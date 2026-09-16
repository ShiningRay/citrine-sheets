# frozen_string_literal: true

require "citrine"
require_relative "../format"

module Sheets
  module Panels
    # 所有面板组件的基类。
    #
    # 面板是**真正的子组件**：`Application`（根组件）在自己的 view 里用 `components`
    # 关键字渲染它们（组件嵌套已随 citrine PR #15 落地），共享的运行期状态——工作簿、
    # 选区、编辑缓冲——经 prop `app` 传入，动作经 prop 上的回调 Proc 回传。
    # 面板自己的状态（公式栏的焦点、网格的选中/闪烁高亮）留在面板实例里。
    class Panel < Citrine::Component
      prop :app
    end

    # 面板公共构件与视图层纪律。
    #
    # 两条纪律都关于**更新粒度**（与结构增删无关——后者由 `key:` 负责）：
    #   1. 容器块的 block **不读任何信号** —— 块读什么就订阅什么，容器读信号 =
    #      数据一变就重跑整棵子树；
    #   2. 会变的值放进最内层叶子块（或在元素上写成响应式属性 `css_class: -> { }`）——
    #      只改文字/属性，**0 个新建节点**。
    #
    # 从前这里还有第三条："公式栏的输入框必须挂在永不重建的块里，否则一改选区就丢焦点"。
    # 那条纪律是**重建语义**下的产物：现在输入框所在的面板是 keyed 复用的子组件，
    # 结构变化只会移动/更新节点，不会再把它换掉（FRICTION F5/F6 已落地）。
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

      # key 用于"身份稳定的重复结构"（如依赖标签列表）：给了 key 的节点会按 key 复用，
      # 列表重排/增删时不换 DOM 节点，也就不会丢事件、丢焦点、丢输入法状态。
      # chip：语义上是按钮——走 Beryl::Button（kind/size/disabled 契约统一），
      # 保留 chip/is-on 类名：样式与桩断言（按 .chip 类 + 文本找节点）零改动。
      # active 传 Proc 时为响应式激活态：class 在本节点的属性 Effect 里现求值
      # （换选中 / 改格式只重设 class，不重建工具条）。
      # 必须经 render()（keyed 组件槽位）而不是 .new().view：后者每次父重渲染都
      # 新建实例，元素 owner 随之更换，keyed/位置复用全部失效（依赖标签的
      # DOM 身份断言抓过这一笔）。
      def chip(text, active, handler, extra_class = nil, key: nil)
        extra = extra_class ? [extra_class] : []
        if active.is_a?(Proc)
          render(Beryl::Button, text: text, kind: :ghost, size: :sm,
                                css_class: -> { ["chip", active.call ? "is-on" : nil].concat(extra).compact.join(" ") },
                                on_click: handler, key: key)
        else
          render(Beryl::Button, text: text, kind: :ghost, size: :sm,
                                css_class: ["chip", active ? "is-on" : nil].concat(extra).compact.join(" "),
                                on_click: handler, key: key)
        end
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
