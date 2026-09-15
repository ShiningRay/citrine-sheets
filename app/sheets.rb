# backtick_javascript: true
# frozen_string_literal: true

# 浏览器入口（开发服务器请求 app/sheets.js 时编译本文件）：
#
#   bin/dev  →  http://localhost:4404/sheets.html
#
# 架构要点：**单一挂载根**（`#app`）——整棵组件树（工具条 / 公式栏 / 网格 / 检查器 /
# 状态栏 / 埋点）由 `Sheets::Application` 的 view 渲染，布局骨架与嵌套都在 Ruby 里。
# 从前这里是"六个空 div + 六次 mount_at + 一个共享普通对象"的绕法：v1 没有组件嵌套
# （FRICTION F5），一个根只能挂一个组件，所以布局只能写在 HTML 里、面板之间只能靠
# 共享对象通信。随 citrine PR #15 落地组件嵌套后，这些都回到了组件树里。
require "native"
require "citrine/browser"
require_relative "tokens"
require_relative "telemetry"
require_relative "application"
require_relative "seed"
require_relative "test_api"

# 设计令牌注入：app/tokens.rb 是唯一来源（原生 native/theme.rb 也从它派生），
# 这里在挂载前把 :root 变量写进页面，app/styles.css 的规则全部经 var(--x) 引用。
token_style = `document.createElement("style")`
`#{token_style}.textContent = #{Sheets::Tokens.css_root_block}`
`document.head.appendChild(#{token_style})`

Sheets::Telemetry.install!

app = Sheets::Application.new(clock: -> { `Date.now()` })
Sheets::Seed.load!(app.workbook)

mounted_at = `Date.now()`
Citrine::DomRenderer.mount_at("app", app)
Sheets::Telemetry.reset_round! # 挂载不算"一次编辑"
# 挂载耗时只有整棵树挂完之后才知道：回填给根组件，埋点面板读这个信号、立刻刷新一次
app.mark_mounted(`Date.now()` - mounted_at)

Sheets::TestApi.expose(app)
