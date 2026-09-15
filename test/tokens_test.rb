# frozen_string_literal: true

# 设计令牌守卫：令牌唯一来源是 app/tokens.rb（浏览器 CSS / 浏览器视图 / 原生
# theme.rb 三处共用），这里把"唯一"锁死——
#
#   1. HTML 不再内嵌 <style>，样式抽在 app/styles.css（<link> 引入）；
#   2. styles.css 里引用的每个 var(--x) 都有令牌（拼写漂移当场红）；
#   3. 每个令牌都有去向：要么被 styles.css 引用，要么在白名单里注明使用方；
#   4. 原生 theme.rb 只准保留 FORMULA 一个本地色值（原生独有的公式格色）。
#
# 纯 CRuby 文件对拍，不需要 Opal / 浏览器 / 真窗口。
#
#   rake test
require "minitest/autorun"
require_relative "../app/tokens"

class TokensTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # 不进 CSS 的令牌（使用方注明）：
  #   cell_alt / ok —— 调色板保留槽位，当前无消费者（原生 theme 仅透传）；
  #   swatch_*      —— 浏览器 toolbar.rb 与原生 Theme::SWATCH_* 直接取值（不经过 CSS）。
  NOT_IN_CSS = %i[cell_alt ok swatch_amber swatch_green swatch_red].freeze

  def read(name)
    File.read(File.join(ROOT, name), encoding: "UTF-8")
  end

  # 去掉 CSS 注释再扫：守卫针对的是规则与真实引用，不是说明文字
  def css_rules
    @css_rules ||= read("app/styles.css").gsub(/\/\*.*?\*\//m, "")
  end

  def css_var_refs
    css_rules
      .scan(/var\(--([a-z0-9-]+)[),]/)
      .flatten
      .map { |name| name.tr("-", "_").to_sym }
      .uniq
  end

  def test_html_has_no_inline_styles_and_links_the_stylesheet
    html = read("app/sheets.html")
    refute_includes html, "<style>", "HTML 里不允许再内嵌样式（样式在 app/styles.css）"
    assert_includes html, %(<link rel="stylesheet" href="styles.css">),
                    "HTML 必须外链 styles.css"
  end

  def test_stylesheet_does_not_define_root_tokens
    refute css_rules.match?(/:root\s*\{/),
           "styles.css 不允许定义令牌根块（唯一来源是 app/tokens.rb，由入口运行时注入）"
  end

  def test_every_css_var_reference_has_a_token
    missing = css_var_refs - Sheets::Tokens::MAP.keys
    assert_empty missing, "styles.css 引用了未定义的令牌：#{missing.inspect}"
  end

  def test_every_token_is_used_or_whitelisted
    orphaned = Sheets::Tokens::MAP.keys - css_var_refs - NOT_IN_CSS
    assert_empty orphaned,
                 "这些令牌没有任何使用方（styles.css 未引用、也不在白名单）：#{orphaned.inspect}"
  end

  def test_native_theme_derives_from_tokens_without_local_colors
    theme = read("native/theme.rb")
    locals = theme.scan(/^ *[A-Z_]+ = "(#[0-9a-fA-F]{3,8})"/).flatten
    assert_equal ["#93b8f0"], locals,
                 "native/theme.rb 里出现了新的字面量色值——它只允许出现在 FORMULA（原生独有的公式格色）"
  end
end
