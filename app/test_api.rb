# backtick_javascript: true
# frozen_string_literal: true

# 桩验收驱动接口（demo 专用，非框架 API）。
#
# 这里从前是 `glue.rb`——150 行的浏览器外挂层：window 级键盘、setInterval 定时器、
# beforeunload 清理、原生 focus/blur、以及这个调试接口。前四样在 Citrine 0.1.1
# 之后都有了框架入口（G-9 / G-10）：
#   · 全局键盘      → GridPanel 的 `window_key :global_key`
#   · 定时器        → GridPanel 的 `on_mount` / `on_unmount`
#   · 原生焦点      → FormulaBar 的 `ref: :input` + `refs[:input]`
#   · 输入框内按键  → FormulaBar 的 `on_key: { "Escape" => …, "Tab" => … }`
# 只剩这个"给无头测试用"的钩子没有框架形态，留在这里。
require "native"
require "citrine"

module Sheets
  module TestApi
    module_function

    def expose(app)
      breakdown = Sheets::Telemetry.breakdown.map { |k, v| "#{k}:#{v}" }.join(", ")
      `window.sheetsTestApi = {
         state: function () { return #{app}.$test_state_text(); },
         tick: function () { #{app}.$tick_visuals(); },
         breakdown: function () { return #{breakdown.inspect}; },
         focusEditor: function () { #{app}.$focus_editor(); return document.activeElement ? document.activeElement.className : "none"; }
       }`
      true
    end
  end
end
