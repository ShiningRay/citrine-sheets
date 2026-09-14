# frozen_string_literal: true

require "citrine"
require_relative "common"
require_relative "../telemetry"

module Sheets
  module Panels
    # 埋点面板：一轮编辑/重建里框架实际做了多少工作。
    # v1 没有官方可观测性钩子（FRICTION F9），计数器由 Telemetry 包装框架内部得到。
    class DebugBar < Panel
      include Common

      def view
        panel("panel-debug") do # 不读信号
          box(css_class: "dbg-row") do # 读 last_action → 每次编辑后刷新
            app.last_action.get
            report = Sheets::Telemetry.report
            box(css_class: "dbg-group", direction: :row, gap: 14) do
              metric("挂载耗时", "#{report[:mount_ms]} ms")
              metric("本次编辑 Effect 重跑", report[:effect_runs].to_s)
              metric("本次编辑新建 DOM", report[:node_creates].to_s)
              metric("累计 Effect 重跑", report[:total_effect_runs].to_s)
              metric("累计新建 DOM", report[:total_node_creates].to_s)
              metric("信号对象", app.signal_count.to_s)
              metric("编辑轮次", report[:rounds].to_s)
            end
          end
          box(css_class: "dbg-note") do
            label do
              "口径：一次编辑 = 从动作开始到发布完成。统计含本面板自身的重建；" \
              "方括号为框架缺口编号（F1/F2/F3/F6/F7/F9/F17/F19/F20）"
            end
          end
        end
      end

      def metric(label_text, value_text)
        box(css_class: "dbg-metric", direction: :column) do
          label(css_class: "dbg-k") { label_text }
          label(css_class: "dbg-v num") { value_text }
        end
      end
    end
  end
end
