# backtick_javascript: true
# frozen_string_literal: true

# 探针 E：同一页面调用两次官方入口 DomRenderer.mount_at
# （各自的 state 更新会重跑块 → 块内 emit → 走全局 Citrine.renderer）
require "citrine/browser"

class MiniList < Citrine::Component
  state :items, default: %w[a]

  def view
    box(css_class: "mini") do
      items.each_with_index { |it, i| box(css_class: "mini-item") { label { "#{it}#{i}" } } }
      button(css_class: "mini-btn", on_click: :add) { "add" }
    end
  end

  def add
    self.items = items + ["x"]
  end
end

Citrine::DomRenderer.mount_at("app5", MiniList.new) # 第一次
Citrine::DomRenderer.mount_at("app6", MiniList.new) # 第二次 → 全局 Citrine.renderer 被替换
