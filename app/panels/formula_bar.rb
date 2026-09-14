# backtick_javascript: true
# frozen_string_literal: true

require "citrine"
require_relative "common"

module Sheets
  module Panels
    # 公式栏：左侧显示当前地址，中间是编辑框，右侧是确认/取消。
    #
    # ★ 编辑框挂在"只执行一次的块"里——这是键盘可用的前提：
    #   输入框一旦被重建就会丢焦点、丢输入法状态。所以本面板的
    #   fx-row 块不读任何信号，只有旁边的标签各自读信号。
    #   （market demo 里同样的纪律只是性能问题，这里是功能问题。）
    class FormulaBar < Panel
      include Common

      def view
        panel("panel-formula") do # 不读信号
          box(css_class: "fx-row") do # 不读信号：输入框必须挂在这里
            label(css_class: "fx-name num") { app.selection_label }
            label(css_class: "fx-sym") { "fx" }
            @input = text_input(
              value: app.edit_text,
              placeholder: "输入数值、文本，或以 = 开头的公式",
              on_enter: :commit_from_enter,
              css_class: "fx-input"
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

      def commit_from_enter
        app.on_enter_commit
      end

      # ── 原生焦点控制（v1 无 ref / 生命周期，只能由 App 持引用调用）──
      #
      # 注意：这里必须走 Ruby 侧方法调用——Native::Object 会把 focus/blur 转发给
      # 底层 JS 对象。若写进反引号里插值，`#{el}` 得到的是包装器对象本身而非
      # DOM 元素，`el.focus` 会是 undefined（实测踩过，见 FRICTION-2 的 G-6）。
      def focus_input
        el = @input&.dom
        return self unless el

        el.focus
        set_caret_to_end(el)
        self
      end

      def blur_input
        el = @input&.dom
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
        el = @input&.dom
        active = Native(`document.activeElement`)
        "input_assigned=#{!@input.nil?} dom_assigned=#{!el.nil?} " \
          "has_focus=#{`typeof #{Native(el)}.focus`} " \
          "active=#{active ? active[:className].to_s : 'none'}"
      end
    end
  end
end
