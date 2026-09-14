# frozen_string_literal: true

# 跨平台数值工具（CRuby / Opal 语义差异集中在这一个文件）
#
# 与 citrine-market-terminal 的 num.rb 是同一件事的第二份实现——这本身是条
# 框架缺口的证据（见 FRICTION-2.md G-12：跨平台数值工具应当由框架提供一次）。
#
# 陷阱原文（Opal 1.8.3 实测）：
#   1. 整数除法 `7 / 2` 在 Opal 返回 3.5（Opal 的 Numeric#/ 即 JS 除法），
#      CRuby 返回 3 —— 静默差异。凡需整数商一律走 Num.idiv（用 Integer#div）。
#   2. `(-1.5).round` CRuby 为 -2（远离零），Opal 为 -1（JS Math.round 朝 +∞）。
#      故取整先取绝对值再回贴符号。
#   3. 表格里的除法永远是"真除法"（=10/4 应为 2.5），所以数值计算统一 to_f。
module Sheets
  module Num
    module_function

    def idiv(value, divisor)
      value.div(divisor)
    end

    def round_to(value, digits)
      return value.to_f if digits.to_i.zero? && value == value.round

      factor = 10**digits
      sign = value.negative? ? -1 : 1
      ((value.abs * factor).round.to_f / factor) * sign
    end

    # 整数值判定（用于显示层：2.0 显示成 "2" 而不是 "2.00"）
    def integral?(value)
      value.to_f == value.to_f.round
    end

    def finite?(value)
      return false unless value.is_a?(Numeric)

      value.to_f.finite?
    end

    def to_int(value)
      value.to_f.round
    end
  end
end
