# backtick_javascript: true
# frozen_string_literal: true

# 探针 D（真实浏览器）：问题 3（transition/animation vs 块重建）、问题 9（CSSOM 真值）、
# 问题 2（焦点/输入丢失）、问题 7/10（崩溃复现）、仓库自带 TodoApp 的真实观感，
# 外加：同一页面两次 mount_at 会互相破坏（Q10 的额外静默失败入口）
require "citrine/browser"
require "components" # examples/components.rb 里的真实 TodoApp

class NumStyle < Citrine::Component
  def view
    box(css_class: "numwrap") do
      # 数字值（无单位）——案例来自 examples/components.rb:44 (border_radius: 20)
      label(css_class: "num-bad",
            style: { width: 18, height: 18, border_radius: 20, font_size: 15, font_weight: "600" }) { "bad" }
      # 字符串带单位（对照组）
      label(css_class: "num-ok",
            style: { width: "180px", height: "18px", border_radius: "20px", font_size: "15px" }) { "ok" }
      # 框架只认 css_class/placeholder/style/on_click，其它 HTML 属性全部静默丢弃
      button(css_class: "attr-test", id: "my-id", disabled: true, title: "hello",
             data_role: "primary", aria_label: "关闭") { "禁用我" }
    end
  end
end

class AnimWidget < Citrine::Component
  state :items, default: %w[a b c]
  state :faded, default: false

  def view
    box(css_class: "animwrap") do
      items.each_with_index do |it, i|
        box(css_class: "anim") { label { "#{it}#{i}" } }
      end
      box(css_class: "trans", style: { transition: "opacity 5s linear", opacity: 1 }) { label { "t" } }
      # 由 state 驱动的过渡：value 变化 → 块重建 → 新节点天生就是终值
      box(css_class: "trans-state",
          style: { transition: "opacity 5s linear", opacity: faded ? 0.2 : 1 }) { label { "s" } }
      button(css_class: "anim-add", on_click: :add) { "add" }
      button(css_class: "trans-toggle", on_click: :toggle) { "fade" }
    end
    # 对照组：位于不参与重建的块里（顶层兄弟，自己的 block 不读任何信号）
    box(css_class: "anim anim-static") { label { "static" } }
  end

  def add
    self.items = items + ["d"]
  end

  def toggle
    self.faded = !faded
  end
end

class FocusWidget < Citrine::Component
  state :items, default: %w[one two three]
  state :draft, default: ""

  def view
    box(css_class: "focuswrap") do
      items.each_with_index do |it, i|
        box(css_class: "focus-row") do
          label { it }
          text_input(css_class: "focus-input", placeholder: "第#{i}行")
        end
      end
      text_input(css_class: "focus-draft", value: signal(:draft), on_enter: :noop)
      button(css_class: "focus-add", on_click: :add) { "add" }
    end
  end

  def noop; end

  def add
    self.items = items + ["new"]
  end
end

class CrashWidget < Citrine::Component
  state :q, default: ""

  def view
    box(css_class: "crashwrap") do
      t = q # ← 让这个块订阅 q（等价于"输入框所在容器读了输入框自己的信号"）
      text_input(css_class: "crash-input", value: signal(:q))
      label(css_class: "crash-echo") { "echo=#{t}" }
    end
  end
end

class MiniCounter < Citrine::Component
  state :n, default: 0

  def view
    box(css_class: "mini") do
      label(css_class: "mini-label") { "n=#{n}" }
      button(css_class: "mini-btn", on_click: :inc) { "+1" }
    end
  end

  def inc
    self.n += 1
  end
end

# ── 主测量组：共享一个渲染器（mount_at 每次都换新渲染器，会互相破坏）──
R = Citrine::DomRenderer.new
Citrine.renderer = R
R.mount_component(NumStyle.new, R.document_element("app1"))
R.mount_component(AnimWidget.new, R.document_element("app2"))
R.mount_component(FocusWidget.new, R.document_element("app3"))
R.mount_component(CrashWidget.new, R.document_element("app4"))
R.mount_component(TodoApp.new, R.document_element("todo"))

# 注：MiniCounter 留给 probe_e.rb（两次 mount_at 的坑单独测，避免污染本页测量）
