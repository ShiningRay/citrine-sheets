# frozen_string_literal: true

module Sheets
  # 设计令牌唯一来源：浏览器 CSS、浏览器视图内联样式、原生自绘三处共用。
  #
  # - 浏览器：入口（sheets.rb）在挂载前把 `css_root_block` 注入为
  #   `<style>:root{…}</style>`；app/styles.css 的规则全部经 var(--x) 引用，
  #   样式表里不再出现字面量色值（罕见的浏览器表现层小技巧除外，见 styles.css 注释）。
  # - 原生：native/theme.rb 从这里派生常量，自绘代码照旧引用 Theme::XXX。
  #
  # 为什么是 Ruby 而不是 CSS：原生后端没有 CSS（样式矩阵 L1/L2 之外不可着色），
  # 令牌放 CSS 里原生就拿不到——放 Ruby 里则 Opal 与 CRuby 都能加载，天然两栖。
  # 改配色只改这一个文件；机器守卫在 test/tokens_test.rb
  # （HTML 不内联样式 / CSS 引用的每个 --var 都有令牌 / 令牌都有去向）。
  #
  # 8 位 hex（#rrggbbaa）与 rgba() 等价：浏览器（CSS Color 4）与 Painter
  # （native-area.md 2.2）都接受，令牌里统一存 8 位形式，两侧不再各写各的。
  module Tokens
    MAP = {
      bg: "#080d18",
      panel: "#101a2e",
      panel_2: "#14203a",
      cell: "#0e1626",
      cell_alt: "#0b1220",
      line: "#1e2c48",
      line_soft: "#17233b",
      text: "#e6ecf8",
      dim: "#7a88a3",
      accent: "#4f9cf9",
      accent_soft: "#4f9cf929",   # rgba(79,156,249,.16)
      flash: "#d8a13a",
      flash_soft: "#d8a13a38",    # rgba(216,161,58,.22)
      danger: "#f2686f",
      ok: "#30c48d",
      # 语义态色（浏览器 CSS 与原生自绘同用：选区 / 选中+闪烁 / 编辑态）
      cell_sel: "#16294a",        # .cell.is-sel 的底色
      cell_sel_flash: "#2b3448",  # .cell.is-sel.is-flash 的底色
      edit_fill: "#0d1728",       # .fx-input:focus / 原生编辑态的底色
      # 工具条底色按钮（toolbar.rb 的 apply_chrome 参数 + 原生 Theme::SWATCH_*）
      swatch_amber: "#3a2f14",
      swatch_green: "#12351f",
      swatch_red: "#3a1a22"
    }.freeze

    def self.[](name)
      MAP.fetch(name)
    end

    # 注入页面用的 `:root` 块（键名 snake_case → CSS 的 kebab-case）
    def self.css_root_block
      rows = MAP.map { |name, value| "  --#{name.to_s.tr('_', '-')}: #{value};" }
      ":root {\n#{rows.join("\n")}\n}"
    end
  end
end
