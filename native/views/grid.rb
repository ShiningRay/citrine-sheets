# frozen_string_literal: true

require "citrine"
require_relative "../theme"
require_relative "../../app/format"

module Sheets
  module Native
    module Views
      # 网格：**一个自绘面板**画完 1560 格。
      #
      # 浏览器侧的 Panels::Grid 是 1560 个节点 + 1560 个逐格信号（粒度换吞吐）；
      # 原生侧反过来——libui 的 uiArea 一次 on_draw 就能画完整块，逐格信号与 Effect
      # 在这里是纯开销。两侧共享的是同一份 Application 逻辑（选区/编辑/重算/撤销）。
      #
      # 三个口径写在前面（改绘制前先读）：
      #   1. **不读信号**：绘制回调不在 Effect 里，画的都是调用时的数据快照
      #      （workbook 的读方法 + Application 的实例变量派生值），读信号只会白建订阅；
      #      重绘时机由 `watch:` 依赖 + 框架的收敛兜底 + 本文件的闪烁 ticker 决定。
      #   2. **省调用而不是省正确性**：1560 格里绝大多数既没值也没格式——空白格
      #      只由网格线表达（cols+1 竖 + rows+1 横 = 88 次 line 调用覆盖整块），
      #      有值/有底色/选中/闪烁的格才各出一次 rect/text。整块绘制因此在
      #      百来个图元的量级，不需要按裁剪区算可见行列。
      #   3. **坐标 = 内容坐标**：面板是滚动区域（`scroll: true`，libui 的
      #      uiNewScrollingArea 按内容尺寸建，滚动量由 libui 平移上下文），
      #      点击报点与绘制共用同一套换算（见 click_at）。
      class Grid < Citrine::Component
        prop :app

        HEAD_W = 46   # 行号列宽（与浏览器侧 .grid-row-head 的 46px 一致）
        HEAD_H = 24   # 列头高
        CELL_W = 88
        CELL_H = 24
        FONT_SIZE = 13
        HEAD_FONT_SIZE = 11
        PAD_X = 6
        TEXT_TOP = 5  # 单元格文本顶边相对单元格顶边的偏移（垂直居中取整）
        HEAD_TEXT_TOP = 7 # 列头/行号文本的顶边偏移（字号更小）
        FLASH_MS = 150
        ELLIPSIS = "…" # 左对齐文本超宽时的截断标记（浏览器侧 text-overflow: ellipsis）

        # 启动取焦点：框架的 App#setup 顺序是 mount_component（跑 on_mount）→ window_show
        # → activate，**on_mount 里还没有 key window**（实测 [NSApp keyWindow] 为 nil），
        # 那时调 AreaHandle#focus 会静默返回 false，焦点停在公式栏的 entry 上
        # （firstResponder 是它的 NSTextView）→ 方向键/打字/⌘Z 全都到不了网格。
        # 因此 on_mount 里只**排队**尝试，等窗口显示 + 应用激活之后再取；激活是异步的，
        # 一次不成再试几次，用尽仍失败就给一句可操作的提示（不静默失败）。
        FOCUS_RETRY_MS = 250
        FOCUS_ATTEMPTS = 24        # ≈6s：窗口显示与应用激活实测可能晚到 ~4s（屏幕刚唤醒时）
        FOCUS_HINT_ATTEMPTS = 4    # ≈1s 还没拿到就先提示用户点一下；之后拿到焦点会自动撤掉
        FOCUS_HINT = "点一下网格即可用键盘（窗口还没拿到键盘焦点）"

        # 全局键盘：**声明在网格面板组件上**（浏览器侧 Panels::GridPanel 也是这么做的），
        # 而不是声明在 Application 的实例上。原因是命名冲突：Sheets::Application#handle_key(ev)
        # 是应用的键逻辑，与框架的 Component#handle_key(handler, event)（事件派发入口）同名；
        # 框架转发 window_key 时按 2 实参调用声明者的 handle_key，声明在 Application
        # 子类上会直接 ArgumentError。声明在这里则落在 Component 的实现上，
        # 再由本方法转给 app.global_key（应用侧的键逻辑入口）。
        window_key :global_key

        def global_key(ev)
          yield_startup_focus # 键能打到网格 = 焦点已经在网格上（启动提示已过时、取焦点该让位）
          app.global_key(ev)
        end

        # 自绘面板（area）：内容尺寸 = 26 列 × 60 行的像素尺寸，滚动由 libui 负责。
        # on_draw / on_click 是冻结接口里的 prop（docs/design/native-area.md 2.1）。
        def view
          element(:area,
                  ref: :grid,
                  # 注意：scroll: true 下的 size 是**内容尺寸**（uiNewScrollingArea 的
                  # width/height 参数；滚动面板下 libui 不报 Draw 尺寸）。
                  # 视口尺寸由外层容器链的 flex_grow 决定——这条链必须**一路不断**：
                  # libui 的 box 只把剩余空间给它自己的 stretchy 子控件，父容器自己没
                  # 撑开的话，子控件的 flex_grow 就没有空间可分。根元素那一环在
                  # NativeApp#view（见那里的注释，SHEETS-1c 的 D2 实测）。
                  size: [content_width, content_height],
                  scroll: true,
                  on_draw: ->(p) { paint_grid(p) },
                  on_click: ->(ev) { click_at(ev.x, ev.y) },
                  style: { flex_grow: 1 })
        end

        def content_width
          HEAD_W + app.workbook.cols * CELL_W
        end

        def content_height
          HEAD_H + app.workbook.rows * CELL_H
        end

        # ── 重绘时机（设计 2.4 / 2.5）────────────────────────────
        #
        # 用组件级 watch（核心的声明式订阅，浏览器侧面板同款）读"画的东西依赖哪些信号"，
        # 依赖一变就显式排一次重绘（refs[:grid] 是 AreaHandle，#repaint 见设计 2.5）。
        #
        # 为什么不用 area 的 `watch:` prop（设计 2.4 的另一条路）：那条路要求把 Proc 传给
        # 元素，而 citrine 核心的属性校验不认 area 的 watch，每挂载一次就提醒一条
        # "Proc 不会被求值"（核心未收录 area 的响应式 prop，见返回的接口问题清单）。
        # 两条路效果相同；这里选没有误导性噪声的一条，并保留框架的粗粒度兜底。
        watch { watch_area }

        def watch_area
          sync_flash(app.flash.get)
          app.selection.get
          app.edit_text.get
          app.edit_mode.get
          app.workbook.recalc_signal.get
          repaint
        end

        # 本轮显示变化的格（键盘编辑后由 Application 发布）→ 本面板的闪烁高亮。
        # 浏览器侧同类逻辑在 GridPanel#sync_flash（逐格视图信号），原生侧只需要一份集合。
        def sync_flash(payload)
          @flash_keys = payload ? payload[:keys].to_h { |key| [key, true] } : nil
          self
        end

        # ticker 到点：清掉上一轮的闪烁并重画一次（重画要显式请求——
        # 定时器回调不是响应式收敛，框架不会替本面板标脏）
        def clear_flash
          return self if @flash_keys.nil?

          @flash_keys = nil
          repaint
        end

        def repaint
          # refs[:grid] 是设计 2.5 的 AreaHandle（面板句柄，#repaint 排一次重绘）
          refs[:grid]&.repaint
          self
        end

        # 启动即需键盘（设计 2.3）：把焦点交给面板。libui 的面板只在自己是 first responder
        # 时收键，而焦点必须在窗口显示 + 应用激活之后才取得到（见 FOCUS_* 的注释）。
        #
        # 三段式：
        #   1. on_mount 里先试一次——桩后端没有"激活"这个概念，这一次就成功（测试的确定性靠它）；
        #   2. 真窗口里第一次必然失败（还没有 key window）→ 一个重复定时器每
        #      FOCUS_RETRY_MS 再试一次（实测屏幕刚唤醒时窗口变 key 要 ~4s，所以窗口给到 6s）；
        #   3. 到 FOCUS_HINT_ATTEMPTS 还没拿到就先给一句可操作提示（用户点一下立刻可用），
        #      之后仍然继续重试到 FOCUS_ATTEMPTS——激活晚到就把提示**自动撤掉**，
        #      而不是让用户面对"打字进公式栏、方向键没反应"的静默失败。
        #
        # **让位**（SHEETS-2b 的 N2）：取焦点是抢占式的，而重试窗口里用户可能正在用应用
        # 自己的输入控件——README 的中文输入路径就是"用鼠标点公式栏输入框"。所以：
        #   · 用户在输入框里打过字（`app.editor_input_seen?`，由 FormulaBar 的 on_change
        #     记下）→ 停止重试、不再抢焦点；
        #   · 用户点了网格 / 键已经打进网格 → 同样停止重试并撤掉提示（yield_startup_focus）。
        # 否则下一个 tick 会把用户刚点进去的输入框抢回网格，他得再点一次。判据只能来自应用
        # 自己收到的事件——libui 的 entry 不上报焦点/点击，应用侧看不到"光标在输入框里"，
        # 残余的那一点竞争（只点进去还没打字）在 native/README.md 里写明。
        on_mount :schedule_focus, :start_flash_ticker
        on_unmount :stop_flash_ticker, :stop_focus_timer

        def schedule_focus
          @focus_attempts = 0
          # 一个重复定时器（每 FOCUS_RETRY_MS 一次，最多 FOCUS_ATTEMPTS 次）比排 N 个
          # 一次性定时器省线程；拿到焦点或次数用尽就自己停表。
          @focus_timer = Citrine::Native.every(FOCUS_RETRY_MS) { attempt_focus }
          attempt_focus # 立刻试一次：桩后端没有"激活"概念，这一步就成功（测试确定性靠它）
        end

        def attempt_focus
          # 用户在应用自己的输入控件里（公式栏 entry）打字 → 让位：不抢、不再重试。
          # 这一条必须在**这里**判，而不是只在调用点判：tick 是排到主线程执行的，用户
          # 打字时可能已经有一个 tick 排在队里，光停表拦不住它（见 yield_startup_focus）。
          return yield_startup_focus if app.editor_input_seen?

          @focus_attempts += 1
          if focus_area(refs[:grid]) # 拿到焦点（含"激活晚到的成功"）
            stop_focus_timer
            return clear_focus_hint
          end

          show_focus_hint if @focus_attempts >= FOCUS_HINT_ATTEMPTS
          stop_focus_timer if @focus_attempts >= FOCUS_ATTEMPTS
          self
        end

        # 启动取焦点让位：用户已经在用应用自己的输入（网格按键/点击 = 本文件的
        # global_key/click_at；公式栏 entry 的编辑 = 面板调 app.note_editor_input）。
        # 这里只负责停表 + 提示进入终态；"不再被排队的 tick 抢焦点"由 attempt_focus 开头的
        # 判据保证——停表拦不住**已经排进主线程队列**的那一个 tick。
        def yield_startup_focus
          stop_focus_timer
          clear_focus_hint
          self
        end

        def stop_focus_timer
          @focus_timer&.stop
          @focus_timer = nil
        end

        # 把焦点交给面板；handle 可注入（默认当前面板句柄）——拿不到句柄 = 没取到焦点。
        # 测试用"如实返回 false 的句柄替身"驱动失败分支（框架契约：能力缺口返回 false）。
        def focus_area(handle)
          return false unless handle

          handle.focus
        end

        def show_focus_hint
          return self if @focus_hint_resolved # 已经了结过的提示不再点亮（N1）

          @notice_before_hint ||= app.notice.get[:text] # 撤提示时恢复（应用自己的首条提示）
          @focus_hint = true
          app.set_notice(:info, FOCUS_HINT)
          self
        end

        # 提示不能撒谎：焦点真到手、或用户已经点了网格/键已经打进网格，就把提示撤掉；
        # 且只在"当前这条就是我们的提示"时撤（不覆盖应用后来的提示）。
        #
        # 撤掉是**终态**（@focus_hint_resolved）：重试 tick 不得再把它点亮。SHEETS-2b 实测过
        # 没有这个终态的样子——用户点掉提示后 +180~240ms 提示又回来了，而那时他已经在用
        # 键盘了（焦点误报/后端能力缺口时这句话就是纯撒谎）。启动提示是一次性的引导，
        # 用户已经证明自己能用键盘之后（或者压根不需要它），就不该再出现。
        def clear_focus_hint
          @focus_hint_resolved = true
          return self unless @focus_hint

          @focus_hint = false
          app.set_notice(:info, @notice_before_hint) if app.notice.get[:text] == FOCUS_HINT
          self
        end

        def start_flash_ticker
          @ticker = Citrine::Native.every(FLASH_MS) { clear_flash }
        end

        def stop_flash_ticker
          @ticker&.stop
          @ticker = nil
        end

        # ── 绘制 ────────────────────────────────────────────────

        def paint_grid(painter)
          wb = app.workbook
          rows = wb.rows
          cols = wb.cols

          painter.rect(0, 0, content_width, content_height, fill: Theme::CELL)
          paint_cells(painter, wb, rows, cols)
          paint_grid_lines(painter, rows, cols)
          paint_headers(painter, rows, cols)
        end

        # 单元格：底色（选中 > 闪烁 > 格式）+ 值文本。空值不画文本（省下 measure/layout）。
        def paint_cells(painter, wb, rows, cols)
          selection = app.selection_state
          editing = app.editing?
          active = [app.active_row, app.active_col]
          buffer = editing ? app.edit_text.get.to_s : ""

          rows.times do |row|
            y = cell_y(row)
            cols.times do |col|
              x = cell_x(col)
              chrome = wb.chrome(row, col)
              editing_here = editing && active[0] == row && active[1] == col
              fill = editing_here ? Theme::EDIT_FILL : cell_fill(selection, chrome, row, col)
              painter.rect(x + 1, y + 1, CELL_W - 1, CELL_H - 1, fill: fill) if fill

              if editing_here
                # 编辑中的格画**编辑缓冲**（不是旧值），并描出输入焦点
                paint_value(painter, buffer, chrome, :text, x, y)
                painter.rect(x + 1, y + 1, CELL_W - 1, CELL_H - 1, stroke: Theme::ACCENT, line_width: 2)
                next
              end

              value = wb.value(row, col)
              next if value.nil?

              paint_value(painter, wb.display(row, col), chrome, wb.kind(row, col), x, y,
                          formula: wb.raw(row, col).to_s.start_with?("="), error: wb.error?(row, col))
            end
          end
        end

        # 单元格底色：选中 > 闪烁 > 格式底色（与浏览器侧的 class 优先级一致；
        # 选中与闪烁同时命中时用 .cell.is-sel.is-flash 的底色）
        def cell_fill(selection, chrome, row, col)
          selected = in_rect?(selection, row, col)
          flashing = !@flash_keys.nil? && @flash_keys.key?([row, col])
          return Theme::SEL_FLASH if selected && flashing
          return Theme::SEL_FILL if selected
          return Theme::FLASH_SOFT if flashing

          chrome[:bg]
        end

        # 数值右对齐、错误值用 danger 且加粗（.cell.is-err 的口径）、公式值冷色。
        # 右对齐自己算 x（measure_text）而不依赖 align:/width: —— 少一层对
        # "align 在给定位宽内如何落位"的解释空间。
        #
        # 三种"太长"的处理口径与浏览器侧对齐（.cell 的 padding + overflow: hidden）：
        #   · 一律 clip 到格的内容框（左右各留 PAD_X）——长值不再压进邻格叠字；
        #   · 左对齐的文本按 text-overflow: ellipsis 截断加省略号（按真度量宽度砍）；
        #   · 数字右对齐**不加**省略号：浏览器在右对齐溢出时是裁掉左边（text-overflow
        #     只管行尾），加"…"反而与浏览器不一样。
        def paint_value(painter, text, chrome, kind, x, y, formula: false, error: false)
          return if text.nil? || text.empty?

          size = FONT_SIZE
          weight = chrome[:bold] || error ? :bold : :normal
          color = if error then Theme::DANGER
                  elsif formula then Theme::FORMULA
                  else Theme::TEXT
                  end
          # 裁剪到格的**内容框**（左右各留 PAD_X，与浏览器 .cell 的 padding + overflow: hidden
          # 同口径）：数字右对齐时左半边被裁在内容框外，不会贴到左邻格的文字上
          painter.clip(x + PAD_X, y + 1, CELL_W - PAD_X * 2, CELL_H - 1) do
            if kind == :number
              width = painter.measure_text(text, size: size, weight: weight)[0]
              painter.text(text, x: x + CELL_W - PAD_X - width, y: y + TEXT_TOP,
                                 color: color, size: size, weight: weight)
            else
              painter.text(ellipsized(painter, text, size, weight), x: x + PAD_X, y: y + TEXT_TOP,
                                                                   color: color, size: size,
                                                                   weight: weight)
            end
          end
        end

        # 文本装不下时砍到装得下再加省略号（CJK 与 ASCII 都按字符砍；度量走框架缓存）
        def ellipsized(painter, text, size, weight)
          avail = CELL_W - PAD_X * 2
          fits = ->(string) { painter.measure_text(string, size: size, weight: weight)[0] <= avail }
          return text if fits.call(text)

          chars = text.chars
          chars.pop until chars.empty? || fits.call("#{chars.join}#{ELLIPSIS}")
          "#{chars.join}#{ELLIPSIS}"
        end

        def paint_grid_lines(painter, rows, cols)
          bottom = HEAD_H + rows * CELL_H
          right = HEAD_W + cols * CELL_W
          (0..cols).each { |col| painter.line(cell_x(col), 0, cell_x(col), bottom, color: Theme::LINE_SOFT) }
          (0..rows).each { |row| painter.line(HEAD_W, cell_y(row), right, cell_y(row), color: Theme::LINE_SOFT) }
        end

        # 列头 A…Z + 行号：底为 panel-2，被选区覆盖的列/行用 accent-soft + accent 文字
        # （浏览器侧 .head-inner.is-on 的口径）
        def paint_headers(painter, rows, cols)
          selection = app.selection_state
          painter.rect(0, 0, HEAD_W, content_height, fill: Theme::PANEL_2)
          painter.rect(0, 0, content_width, HEAD_H, fill: Theme::PANEL_2)

          cols.times do |col|
            on = col >= selection[:c1] && col <= selection[:c2]
            x = cell_x(col)
            painter.rect(x + 1, 1, CELL_W - 1, HEAD_H - 2, fill: Theme::ACCENT_SOFT) if on
            label = Format.column_label(col)
            weight = on ? :bold : :normal
            width = painter.measure_text(label, size: HEAD_FONT_SIZE, weight: weight)[0]
            painter.text(label, x: x + (CELL_W - width) / 2, y: HEAD_TEXT_TOP,
                                color: on ? Theme::ACCENT : Theme::DIM,
                                size: HEAD_FONT_SIZE, weight: weight)
          end

          rows.times do |row|
            on = row >= selection[:r1] && row <= selection[:r2]
            y = cell_y(row)
            painter.rect(1, y + 1, HEAD_W - 2, CELL_H - 1, fill: Theme::ACCENT_SOFT) if on
            label = (row + 1).to_s
            weight = on ? :bold : :normal
            width = painter.measure_text(label, size: HEAD_FONT_SIZE, weight: weight)[0]
            painter.text(label, x: (HEAD_W - width) / 2, y: y + HEAD_TEXT_TOP,
                                color: on ? Theme::ACCENT : Theme::DIM,
                                size: HEAD_FONT_SIZE, weight: weight)
          end
        end

        # ── 命中测试（面板本地坐标 → 行列）──────────────────────
        #
        # 点列头/行号 = 全选该列/该行（浏览器侧没有这条交互，自绘网格顺手补上）；
        # 越界点击交给 select_cell 自己挡掉（它按 in_bounds? 判定）。
        def click_at(x, y)
          yield_startup_focus # 用户点了面板 = 焦点已交给面板（提示已过时、取焦点该让位）
          if y < HEAD_H && x >= HEAD_W
            select_column(col_at(x))
          elsif x < HEAD_W && y >= HEAD_H
            select_row(row_at(y))
          else
            app.select_cell(row_at(y), col_at(x))
          end
          self
        end

        def select_column(col)
          return self unless (0...app.workbook.cols).cover?(col)

          app.select_cell(0, col)
          app.move(app.workbook.rows - 1, 0, extend: true)
          self
        end

        def select_row(row)
          return self unless (0...app.workbook.rows).cover?(row)

          app.select_cell(row, 0)
          app.move(0, app.workbook.cols - 1, extend: true)
          self
        end

        def cell_x(col) = HEAD_W + col * CELL_W
        def cell_y(row) = HEAD_H + row * CELL_H
        # 命中测试：事件坐标是浮点（PointerEvent 的 x/y 从小数像素来），
        # 必须落回整数行列——workbook.in_bounds? 只认 Integer，浮点行/列会被它判为越界
        def col_at(x) = ((x - HEAD_W) / CELL_W).floor
        def row_at(y) = ((y - HEAD_H) / CELL_H).floor

        private

        def in_rect?(rect, row, col)
          row >= rect[:r1] && row <= rect[:r2] && col >= rect[:c1] && col <= rect[:c2]
        end
      end
    end
  end
end
