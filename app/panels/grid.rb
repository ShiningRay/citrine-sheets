# backtick_javascript: true
# frozen_string_literal: true

require "native"
require "citrine"
require_relative "common"
require_relative "../format"
require_relative "../telemetry"

module Sheets
  module Panels
    # 网格面板：列头 + 行头 + 全部单元格。
    #
    # 性能设计（1560 格仍要秒开、方向键要跟手）：
    #   单元格 = 外层 box + 内层 label，分别订阅**不同频率**的信号——
    #     · box   读 chrome_signal（错误态/数字右对齐/格式）与视图信号（选中/闪烁）
    #     · label 读 value_signal（每次重算都可能变）
    #   两者都走"响应式属性 / 叶子块"，于是改一个数只重跑 1 个叶子（0 个新建节点），
    #   移动选区只重设 2 个格子的 class + 2 个表头（同样 0 个新建节点）。
    #   若把这些读进容器块，任何变化都要重建整棵子树，方向键会卡。
    #
    # 结构身份用 key 标出来（行 "row-3"、列头 "col-head-2"、单元格 = 地址 "B3"）：
    # 结构块重跑（行列数变化，或将来的插入/删除行列）时按 key 复用，
    # 只有真正新增的才新建节点——已有的 DOM、Effect、事件全部保留。
    module Grid
      include Common

      CELL_WIDTH = 84
      ROW_HEIGHT = 22
      HEADER_WIDTH = 46

      private

      def render_grid
        panel("panel-grid") do # 容器块：不读信号
          box(css_class: "grid-toolbar") do # 容器块不读信号
            label(css_class: "grid-range num") { app.selection_label } # 读选区
            label(css_class: "grid-action") { app.last_action.get }    # 读动作
            box(css_class: "grid-legend", direction: :row, gap: 10) do # 静态图例
              label(css_class: "legend legend-sel") { "■ 选中" }
              label(css_class: "legend legend-flash") { "■ 本次重算" }
              label(css_class: "legend legend-err") { "■ 错误" }
            end
          end

          box(css_class: "grid-scroll", direction: :column) do # 滚动容器：不读信号
            render_grid_head
            render_grid_body
          end
        end
      end

      # 列头 A..Z
      def render_grid_head
        box(css_class: "grid-head") do
          # 结构块：只读列数（结构信号）——行列数变化才重跑，keyed 复用保住已有表头
          box(css_class: "grid-corner", key: :grid_corner) {}
          app.workbook.cols.times do |col|
            box(css_class: "grid-col-head", key: "col-head-#{col}") do
              # 列高亮是本节点的响应式属性：重跑只重设 class，不重建节点
              box(css_class: -> { col_signal(col).get ? "head-inner is-on" : "head-inner" }) do
                label(css_class: "head-text") { Format.column_label(col) }
              end
            end
          end
        end
      end

      def render_grid_body
        box(css_class: "grid-body", direction: :column) do
          # 结构块：只读行数（结构信号），行数变化才重跑
          app.workbook.rows.times do |row|
            box(css_class: "grid-row", key: "row-#{row}") do
              box(css_class: "grid-row-head") do
                box(css_class: -> { row_signal(row).get ? "head-inner is-on" : "head-inner" }) do
                  label(css_class: "head-text") { (row + 1).to_s }
                end
              end
              app.workbook.cols.times do |col|
                render_cell(row, col)
              end
            end
          end
        end
      end

      # 单个单元格：**两层**结构 + 单元格地址作为 key。
      #
      # key = 地址（"B3"）而不是"第几个格子"：结构一变，身份仍然跟着这一格走。
      #
      # G-2 之前这里必须三层：props 的实参在**外层块的执行中**求值，谁调用
      # cell_class() 谁的 Effect 就订阅了这一格的信号——所以得再包一层，
      # 把订阅关进"中层"（改一格要用 2 个新建节点换一次属性更新）。
      # 现在 `css_class:` / `style:` 直接传 Proc：求值发生在本节点的属性 Effect 内，
      # 订阅收敛到这一格、重跑只重设属性，**0 个新建节点**——中层因此可以去掉。
      #
      #   cell（静态槽：尺寸/边框/点击 + 响应式 class/style）
      #     cell-text（值）   ← 读本格值信号，只改文字
      def render_cell(row, col)
        box(
          key: Format.cell_key(row, col),
          css_class: -> { "cell #{cell_flags(row, col)}" },
          style: -> { cell_style(row, col) },
          on_click: -> { app.select_cell(row, col) }
        ) do
          label(css_class: "cell-text") { cell_text(row, col) }
        end
      end

      # 响应式属性：读 chrome（格式/错误态/类型）+ 视图（选中/闪烁）
      def cell_flags(row, col)
        chrome = app.workbook.chrome_signal(row, col).get
        view = view_signal(row, col).get
        flags = []
        flags << "is-num" if chrome[:kind] == :number
        flags << "is-err" if chrome[:error]
        flags << "is-sel" if view[:selected]
        flags << "is-flash" if view[:flash]
        flags << "is-bold" if chrome[:bold]
        flags.join(" ")
      end

      def cell_style(row, col)
        chrome = app.workbook.chrome_signal(row, col).get
        style = {}
        style[:background] = chrome[:bg] if chrome[:bg]
        style
      end

      # 内层：只读值信号 → 数值变化时只改 textContent（0 个新建节点）
      def cell_text(row, col)
        snapshot = app.workbook.value_signal(row, col).get
        snapshot[:display].to_s
      end

      # ── 网格自己的视图态：选中高亮 / 闪烁 / 行列高亮 ─────────────
      #
      # 这些是"这一格此刻长什么样"，属于**本面板**而不是共享模型：
      # Application 只发布数据层的变化（选区信号 + 本轮哪些格显示变了），
      # 由本面板翻译成逐格视图信号。逐格信号是更新粒度的关键——
      # 若换成"一个全局选区信号 + 每格读它"，移动选区会让 1560 个格子全部重跑属性。

      def setup_view_state
        @selection_watch = Citrine::Effect.create { sync_selection(app.selection.get) }
        @flash_watch = Citrine::Effect.create { sync_flash(app.flash.get) }
      end

      def teardown_view_state
        [@selection_watch, @flash_watch].each { |effect| effect&.dispose }
        @selection_watch = nil
        @flash_watch = nil
        Sheets::Telemetry.view_signals = 0
      end

      # 选区增量：只更新进出选区的格子与行列头（不是"整表重绘"）
      def sync_selection(state)
        previous = @last_selection
        @last_selection = state
        return self if previous == state

        if previous.nil? # 首次挂载：把初始选区发布一次，首屏就有高亮
          Format.rect_keys(state).each { |key| update_view(key, selected: true) }
          publish_axis(state[:r1], state[:r2]) { |i| row_signal(i) }
          publish_axis(state[:c1], state[:c2]) { |i| col_signal(i) }
        else
          publish_selection_delta(previous, state)
        end
        self
      end

      def publish_selection_delta(previous, current)
        old_keys = Format.rect_keys(previous)
        new_keys = Format.rect_keys(current)
        old_index = {}
        old_keys.each { |key| old_index[key] = true }
        new_index = {}
        new_keys.each { |key| new_index[key] = true }

        old_keys.each { |key| update_view(key, selected: false) unless new_index[key] }
        new_keys.each { |key| update_view(key, selected: true) unless old_index[key] }

        publish_axis_delta(previous[:r1], previous[:r2], current[:r1], current[:r2]) { |i| row_signal(i) }
        publish_axis_delta(previous[:c1], previous[:c2], current[:c1], current[:c2]) { |i| col_signal(i) }
      end

      def publish_axis(lo, hi)
        (lo..hi).each { |i| yield(i).set(true) }
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

      # 本轮显示变化的格：先标亮，交给 ticker 在下一拍清掉
      def sync_flash(payload)
        return self if payload.nil?

        keys = payload[:keys]
        @pending_flash = keys
        keys.each { |key| update_view(key, flash: true) }
        self
      end

      # ticker（on_mount 起的定时器）调用：清掉上一轮的闪烁标注
      def clear_flash
        keys = @pending_flash
        return self if keys.nil?

        @pending_flash = nil
        keys.each { |key| update_view(key, flash: false) }
        self
      end

      # 写入某一格的视图态。状态镜像在 @view_state 里而不是读回信号——
      # 本方法跑在 watcher 的 Effect 内，`signal.get` 会让 watcher 订阅自己写的信号。
      def update_view(key, patch)
        @view_state ||= {}
        state = (@view_state[key] ||= { selected: false, flash: false })
        merged = state.merge(patch)
        return self if merged == state

        @view_state[key] = merged
        view_signal(key[0], key[1]).set(merged)
        self
      end

      def view_signal(row, col)
        keyed_signal(:view, [row, col]) { { selected: false, flash: false } }.tap { report_view_signals }
      end

      def row_signal(index)
        keyed_signal(:row, index) { false }.tap { report_view_signals }
      end

      def col_signal(index)
        keyed_signal(:col, index) { false }.tap { report_view_signals }
      end

      # "信号对象数"是应用级指标（埋点面板读 Telemetry.view_signals）：
      # 逐格信号由框架的 keyed_signal 按 key 记忆，这里只统计表的大小。
      def report_view_signals
        Sheets::Telemetry.view_signals = view_signal_count
      end

      def view_signal_count
        keyed_signals.values.sum(&:size)
      end
    end

    # 网格挂载根：一个组件 = 一整块区域（组件嵌套已落地：它是 Application 的子组件）
    #
    # 全局键盘与定时器在这里落地（G-9 / G-10）：
    #   · window_key  —— window 级 keydown，随组件卸载自动解绑（从前是外挂层自己
    #     持 window 引用 + beforeunload 清理）
    #   · on_mount/on_unmount —— 定时器与视图态订阅的起与停交给框架生命周期
    # 键盘逻辑本身仍归 Application（它才是选区/编辑状态的持有者），组件只负责"绑"。
    class GridPanel < Panel
      include Grid

      TICK_MS = 110

      window_key :global_key
      # 钩子按声明顺序执行；一次声明多个或分多次声明都可以（citrine #19 起可变参数），
      # 顺序必须是"先建视图态订阅、再起 ticker"，反之停的时候要对调
      on_mount :setup_view_state
      on_mount :start_ticker
      on_unmount :stop_ticker
      on_unmount :teardown_view_state

      def view
        render_grid
      end

      def global_key(ev)
        app.handle_key(ev)
      end

      # 定时清理上一次编辑的闪烁标注（框架无调度器，用原生定时器 + 生命周期管理）
      def start_ticker
        @ticker = Native(`window`).setInterval(-> { clear_flash }, TICK_MS)
      end

      def stop_ticker
        Native(`window`).clearInterval(@ticker) if @ticker
        @ticker = nil
      end
    end
  end
end
