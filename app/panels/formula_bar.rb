# backtick_javascript: true
# frozen_string_literal: true

require "citrine"
require_relative "common"

module Sheets
  module Panels
    # 公式栏：左侧显示当前地址，中间是编辑框，右侧是确认/取消。
    #
    # 编辑态与焦点是**本面板自己的视图关注点**：进入编辑态就把焦点送进输入框、
    # 离开就 blur（见 watch_edit_mode）。从前这是"Application 反向持有组件引用"的
    # 绕法（挂着 G-10/F7 的名），现在面板用 refs + 生命周期自己管——
    # 输入框所在的块也**不需要**再靠"永不重建"来保住焦点了：面板是 keyed 复用的
    # 子组件，结构变化只会移动/更新节点（F5/F6 已落地）。
    class FormulaBar < Panel
      include Common

      on_mount :watch_edit_mode
      on_unmount :stop_watching

      def view
        panel("panel-formula") do
          box(css_class: "fx-row") do
            label(css_class: "fx-name num") { app.selection_label }
            label(css_class: "fx-sym") { "fx" }
            text_input(
              value: app.edit_text,
              placeholder: "输入数值、文本，或以 = 开头的公式",
              on_enter: :commit_from_enter,
              ref: :input,
              css_class: "fx-input",
              # 元素级键盘（G-9）：从前靠外挂层判断 event.target 是不是 INPUT，
              # 现在由输入框自己声明它在编辑态要接管的键
              on_key: { "Escape" => :cancel_edit_key, "Tab" => :commit_tab }
            )
            box(css_class: "fx-buttons") do
              chip("确认 ↵", false, -> { app.commit_edit(1, 0) }, "chip-primary")
              chip("取消 Esc", false, -> { app.cancel_edit })
            end
          end

          box(css_class: "fx-hint") do # 读编辑态 / 提示
            mode = app.edit_mode.get
            notice = app.notice.get
            text = mode ? "编辑中（Enter 确认并下移 · Esc 取消）" : notice[:text]
            label(css_class: mode ? "hint is-edit" : "hint") { text }
          end
        end
      end

      # ── 编辑态 → 焦点（本面板订阅共享的编辑状态）──────────────
      #
      # 焦点是"看一个信号、不渲染"的场景，所以是一个独立的 Effect（框架还没有
      # effect/watch 宏）：挂载时建立、卸载时 dispose，复用（keyed）时不重建。
      def watch_edit_mode
        @edit_watch = Citrine::Effect.create { sync_focus(app.edit_mode.get) }
      end

      def stop_watching
        @edit_watch&.dispose
        @edit_watch = nil
      end

      def sync_focus(editing)
        editing ? focus_input : blur_input
      end

      def commit_from_enter
        app.on_enter_commit
      end

      # 元素级键盘（G-9）：处理器收到框架归一化的 KeyEvent
      def cancel_edit_key
        app.cancel_edit
      end

      def commit_tab(ev)
        ev.prevent_default # Tab 不该把焦点移走
        app.commit_edit(0, ev.shift? ? -1 : 1)
      end

      # ── 原生焦点控制 ────────────────────────────────────────
      #
      # 元素句柄由框架的 ref: 提供（G-10）：refs[:input] 就是 DOM 元素本身，
      # 不再需要"App 持有组件实例 → 组件持有 node → node.dom"那条链。
      #
      # 注意：必须走 Ruby 侧方法调用——Native::Object 会把 focus/blur 转发给底层
      # JS 对象；若写进反引号里插值，`#{el}` 得到的是包装器对象本身而非 DOM 元素，
      # `el.focus` 会是 undefined（实测踩过，见 FRICTION-2 的 G-5）。
      def focus_input
        el = refs[:input]
        return self unless el

        el.focus
        set_caret_to_end(el)
        self
      end

      def blur_input
        el = refs[:input]
        return self unless el

        el.blur
        self
      end

      def set_caret_to_end(el)
        el.setSelectionRange(el.value.length, el.value.length)
      rescue StandardError
        nil
      end

      # 桩诊断用：报告节点与原生方法可见性
      def debug_focus_state
        el = refs[:input]
        active = Native(`document.activeElement`)
        "input_assigned=#{!el.nil?} dom_assigned=#{!el.nil?} " \
          "has_focus=#{`typeof #{Native(el)}.focus`} " \
          "active=#{active ? active[:className].to_s : 'none'}"
      end
    end
  end
end
