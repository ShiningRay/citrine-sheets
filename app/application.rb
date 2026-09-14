# frozen_string_literal: true

require "citrine"
require_relative "workbook"
require_relative "format"

module Sheets
  # 共享应用状态：工作簿 + 选区 + 编辑缓冲 + 格式 + 撤销。
  #
  # 这是本 demo 与 citrine-market-terminal 最大的架构差异：
  # 那边是"单个组件类 + 面板混入"，把状态挂在组件实例上；
  # 这边是**多个挂载根共享一个普通 Ruby 对象**——因为 v1 没有组件嵌套
  # （FRICTION F5），一个根只能是一个组件，而电子表格天然要拆成
  # 工具条 / 公式栏 / 网格 / 检查器 / 状态栏 / 埋点六个独立区域。
  # 状态必须外置到普通对象，各根组件只做"读信号 + 发动作"。
  #
  # 选区与闪烁不放进 Workbook：工作簿的 chrome 会被撤销栈快照，
  # 把视图态混进去会让"撤销"顺带回滚选区。
  class Application
    FLASH_LIMIT = 400 # 一次编辑最多闪烁标注这么多格（避免"重算全部"刷屏）

    attr_reader :workbook, :selection, :edit_text, :edit_mode, :notice, :last_action, :recalc_view, :editor

    def initialize(workbook: Workbook.new, clock: nil)
      @workbook = workbook
      @clock = clock
      @r1 = 0
      @c1 = 0
      @r2 = 0
      @c2 = 0
      @selection = Citrine::Signal.new(selection_state)
      @edit_text = Citrine::Signal.new("")
      @edit_mode = Citrine::Signal.new(false)
      @notice = Citrine::Signal.new({ kind: :info, text: "点选单元格或直接输入；方向键移动，Enter 编辑，Esc 取消" })
      @recalc_view = Citrine::Signal.new({ computed: 0, cells: 0, cyclic: 0, elapsed: 0, label: "尚未编辑" })
      @last_action = Citrine::Signal.new("就绪")
      @view_signals = {}
      @row_signals = {}
      @col_signals = {}
      publish_initial_selection
      @editor = nil
      @flash_pending = nil
      @elapsed = 0
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
    def start_edit(initial = nil)
      text = initial.nil? ? (@workbook.raw(@r2, @c2) || "").to_s : initial.to_s
      @edit_text.set(text)
      @edit_mode.set(true)
      focus_editor
      self
    end

    def commit_edit(dr = nil, dc = nil)
      return self unless @edit_mode.get

      text = @edit_text.get.to_s
      report = timed { @workbook.set_raw(@r2, @c2, text) }
      @edit_mode.set(false)
      blur_editor
      after_edit(report, "已写入 #{active_key}")
      move(dr || 0, dc || 0) if dr || dc
      self
    end

    def cancel_edit
      return self unless @edit_mode.get

      @edit_mode.set(false)
      @edit_text.set((@workbook.raw(@r2, @c2) || "").to_s)
      blur_editor
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

    # 编辑器组件注入（公式栏在挂载时调用）——v1 没有 ref/生命周期（F7），
    # 需要原生焦点控制只能由 App 持有组件引用
    def attach_editor(component)
      @editor = component
      self
    end

    def focus_editor
      @editor&.focus_input
      self
    end

    def blur_editor
      @editor&.blur_input
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

    # ── 视图态信号（按更新频率拆分，见 Workbook 的说明）────────

    def view_signal(row, col)
      @view_signals[[row, col]] ||= Citrine::Signal.new({ selected: false, flash: false })
    end

    def row_signal(index)
      @row_signals[index] ||= Citrine::Signal.new(false)
    end

    def col_signal(index)
      @col_signals[index] ||= Citrine::Signal.new(false)
    end

    def signal_count
      @view_signals.size + @row_signals.size + @col_signals.size + 5 + @workbook.signal_count
    end

    # 重算后的闪烁提示：把"哪些格参与了重算"可视化
    def flash_cells(keys)
      keys.each do |key|
        row, col = key
        signal = view_signal(row, col)
        state = signal.get
        signal.set({ selected: state[:selected], flash: true })
      end
      keys
    end

    def clear_flash(keys)
      keys.each do |key|
        row, col = key
        signal = view_signal(row, col)
        state = signal.get
        next unless state[:flash]

        signal.set({ selected: state[:selected], flash: false })
      end
      keys
    end

    # ── 内部 ────────────────────────────────────────────────

    private

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
      flash = changed.first(FLASH_LIMIT)
      flash_cells(flash)
      @flash_pending = flash
      self
    end

    def refresh_after_history(label)
      @recalc_view.set({
        computed: 0, cells: 0, cyclic: 0, elapsed: @elapsed.to_i, label: label
      })
      @last_action.set(label)
      self
    end

    # 首屏也要有选中高亮：把初始选区（A1）的视图信号发布一次
    def publish_initial_selection
      state = selection_state
      rect_keys(state).each { |key| update_view(key, selected: true) }
      (state[:r1]..state[:r2]).each { |i| row_signal(i).set(true) }
      (state[:c1]..state[:c2]).each { |i| col_signal(i).set(true) }
      self
    end

    def move_to(r1, c1, r2, c2)
      previous = selection_state
      @r1 = r1
      @c1 = c1
      @r2 = r2
      @c2 = c2
      current = selection_state
      publish_selection_delta(previous, current)
      @selection.set(current)
      unless @edit_mode.get
        @edit_text.set((@workbook.raw(@r2, @c2) || "").to_s)
      end
      self
    end

    def publish_selection_delta(previous, current)
      old_cells = rect_keys(previous)
      new_cells = rect_keys(current)
      old_index = {}
      old_cells.each { |key| old_index[key] = true }
      new_index = {}
      new_cells.each { |key| new_index[key] = true }

      old_cells.each { |key| update_view(key, selected: false) unless new_index[key] }
      new_cells.each { |key| update_view(key, selected: true) unless old_index[key] }

      publish_axis_delta(previous[:r1], previous[:r2], current[:r1], current[:r2]) { |i| row_signal(i) }
      publish_axis_delta(previous[:c1], previous[:c2], current[:c1], current[:c2]) { |i| col_signal(i) }
    end

    def publish_axis_delta(old_lo, old_hi, new_lo, new_hi)
      i = old_lo
      while i <= old_hi
        yield(i).set(false) if i < new_lo || i > new_hi
        i += 1
      end
      i = new_lo
      while i <= new_hi
        yield(i).set(true) if i < old_lo || i > old_hi
        i += 1
      end
    end

    def update_view(key, patch)
      row, col = key
      signal = view_signal(row, col)
      state = signal.get
      signal.set({ selected: state[:selected], flash: state[:flash] }.merge(patch))
    end

    def rect_keys(state)
      keys = []
      (state[:r1]..state[:r2]).each do |row|
        (state[:c1]..state[:c2]).each { |col| keys << [row, col] }
      end
      keys
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
      keys = rect_keys(state)
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

    # 由外挂层调用：清理上一次编辑的闪烁标注
    def tick_visuals
      return self if @flash_pending.nil?

      keys = @flash_pending
      @flash_pending = nil
      clear_flash(keys)
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
        "flash=#{@view_signals.values.count { |signal| signal.get[:flash] }}",
        "nodes=#{Sheets::Telemetry.breakdown.map { |k, v| "#{k}:#{v}" }.join(",")}",
        "notice=#{@notice.get[:text]}"
      ].join("|")
    end
  end
end
