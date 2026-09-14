# frozen_string_literal: true

require "citrine"
require_relative "workbook"
require_relative "format"
require_relative "panels/toolbar"
require_relative "panels/formula_bar"
require_relative "panels/grid"
require_relative "panels/inspector"
require_relative "panels/status_bar"
require_relative "panels/debug_bar"

module Sheets
  # 应用根组件：共享状态（工作簿 + 选区 + 编辑缓冲 + 格式 + 撤销）的持有者，
  # 也是整棵组件树的入口。
  #
  # 结构（组件嵌套，随 citrine PR #15 落地）：
  #
  #   Application                      ← 唯一的挂载根（#app）
  #     ├── Toolbar / FormulaBar / StatusBar
  #     ├── GridPanel                  ← 网格视图态（选中/闪烁/行列高亮）归它自己
  #     ├── Inspector / DebugBar
  #     └── 共享的东西一律经 prop `app:` 往下传，动作经回调 Proc 回传
  #
  # 从前这里是"一个普通 Ruby 对象 + 六个平级挂载根"（v1 无组件嵌套，FRICTION F5，
  # 见 sheets.html 里那六个空 div）——布局骨架只能写在 HTML 里、面板之间只能靠共享对象通信。
  # 现在布局是 view 里的嵌套调用，面板是真正的子组件。
  #
  # 选区与闪烁不放进 Workbook：工作簿的 chrome 会被撤销栈快照，
  # 把视图态混进去会让"撤销"顺带回滚选区。
  class Application < Citrine::Component
    FLASH_LIMIT = 400 # 一次编辑最多闪烁标注这么多格（避免"重算全部"刷屏）

    components Panels::Toolbar, Panels::FormulaBar, Panels::GridPanel,
               Panels::Inspector, Panels::StatusBar, Panels::DebugBar

    attr_reader :workbook, :selection, :edit_text, :edit_mode, :notice, :last_action, :recalc_view, :flash

    def initialize(workbook: Workbook.new, clock: nil)
      super({})
      @workbook = workbook
      @clock = clock
      @r1 = 0
      @c1 = 0
      @r2 = 0
      @c2 = 0
      @selection = own_signal(selection_state)
      @edit_text = own_signal("")
      @edit_mode = own_signal(false)
      @notice = own_signal({ kind: :info, text: "点选单元格或直接输入；方向键移动，Enter 编辑，Esc 取消" })
      @recalc_view = own_signal({ computed: 0, cells: 0, cyclic: 0, elapsed: 0, label: "尚未编辑" })
      @last_action = own_signal("就绪")
      @mount_ms = own_signal(0)
      # 本轮"显示变化的格"：数据层事实，由网格面板翻译成闪烁高亮
      @flash = own_signal(nil)
      @flash_seq = 0
      @elapsed = 0
    end

    # ── view：整棵树的骨架 ──────────────────────────────────
    #
    # 容器块**不读任何信号**（读 = 订阅 = 数据一变就重跑整棵树）：
    # 面板各自订阅自己关心的信号，更新粒度由面板内部决定。
    def view
      stack(css_class: "shell", gap: 10) do
        toolbar(app: self)
        formula_bar(app: self)
        row(css_class: "shell-main", gap: 10) do
          stack(css_class: "shell-left") { grid_panel(app: self) }
          stack(css_class: "shell-right", gap: 10) do
            inspector(app: self)
            debug_bar(app: self)
          end
        end
        status_bar(app: self)
      end
    end

    # 挂载耗时只有"整棵树挂完之后"才知道，由入口回填；埋点面板读这个信号，回填即刷新
    def mark_mounted(ms)
      @mount_ms.set(ms)
      self
    end

    def mount_ms
      @mount_ms.get
    end

    # ── 选区 ────────────────────────────────────────────────

    def active_row
      @r2
    end

    def active_col
      @c2
    end

    def selection_state
      {
        r1: [@r1, @r2].min, c1: [@c1, @c2].min,
        r2: [@r1, @r2].max, c2: [@c1, @c2].max,
        ar: @r2, ac: @c2
      }
    end

    def active_key
      Format.cell_key(@r2, @c2)
    end

    def range_label
      state = selection_state
      if state[:r1] == state[:r2] && state[:c1] == state[:c2]
        Format.cell_key(state[:r1], state[:c1])
      else
        "#{Format.cell_key(state[:r1], state[:c1])}:#{Format.cell_key(state[:r2], state[:c2])}"
      end
    end

    def selected_keys
      state = selection_state
      keys = []
      (state[:r1]..state[:r2]).each do |row|
        (state[:c1]..state[:c2]).each { |col| keys << [row, col] }
      end
      keys
    end

    def selection_size
      state = selection_state
      (state[:r2] - state[:r1] + 1) * (state[:c2] - state[:c1] + 1)
    end

    def select_cell(row, col, commit: true)
      return self unless @workbook.in_bounds?(row, col)

      commit_edit if commit && @edit_mode.get
      move_to(row, col, row, col)
      self
    end

    def move(dr, dc, extend: false)
      commit_edit if @edit_mode.get
      row = clamp(@r2 + dr, 0, @workbook.rows - 1)
      col = clamp(@c2 + dc, 0, @workbook.cols - 1)
      if extend
        move_to(@r1, @c1, row, col)
      else
        move_to(row, col, row, col)
      end
      self
    end

    def jump(dr, dc, extend: false)
      # Ctrl/Cmd + 方向键：跳到数据边缘或表格尽头
      commit_edit if @edit_mode.get
      row = dc.zero? ? edge_row(dr) : clamp(@r2 + dr, 0, @workbook.rows - 1)
      col = dr.zero? ? edge_col(dc) : clamp(@c2 + dc, 0, @workbook.cols - 1)
      if extend
        move_to(@r1, @c1, row, col)
      else
        move_to(row, col, row, col)
      end
      self
    end

    def selection_stats
      values = []
      errors = 0
      selected_keys.each do |(row, col)|
        v = @workbook.value(row, col)
        if Coerce.error?(v)
          errors += 1
        elsif v.is_a?(Numeric)
          values << v.to_f
        end
      end
      sum = values.inject(0.0) { |acc, v| acc + v }
      {
        count: values.size,
        numeric_count: values.size,
        sum: sum,
        average: values.empty? ? nil : sum / values.size,
        min: values.empty? ? nil : values.min,
        max: values.empty? ? nil : values.max,
        errors: errors,
        cells: selection_size
      }
    end

    # ── 编辑 ────────────────────────────────────────────────

    def editing?
      @edit_mode.get
    end

    # initial 为 nil 表示编辑现有内容；传字符串表示"直接输入"（覆盖原内容）
    #
    # 焦点不在这里安排：编辑态是**公式栏自己的视图关注点**，它用 watch 订阅 edit_mode
    # 决定何时 focus/blur 自己的输入框（见 FormulaBar#sync_focus_to_edit_mode）。
    def start_edit(initial = nil)
      text = initial.nil? ? (@workbook.raw(@r2, @c2) || "").to_s : initial.to_s
      @edit_text.set(text)
      @edit_mode.set(true)
      self
    end

    def commit_edit(dr = nil, dc = nil)
      return self unless @edit_mode.get

      text = @edit_text.get.to_s
      report = timed { @workbook.set_raw(@r2, @c2, text) }
      @edit_mode.set(false)
      after_edit(report, "已写入 #{active_key}")
      move(dr || 0, dc || 0) if dr || dc
      self
    end

    def cancel_edit
      return self unless @edit_mode.get

      @edit_mode.set(false)
      @edit_text.set((@workbook.raw(@r2, @c2) || "").to_s)
      notice!(:info, "已取消编辑")
      self
    end

    # 供输入框的 on_change（此处为 input 事件）使用：把用户输入同步进信号
    # text_input 已做双向绑定，这里只标脏
    def edit_text_input(value)
      @edit_text.set(value.to_s)
      self
    end

    def on_enter_commit
      commit_edit(1, 0)
      self
    end

    # ── 动作 ────────────────────────────────────────────────

    def clear_selection
      report = timed { @workbook.clear_range(*selection_bounds) }
      after_edit(report, "已清空 #{range_label}")
      self
    end

    def apply_chrome(patch)
      report = timed { @workbook.set_chrome(selected_keys, patch) }
      after_edit(report, "已设置格式 #{range_label}")
      self
    end

    def undo
      result = timed { @workbook.undo }
      return notice!(:warn, "没有可撤销的操作") if result.nil?

      refresh_after_history("已撤销")
      self
    end

    def redo
      result = timed { @workbook.redo }
      return notice!(:warn, "没有可重做的操作") if result.nil?

      refresh_after_history("已重做")
      self
    end

    def recalculate_all
      report = timed { @workbook.recalculate_all }
      after_edit(report, "已重算全部公式")
      self
    end

    # ── 键盘（G-9：GridPanel 用 window_key 绑定，逻辑仍在 App）────────
    #
    # ev 是框架归一化的 Citrine::KeyEvent（key / 修饰键谓词 / prevent_default），
    # 键盘逻辑不再直接碰原生事件对象。
    def handle_key(ev)
      key = ev.key
      shift = ev.shift?
      target = ev.raw && ev.raw[:target]
      tag = target ? target[:tagName].to_s.upcase : ""

      # 编辑框内：Esc / Tab 由输入框自己的 on_key 处理（见 FormulaBar），
      # 其余按键留给输入法与光标，全局层不接管
      return self if tag == "INPUT"
      return handle_meta(ev, key, shift) if ev.command?

      case key
      when "ArrowUp" then swallow(ev) { move(-1, 0, extend: shift) }
      when "ArrowDown" then swallow(ev) { move(1, 0, extend: shift) }
      when "ArrowLeft" then swallow(ev) { move(0, -1, extend: shift) }
      when "ArrowRight" then swallow(ev) { move(0, 1, extend: shift) }
      when "Enter" then swallow(ev) { start_edit }
      when "Tab" then swallow(ev) { move(0, shift ? -1 : 1) }
      when "Escape" then set_notice(:info, "方向键移动 · 直接打字即编辑 · Enter 编辑 · Esc 取消")
      when "Delete" then swallow(ev) { clear_selection }
      when "Backspace" then swallow(ev) { start_edit("") }
      else
        # 可打印字符 → 直接开始编辑（Excel 的习惯）
        swallow(ev) { start_edit(key) } if key.length == 1 && !ev.alt?
      end
      self
    end

    def handle_meta(ev, key, shift)
      case key
      # 注意：裸写 redo 是 Ruby 关键字（重启块）而非方法调用——必须带接收者
      when "z", "Z" then swallow(ev) { shift ? self.redo : undo }
      when "b", "B" then swallow(ev) { apply_chrome(bold: !workbook.chrome(@active_row, @active_col)[:bold]) }
      when "s", "S" then swallow(ev) { set_notice(:info, "这是本地模拟表格，没有文件保存") }
      when "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"
        dr, dc = arrow_delta(key)
        swallow(ev) { jump(dr, dc, extend: shift) }
      end
      self
    end

    def swallow(ev)
      ev.prevent_default
      yield
      self
    end

    def arrow_delta(key)
      case key
      when "ArrowUp" then [-1, 0]
      when "ArrowDown" then [1, 0]
      when "ArrowLeft" then [0, -1]
      else [0, 1]
      end
    end

    # ── 视图态的**数据面**（选中/闪烁的呈现归网格面板，见 panels/grid.rb）──

    # 信号对象数：应用级信号 + 工作簿信号 + 网格上报的视图信号（面板自己的状态）
    def signal_count
      @signals.size + @workbook.signal_count + Sheets::Telemetry.view_signals.to_i
    end

    # 本轮显示变化的格（数据层事实）：网格面板据此标亮、下一拍自己清掉。
    # 带 seq 是因为 Signal 的"值相同不通知"——同一批格连续两次变化也必须能重新点亮。
    def publish_flash(keys)
      @flash_seq += 1
      @flash.set({ seq: @flash_seq, keys: keys })
      self
    end

    # ── 内部 ────────────────────────────────────────────────

    private

    # 应用级信号集中登记：埋点面板要报告"信号对象数"，写死个数容易与实现漂移。
    # 这里用 Citrine.signal 而不是裸 signal：组件里 `signal(name)` 是框架"取 state 底层信号"
    # 的入口，同名会把它盖掉；Citrine.signal 顺带也避免了裸写 Signal 撞 stdlib 的坑（F14）。
    def own_signal(value)
      (@signals ||= []) << Citrine.signal(value)
      @signals.last
    end

    def timed
      Sheets::Telemetry.begin_round! # 一轮 = 一次用户动作（埋点面板据此显示本轮开销）
      return yield if @clock.nil?

      started = @clock.call
      result = yield
      @elapsed = @clock.call - started
      result
    end

    def after_edit(report, label)
      changed = report && report[:cells] ? report[:cells] : []
      @recalc_view.set({
        computed: report ? report[:computed].to_i : 0,
        cells: changed.size,
        cyclic: report ? report[:cyclic].to_i : 0,
        elapsed: @elapsed.to_i,
        label: label
      })
      @last_action.set(label)
      publish_flash(changed.first(FLASH_LIMIT))
      self
    end

    def refresh_after_history(label)
      @recalc_view.set({
        computed: 0, cells: 0, cyclic: 0, elapsed: @elapsed.to_i, label: label
      })
      @last_action.set(label)
      self
    end

    def move_to(r1, c1, r2, c2)
      @r1 = r1
      @c1 = c1
      @r2 = r2
      @c2 = c2
      @selection.set(selection_state)
      unless @edit_mode.get
        @edit_text.set((@workbook.raw(@r2, @c2) || "").to_s)
      end
      self
    end

    def selection_bounds
      state = selection_state
      [state[:r1], state[:c1], state[:r2], state[:c2]]
    end

    def clamp(value, low, high)
      return low if value < low
      return high if value > high

      value
    end

    def edge_row(dr)
      limit = dr.positive? ? @workbook.rows - 1 : 0
      row = @r2
      row += dr.positive? ? 1 : -1 while row != limit && @workbook.value(row + dr, @c2).nil? && @workbook.raw(row + dr, @c2).nil?
      clamp(row, 0, @workbook.rows - 1)
    end

    def edge_col(dc)
      limit = dc.positive? ? @workbook.cols - 1 : 0
      col = @c2
      col += dc.positive? ? 1 : -1 while col != limit && @workbook.value(@r2, col + dc).nil? && @workbook.raw(@r2, col + dc).nil?
      clamp(col, 0, @workbook.cols - 1)
    end

    def notice!(kind, text)
      @notice.set({ kind: kind, text: text })
      self
    end

    public

    def set_notice(kind, text)
      notice!(kind, text)
    end

    # ── 面板读取的派生视图 ──────────────────────────────────
    # 这些方法内部**读信号**，因此在 block 里调用即建立依赖。
    # 不要在事件处理器里调用（那会白白订阅一堆信号）。

    def selection_label
      @selection.get
      range_label
    end

    def active_info
      @selection.get # 依赖：选区
      key = [active_row, active_col]
      snapshot = @workbook.value_signal(key[0], key[1]).get # 依赖：当前格的值
      raw = @workbook.raw(key[0], key[1])
      {
        key: key,
        key_label: Format.cell_key(key[0], key[1]),
        raw: raw,
        display: snapshot[:display],
        kind: snapshot[:kind],
        kind_label: kind_label(snapshot[:kind], raw),
        error: snapshot[:error],
        formula: !!(raw && raw.to_s.start_with?("="))
      }
    end

    def active_dependencies
      @selection.get
      @workbook.dependencies(active_row, active_col)
    end

    def active_dependents
      @selection.get
      @workbook.dependents(active_row, active_col)
    end

    def live_stats
      state = @selection.get # 依赖：选区
      @workbook.recalc_signal.get # 依赖：重算（值变了才需要重算统计）
      # 注意：这里**不**逐个订阅范围内单元格的值信号。若那样做，一次编辑会让
      # 统计块重跑 N 次（v1 无批量更新，F3），实测多建 80+ 个节点。
      # 以"重算信号"为唯一数据口径即可覆盖所有值变化。
      values = []
      errors = 0
      keys = Format.rect_keys(state)
      keys.each do |(row, col)|
        value = @workbook.value(row, col)
        if Coerce.error?(value)
          errors += 1
        elsif value.is_a?(Numeric)
          values << value.to_f
        end
      end
      sum = values.inject(0.0) { |acc, v| acc + v }
      {
        cells: keys.size,
        numeric_count: values.size,
        sum: values.empty? ? nil : sum,
        average: values.empty? ? nil : sum / values.size,
        min: values.empty? ? nil : values.min,
        max: values.empty? ? nil : values.max,
        errors: errors
      }
    end

    def sheet_summary
      wb = @workbook
      "填充 #{wb.filled_count} 格 · 公式 #{wb.formula_count} 个 · 错误 #{wb.error_count} 格 · " \
        "循环引用 #{wb.cyclic_count} 格 · 撤销栈 #{wb.undo_depth} / 重做栈 #{wb.redo_depth}"
    end

    def kind_label(kind, raw)
      base =
        case kind
        when :blank then "空白"
        when :number then "数字"
        when :text then "文本"
        when :bool then "布尔"
        when :error then "错误值"
        else kind.to_s
        end
      raw.to_s.start_with?("=") ? "公式 → #{base}" : base
    end

    # ── 桩验收用钩子（demo 专用，非框架 API）──────────────

    # 驱动一次"结构变更"（行列数变化），用来验证网格的 keyed 复用：
    # 已有行/列/单元格应保持同一批 DOM 对象，只有新增的才新建节点。
    def resize_grid(rows, cols)
      @workbook.resize(rows: rows, cols: cols)
      self
    end

    # ── 桩验收用状态摘要（demo 专用，非框架 API）──────────────

    def test_state_text
      info = active_info
      stats = live_stats
      report = @recalc_view.get
      [
        "sel=#{info[:key_label]}",
        "range=#{range_label}",
        "edit=#{@edit_mode.get}",
        "raw=#{info[:raw]}",
        "val=#{info[:display]}",
        "kind=#{info[:kind_label]}",
        "stats=#{stats[:numeric_count]}/#{stats[:sum] || 0}",
        "filled=#{@workbook.filled_count}",
        "formulas=#{@workbook.formula_count}",
        "errors=#{@workbook.error_count}",
        "cyclic=#{@workbook.cyclic_count}",
        "undo=#{@workbook.undo_depth}",
        "redo=#{@workbook.redo_depth}",
        "recalc=#{report[:computed]}/#{report[:cells]}/#{report[:cyclic]}",
        "action=#{@last_action.get}",
        "input=#{@edit_text.get}",
        "nodes=#{Sheets::Telemetry.breakdown.map { |k, v| "#{k}:#{v}" }.join(",")}",
        "notice=#{@notice.get[:text]}"
      ].join("|")
    end
  end
end
