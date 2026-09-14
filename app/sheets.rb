# backtick_javascript: true
# frozen_string_literal: true

# 浏览器入口（开发服务器请求 app/sheets.js 时编译本文件）：
#
#   bin/dev  →  http://localhost:4404/sheets.html
#
# 架构要点：**六个挂载根共享一个普通 Ruby 对象（Application）**。
# 之所以不是一棵组件树，是因为 citrine v1 没有组件嵌套（FRICTION F5）；
# 之所以能这样拆，是因为 0.1.1 修好了 F2（mount_at 复用渲染器实例，
# 多根不会再互相清空）——本 demo 是对那次修复的真实应用级验证。
require "native"
require "citrine/browser"
require_relative "telemetry"
require_relative "application"
require_relative "seed"
require_relative "panels/toolbar"
require_relative "panels/formula_bar"
require_relative "panels/grid"
require_relative "panels/inspector"
require_relative "panels/status_bar"
require_relative "panels/debug_bar"
require_relative "glue"

Sheets::Telemetry.install!

app = Sheets::Application.new(clock: -> { `Date.now()` })
Sheets::Seed.load!(app.workbook)

editor = Sheets::Panels::FormulaBar.new(app)
app.attach_editor(editor)

mount_started = `Date.now()`
Citrine::DomRenderer.mount_at("panel-toolbar", Sheets::Panels::Toolbar.new(app))
Citrine::DomRenderer.mount_at("panel-formula", editor)
Citrine::DomRenderer.mount_at("panel-grid", Sheets::Panels::GridPanel.new(app))
Citrine::DomRenderer.mount_at("panel-inspector", Sheets::Panels::Inspector.new(app))
Citrine::DomRenderer.mount_at("panel-status", Sheets::Panels::StatusBar.new(app))
Sheets::Telemetry.mount_ms = `Date.now()` - mount_started
Sheets::Telemetry.reset_round! # 挂载不算"一次编辑"
# 埋点面板最后挂载：这样它首次渲染就能显示真实挂载耗时，且本轮计数从 0 开始
Citrine::DomRenderer.mount_at("panel-debug", Sheets::Panels::DebugBar.new(app))

glue = Sheets::Glue.new(app)
glue.start
glue.expose_test_api
