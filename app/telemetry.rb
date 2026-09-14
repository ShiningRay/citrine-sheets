# frozen_string_literal: true

require "citrine"

module Sheets
  # 极简埋点：包装框架内部计数（v1 没有官方可观测性钩子 —— FRICTION F9）。
  #
  #   Effect#run          → 一次"块重跑"
  #   DomRenderer#create_dom → 一次 DOM 元素创建
  #
  # 一轮 = 一次用户动作（编辑/撤销/格式/清空…），由 Application 在动作开始时
  # 调用 begin_round! 重置计数，面板显示"这次动作让框架做了多少事"。
  module Telemetry
    class << self
      def install!
        wrap_effect!
        wrap_dom! if defined?(Citrine::DomRenderer)
        reset_counters!
        true
      end

      def begin_round!
        reset_round!
        self.rounds = rounds.to_i + 1
      end

      # 只清空"本轮"计数（挂载完成后调用，避免把挂载算成一次编辑）
      def reset_round!
        self.round_effects = 0
        self.round_nodes = 0
        self.breakdown = {}
      end

      def count_effect
        self.round_effects = round_effects.to_i + 1
        self.total_effects = total_effects.to_i + 1
      end

      def count_node(node = nil)
        self.round_nodes = round_nodes.to_i + 1
        self.total_nodes = total_nodes.to_i + 1
        return if node.nil?

        key = node.props[:css_class].to_s.split(" ").first
        key = node.type.to_s if key.to_s.empty?
        self.breakdown = (breakdown || {})
        self.breakdown[key] = (breakdown[key] || 0) + 1
      end

      def report
        {
          effect_runs: round_effects.to_i,
          node_creates: round_nodes.to_i,
          total_effect_runs: total_effects.to_i,
          total_node_creates: total_nodes.to_i,
          rounds: rounds.to_i
        }
      end

      attr_accessor :rounds, :round_effects, :round_nodes, :total_effects, :total_nodes,
                    :breakdown
      # 网格的视图信号（选中/闪烁/行列高亮）由 GridPanel 持有，但它算进"信号对象数"
      # 这个应用级指标：面板在分配信号时上报总数、卸载时归零。
      attr_accessor :view_signals

      private

      def reset_counters!
        self.rounds ||= 0
        self.total_effects ||= 0
        self.total_nodes ||= 0
        reset_round!
      end

      def wrap_effect!
        return if Citrine::Effect.method_defined?(:run_without_telemetry)

        Citrine::Effect.class_eval do
          alias_method :run_without_telemetry, :run
          define_method(:run) do
            Sheets::Telemetry.count_effect
            run_without_telemetry
          end
        end
      end

      def wrap_dom!
        return if Citrine::DomRenderer.method_defined?(:create_without_telemetry)

        Citrine::DomRenderer.class_eval do
          alias_method :create_without_telemetry, :create_dom
          define_method(:create_dom) do |node|
            Sheets::Telemetry.count_node(node)
            create_without_telemetry(node)
          end
        end
      end
    end
  end
end
