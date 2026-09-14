# frozen_string_literal: true

require_relative "num"

module Sheets
  # 显示格式化（纯函数，两侧平台一致；不使用 sprintf）
  module Format
    module_function

    # 0 → "A"，25 → "Z"，26 → "AA"
    def column_label(index)
      index = index.to_i
      label = +""
      n = index
      loop do
        label = ((65 + (n % 26)).chr) + label
        n = Num.idiv(n, 26) - 1
        break if n < 0
      end
      label
    end

    # "A" → 0，"AA" → 26，"$B$3" → 1
    def column_index(label)
      text = label.to_s.gsub("$", "").upcase
      value = 0
      text.each_char { |ch| value = value * 26 + (ch.ord - 64) }
      value - 1
    end

    def cell_key(row, col)
      "#{column_label(col)}#{row + 1}"
    end

    # "B3" → { row: 2, col: 1 }
    def parse_key(key)
      match = key.to_s.strip.upcase.gsub("$", "").match(/\A([A-Z]+)(\d+)\z/)
      return nil unless match

      { row: match[2].to_i - 1, col: column_index(match[1]) }
    end

    # 纯数字文本（不含千分位；用于公式引擎内部与测试）
    def number_plain(value)
      return "0" if value.zero? && value.is_a?(Numeric)

      rounded = Num.round_to(value.to_f, 6)
      if Num.integral?(rounded)
        Num.to_int(rounded).to_s
      else
        text = rounded.to_s
        text = text.sub(/(\.\d*?)0+\z/, '\1').sub(/\.\z/, "")
        text.sub(/\A0\./, ".").sub(/\A-0\./, "-.")
      end
    end

    # 千分位分组：1234567 → "1,234,567"
    def grouped(integer)
      text = integer.to_s
      negative = text.start_with?("-")
      digits = negative ? text[1, text.length - 1] : text
      parts = []
      while digits.length > 3
        parts.unshift(digits[digits.length - 3, 3])
        digits = digits[0, digits.length - 3]
      end
      parts.unshift(digits)
      body = parts.join(",")
      negative ? "-#{body}" : body
    end

    # 固定小数位（带千分位）：(1234.5, 2) → "1,234.50"
    def fixed(value, digits)
      factor = 10**digits
      scaled = (value.abs * factor).round
      whole = Num.idiv(scaled, factor)
      frac = scaled - whole * factor
      body = grouped(whole)
      body = "#{body}.#{frac.to_s.rjust(digits, '0')}" if digits.positive?
      value.negative? ? "-#{body}" : body
    end

    # 单元格显示文本。decimals 为 nil 表示自动（整数不带小数，其余最多 2 位并去尾零）
    def display(value, decimals = nil)
      case value
      when nil then ""
      when ErrorValue then value.code
      when true then "TRUE"
      when false then "FALSE"
      when String then value
      when Numeric then number_display(value, decimals)
      else value.to_s
      end
    end

    def number_display(value, decimals)
      return fixed(value, decimals) if decimals

      abs = value.abs
      return exponent(value) if abs >= 1e15 || (abs < 1e-9 && !value.zero?)

      if Num.integral?(value)
        grouped(Num.to_int(value))
      else
        fixed(Num.round_to(value, 2), 2).sub(/(\.\d*?)0+\z/, '\1').sub(/\.\z/, "")
      end
    end

    def exponent(value)
      text = value.to_s.upcase
      text.include?("E") ? text : "#{value}E0"
    end

    # 状态栏用的紧凑数字（无千分位）
    def compact(value)
      return "" if value.nil?
      return value.code if value.is_a?(ErrorValue)

      Num.integral?(value) ? Num.to_int(value).to_s : Num.round_to(value.to_f, 3).to_s
    end
  end
end
