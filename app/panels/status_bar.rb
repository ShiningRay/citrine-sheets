# frozen_string_literal: true

require "citrine"
require_relative "common"

module Sheets
  module Panels
    # 状态栏：选区聚合统计 + 工作簿统计
    class StatusBar < Panel
      include Common

      def view
        panel("panel-status") do # 不读信号
          box(css_class: "st-row") do # 读选区（并订阅范围内的值）
            stats = app.live_stats
            action = app.last_action.get
            box(css_class: "st-group", direction: :row, gap: 14) do
              label(css_class: "st-label") { "选区" }
              stat("单元格", stats[:cells].to_s)
              stat("数值", stats[:numeric_count].to_s)
              stat("求和", stats[:sum].nil? ? "—" : Sheets::Format.compact(stats[:sum]))
              stat("平均", stats[:average].nil? ? "—" : Sheets::Format.compact(stats[:average]))
              stat("最小", stats[:min].nil? ? "—" : Sheets::Format.compact(stats[:min]))
              stat("最大", stats[:max].nil? ? "—" : Sheets::Format.compact(stats[:max]))
              stat("错误", stats[:errors].to_s)
            end
          end

          label(css_class: "st-summary dim small") do # 读 last_action → 跟随编辑刷新
            app.last_action.get
            app.sheet_summary
          end
        end
      end

      def stat(label_text, value_text)
        box(css_class: "st-stat", direction: :row) do
          label(css_class: "st-k") { label_text }
          label(css_class: "st-v num") { value_text }
        end
      end
    end
  end
end
