# frozen_string_literal: true

require "citrine"
require_relative "common"
require_relative "../tokens"

module Sheets
  module Panels
    # 工具条：撤销/重做、格式、清空、重算
    class Toolbar < Panel
      include Common

      def view
        panel("panel-toolbar") do # 不读信号
          box(css_class: "tb-row") do # 容器块不读信号：各小组各自订阅（避免整条工具条重建）
            box(css_class: "tb-group", direction: :row, gap: 6) do # 读选区
              label(css_class: "tb-selection num") { app.selection_label }
              label(css_class: "tb-dims") { "#{app.workbook.rows} 行 × #{app.workbook.cols} 列" }
            end

            box(css_class: "tb-group", direction: :row, gap: 6) do # 读 last_action（历史深度随之刷新）
              action = app.last_action.get
              chip("↶ 撤销 #{app.workbook.undo_depth}", false, -> { app.undo }, "chip-icon")
              chip("↷ 重做 #{app.workbook.redo_depth}", false, -> { app.redo }, "chip-icon")
              label(css_class: "tb-action") { action }
            end

            box(css_class: "tb-group", direction: :row, gap: 6) do
              chip("B 加粗", false, -> { app.apply_chrome(bold: true) }, "chip-bold")
              chip("常规", false, -> { app.apply_chrome(bold: false) })
              chip("底色", false, -> { app.apply_chrome(bg: Tokens[:swatch_amber]) }, "swatch swatch-amber")
              chip("底色", false, -> { app.apply_chrome(bg: Tokens[:swatch_green]) }, "swatch swatch-green")
              chip("底色", false, -> { app.apply_chrome(bg: Tokens[:swatch_red]) }, "swatch swatch-red")
              chip("无底色", false, -> { app.apply_chrome(bg: nil) })
            end

            box(css_class: "tb-group", direction: :row, gap: 6) do
              chip("自动", false, -> { app.apply_chrome(decimals: nil) })
              chip("0 位", false, -> { app.apply_chrome(decimals: 0) })
              chip("2 位", false, -> { app.apply_chrome(decimals: 2) })
              chip("4 位", false, -> { app.apply_chrome(decimals: 4) })
            end

            box(css_class: "tb-group", direction: :row, gap: 6) do
              chip("清空选区", false, -> { app.clear_selection }, "chip-danger")
              chip("重算全部", false, -> { app.recalculate_all })
            end
          end
        end
      end
    end
  end
end
