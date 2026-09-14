# frozen_string_literal: true

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

      # 单个单元格：三层结构，每层只订阅一类信号。
      #
      # 为什么必须三层？v1 的 props 在**创建节点时**求值（apply_props 只在挂载时跑），
      # 而 `box(css_class: ...)` 的实参是在**外层块的执行中**求值的 —— 也就是说：
      # 谁调用 cell_class()，谁的 Effect 就订阅了这一格的信号。若把单元格直接建在
      # 行块里，行块就会订阅整行 26 格的信号，改任何一格都会重建整行
      # （实测：一次编辑新建 1903 个 DOM 节点）。隔离出一个单元，必须多包一层容器。
      #
      #   cell（静态：尺寸/边框/点击）        ← 由行块创建，不读任何信号
      #     cell-chrome（外观：选中/错误/加粗/底色/对齐） ← 读本格 chrome+view
      #       cell-text（值）                            ← 读本格值信号，只改文字
      def render_cell(row, col)
        box(css_class: "cell", on_click: -> { app.select_cell(row, col) }) do
          box(css_class: cell_class(row, col), style: cell_style(row, col)) do
            label(css_class: "cell-text") { cell_text(row, col) }
          end
        end
      end

      # 中层：读 chrome（格式/错误态/类型）+ view（选中/闪烁）
      def cell_class(row, col)
        chrome = app.workbook.chrome_signal(row, col).get
        view = app.view_signal(row, col).get
        classes = ["cell-chrome"]
        classes << "is-num" if chrome[:kind] == :number
        classes << "is-err" if chrome[:error]
        classes << "is-sel" if view[:selected]
        classes << "is-flash" if view[:flash]
        classes << "is-bold" if chrome[:bold]
        classes.join(" ")
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
    class GridPanel < Panel
      include Grid

      def view
        render_grid
      end
    end
  end
end
