# frozen_string_literal: true

require "citrine"
require_relative "common"
require_relative "../format"

module Sheets
  module Panels
    # 检查器：当前格的内容/值/类型 + 依赖关系（可直接跳转）+ 上次重算报告
    class Inspector < Panel
      include Common

      def view
        panel("panel-inspector") do # 不读信号
          panel_head("单元格检查器") {}

          box(css_class: "ins-body", direction: :column) do # 读选区与当前格
            info = app.active_info
            kv("地址", info[:key_label], "num")
            kv("原始输入", info[:raw].to_s.empty? ? "（空）" : info[:raw].to_s)
            kv("计算值", info[:display].to_s.empty? ? "（空）" : info[:display].to_s)
            kv("类型", info[:kind_label])
          end

          box(css_class: "ins-section", direction: :column) do # 读依赖
            deps = app.active_dependencies
            box(css_class: "ins-title") do
              label { "← 本格引用了 #{deps.size} 格（点击跳转）" }
            end
            box(css_class: "ins-chips") do
              if deps.empty?
                label(css_class: "dim small") { "无（不是公式格）" }
              else
                deps.first(40).each do |(row, col)|
                  key = Format.cell_key(row, col)
                  chip(key, false, -> { app.select_cell(row, col) }, "chip-cell", key: key)
                end
              end
            end
          end

          box(css_class: "ins-section", direction: :column) do # 读反向依赖
            dependents = app.active_dependents
            box(css_class: "ins-title") do
              label { "→ 有 #{dependents.size} 格引用本格（点击跳转）" }
            end
            box(css_class: "ins-chips") do
              if dependents.empty?
                label(css_class: "dim small") { "无" }
              else
                dependents.first(40).each do |(row, col)|
                  key = Format.cell_key(row, col)
                  chip(key, false, -> { app.select_cell(row, col) }, "chip-cell", key: key)
                end
              end
            end
          end

          box(css_class: "ins-section", direction: :column) do # 读重算报告
            report = app.recalc_view.get
            box(css_class: "ins-title") do
              label { "上次重算" }
            end
            kv("动作", report[:label].to_s)
            kv("重算格数", report[:computed].to_i.to_s, "num")
            kv("显示变化", report[:cells].to_i.to_s, "num")
            kv("循环引用", report[:cyclic].to_i.to_s, "num")
            kv("耗时", "#{report[:elapsed].to_i} ms", "num")
          end

          box(css_class: "ins-section", direction: :column) do # 静态提示（不读信号）
            box(css_class: "ins-title") do
              label { "试试看" }
            end
            label(css_class: "hint-line") { "改 B2 的收入数字 → 看『重算格数』与黄色闪烁" }
            label(css_class: "hint-line") { "选中 E2：它引用了 D2 与 B2（可点击跳转）" }
            label(css_class: "hint-line") { "改 C20 涨价系数 → 情景分析整块重算" }
            label(css_class: "hint-line") { "选中 B29/B30 → 循环引用 (#CIRC!)" }
            label(css_class: "hint-line") { "⌘Z / ⌘⇧Z 撤销重做 · ⌘B 加粗 · ⌘↑↓←→ 跳到边缘" }
          end
        end
      end
    end
  end
end
