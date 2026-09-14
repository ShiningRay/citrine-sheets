# backtick_javascript: true
# frozen_string_literal: true

# 桩验收驱动接口（demo 专用，非框架 API）。
#
# 这里从前是 `glue.rb`——150 行的浏览器外挂层：window 级键盘、setInterval 定时器、
# beforeunload 清理、原生 focus/blur、以及这个调试接口。前四样在 Citrine 0.1.1
# 之后都有了框架入口（G-9 / G-10）：
#   · 全局键盘      → GridPanel 的 `window_key :global_key`
#   · 定时器        → GridPanel 的 `on_mount` / `on_unmount`
#   · 原生焦点      → FormulaBar 自己订阅 edit_mode（`refs[:input]` + 一个 Effect）
#   · 输入框内按键  → FormulaBar 的 `on_key: { "Escape" => …, "Tab" => … }`
# 只剩这个"给无头测试用"的钩子没有框架形态，留在这里。
require "native"
require "citrine"

module Sheets
  module TestApi
    module_function

    # 卸载整棵组件树（验证生命周期收尾：解绑全局键盘、停掉面板自己的定时器、清空挂载点）
    def unmount(app)
      Citrine.unmount(app)
      true
    end

    def expose(app)
      breakdown = Sheets::Telemetry.breakdown.map { |k, v| "#{k}:#{v}" }.join(", ")
      `window.sheetsTestApi = {
         state: function () {
           // 闪烁格数从 DOM 现取：视图态（选中/闪烁）由网格面板持有，
           // 应用对象已经看不到它——直接数 class 反而更接近"用户看到的样子"
           return #{app}.$test_state_text() + "|flash=" + document.querySelectorAll(".cell.is-flash").length;
         },
         breakdown: function () { return #{breakdown.inspect}; },
         resizeGrid: function (rows, cols) { #{app}.$resize_grid(rows, cols); return true; },
         unmount: function () { return Opal.Sheets.TestApi.$unmount(#{app}); }
       }`
      true
    end
  end
end
