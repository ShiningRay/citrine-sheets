# frozen_string_literal: true

require "citrine"
require_relative "common"
require_relative "../telemetry"

module Sheets
  module Panels
    # 埋点面板：一轮编辑/重建里框架实际做了多少工作。
    # 这些数字来自 Telemetry 对框架内部的包装（v1 没有官方可观测性钩子 —— FRICTION F9）；
    # 挂载耗时不是"一轮工作"而是启动事实，所以它是 Application 自己的信号（mark_mounted）。
    class DebugBar < Panel
      include Common

      def view
        panel("panel-debug") do
          # 外层块读 last_action（每次动作刷新）与 mount_ms（挂载耗时回填后刷新）：
          # report 是外层块的局部变量，只有外层重跑才会重新取值——挂载耗时的信号
          # 必须在外层读，否则内层块会拿着挂载时刻的旧快照渲染。
          box(css_class: "dbg-row") do
            app.last_action.get
            app.mount_ms
            report = Sheets::Telemetry.report
            box(css_class: "dbg-group", direction: :row, gap: 14) do
              metric("挂载耗时", "#{app.mount_ms} ms")
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
              "方括号是框架缺口编号（仍开着：F3 批量更新 / F9 官方埋点钩子；F1/F2/F5/F6/F7/F10 已落地）"
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
