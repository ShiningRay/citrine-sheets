# frozen_string_literal: true

require "citrine"
require_relative "../format"

module Sheets
  module Panels
    # 所有面板组件的基类：持有共享 Application，自身只负责渲染与转发动作。
    # v1 没有组件嵌套（FRICTION F5），"面板"是一组平级的挂载根而非父子组件——
    # 状态因此必须放在 Application 上，而不是组件实例里。
    class Panel < Citrine::Component
      def initialize(app)
        super({})
        @app = app
      end

      attr_reader :app
    end

    # 面板公共构件与视图层纪律（与 market demo 同源，但这里多了一条硬约束）
    #
    # 三条纪律：
    #   1. 容器块的 block **不读任何信号** —— 否则每次数据变化都会重建整棵子树；
    #   2. 会变的数字放进最内层叶子块 —— 叶子只改文字，0 个 DOM 节点重建；
    #   3. 公式栏的输入框必须挂在**永不重建**的块里，否则获得焦点后一改选区
    #      就被销毁重建、焦点丢失（v1 没有 keyed 复用，FRICTION F6）。
    module Common
      private

      def panel(css_class, &block)
        box(css_class: "panel #{css_class}", direction: :column, &block)
      end

      def panel_head(title, &tools)
        box(css_class: "panel-head") do
          label(css_class: "panel-title") { title }
          if tools
            box(css_class: "panel-tools", direction: :row, gap: 6) { tools.call }
          else
            box(css_class: "panel-tools", direction: :row, gap: 6) {}
          end
        end
      end

      def chip(text, active, handler, extra_class = nil)
        classes = ["chip"]
        classes << "is-on" if active
        classes << extra_class if extra_class
        button(on_click: handler, css_class: classes.join(" ")) { text }
      end

      def kv(label_text, value_text, value_class = nil)
        box(css_class: "kv", direction: :row) do
          label(css_class: "kv-k") { label_text }
          label(css_class: ["kv-v", value_class].compact.join(" ")) { value_text }
        end
      end
    end
  end
end
