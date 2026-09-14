# backtick_javascript: true
# frozen_string_literal: true

require "native"
require "citrine"
require_relative "common"
require_relative "../format"

module Sheets
  module Panels
    # 网格面板：列头 + 行头 + 全部单元格。
    #
    # 性能设计（1560 格仍要秒开、方向键要跟手）：
    #   单元格 = 外层 box + 内层 label，分别订阅**不同频率**的信号——
    #     · box   读 workbook.chrome_signal（错误态/数字右对齐/格式）与 app.view_signal（选中/闪烁）
    #     · label 读 workbook.value_signal（每次重算都可能变）
    #   于是改一个数只触发 1 次叶子重跑（0 个新建节点），
    #   移动选区只触发 2 个格子的 box 重建（约 4 个节点）。
    #   若把三者塞进同一个块，任何变化都要重建单元格，方向键会卡。
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
          box(css_class: "grid-corner") {}
          app.workbook.cols.times do |col|
            box(css_class: "grid-col-head") do
              # 读该列的视图信号 → 只有被选中的列头会重建
              box(css_class: app.col_signal(col).get ? "head-inner is-on" : "head-inner") do
                label(css_class: "head-text") { Format.column_label(col) }
              end
            end
          end
        end
      end

      def render_grid_body
        box(css_class: "grid-body", direction: :column) do
          app.workbook.rows.times do |row|
            box(css_class: "grid-row") do
              box(css_class: "grid-row-head") do
                box(css_class: app.row_signal(row).get ? "head-inner is-on" : "head-inner") do
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

      # 单个单元格：**两层**结构。
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
          css_class: -> { "cell #{cell_flags(row, col)}" },
          style: -> { cell_style(row, col) },
          on_click: -> { app.select_cell(row, col) }
        ) do
          label(css_class: "cell-text") { cell_text(row, col) }
        end
      end

      # 响应式属性：读 chrome（格式/错误态/类型）+ view（选中/闪烁）
      def cell_flags(row, col)
        chrome = app.workbook.chrome_signal(row, col).get
        view = app.view_signal(row, col).get
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
    end

    # 网格挂载根：一个组件 = 一整块区域（v1 无组件嵌套，见 FRICTION F5）
    #
    # 全局键盘与定时器在这里落地（G-9 / G-10）：
    #   · window_key  —— window 级 keydown，随组件卸载自动解绑（从前是外挂层自己
    #     持 window 引用 + beforeunload 清理）
    #   · on_mount/on_unmount —— 定时器的起与停交给框架生命周期
    # 键盘逻辑本身仍归 Application（它才是状态的持有者），组件只负责"绑"。
    class GridPanel < Panel
      include Grid

      TICK_MS = 110

      window_key :global_key
      on_mount :start_ticker
      on_unmount :stop_ticker

      def view
        render_grid
      end

      def global_key(ev)
        app.handle_key(ev)
      end

      # 定时清理上一次编辑的闪烁标注（框架无调度器，用原生定时器 + 生命周期管理）
      def start_ticker
        @ticker = Native(`window`).setInterval(-> { app.tick_visuals }, TICK_MS)
      end

      def stop_ticker
        Native(`window`).clearInterval(@ticker) if @ticker
        @ticker = nil
      end
    end
  end
end
