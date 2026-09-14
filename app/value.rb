# frozen_string_literal: true

require_relative "num"
require_relative "format"

module Sheets
  # 单元格错误值（与数字/字符串一样是"值"，参与传播但不参与运算）
  class ErrorValue
    CODES = %w[#DIV/0! #VALUE! #NAME? #REF! #CIRC! #PARSE! #NUM!].freeze

    attr_reader :code, :detail

    def initialize(code, detail = nil)
      @code = code
      @detail = detail
    end

    def to_s
      @code
    end

    def error?
      true
    end

    def ==(other)
      other.is_a?(ErrorValue) && other.code == @code
    end
  end

  DIV_ZERO  = ErrorValue.new("#DIV/0!")
  VALUE_ERR = ErrorValue.new("#VALUE!")
  NAME_ERR  = ErrorValue.new("#NAME?")
  REF_ERR   = ErrorValue.new("#REF!")
  CIRC_ERR  = ErrorValue.new("#CIRC!")
  PARSE_ERR = ErrorValue.new("#PARSE!")
  NUM_ERR   = ErrorValue.new("#NUM!")

  # 值语义：类型判定、强制转换、比较。
  # 规则（简化自电子表格惯例）：
  #   - 空白当 0（数值上下文）或 ""（文本上下文）
  #   - 布尔 → 1 / 0（数值）或 "TRUE" / "FALSE"（文本）
  #   - 文本参与算术：能解析成数字则用，否则 #VALUE!
  #   - 比较：两边都能当数字则按数字，否则按字符串
  module Coerce
    module_function

    BLANK = nil

    def error?(value)
      value.is_a?(ErrorValue)
    end

    def blank?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end

    # → Float 或 ErrorValue
    def to_number(value)
      case value
      when nil then 0.0
      when Integer, Float then value.to_f
      when true then 1.0
      when false then 0.0
      when ErrorValue then value
      when String
        text = value.strip
        return 0.0 if text.empty?
        return value if text =~ /[,%]/ # 不做千分位/百分号解析，避免歧义

        numeric_string?(text) ? text.to_f : VALUE_ERR
      else
        VALUE_ERR
      end
    end

    def numeric_string?(text)
      !!(text =~ /\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\z/)
    end

    # → String
    def to_text(value)
      case value
      when nil then ""
      when true then "TRUE"
      when false then "FALSE"
      when ErrorValue then value.code
      when Float, Integer then Format.number_plain(value)
      else value.to_s
      end
    end

    def numeric?(value)
      return true if value.is_a?(Numeric)
      return false if value.nil? || value.is_a?(ErrorValue) || value.is_a?(TrueClass) || value.is_a?(FalseClass)

      value.is_a?(String) && numeric_string?(value.strip)
    end

    # 比较：返回 -1 / 0 / 1；不可比较时返回 nil
    def compare(left, right)
      return nil if left.is_a?(ErrorValue) || right.is_a?(ErrorValue)

      if numeric?(left) && numeric?(right)
        a = to_number(left).to_f
        b = to_number(right).to_f
        return 0 if a == b

        a < b ? -1 : 1
      else
        a = to_text(left)
        b = to_text(right)
        return 0 if a == b

        a < b ? -1 : 1
      end
    end

    # 相等（= 运算符）
    def equal?(left, right)
      compared = compare(left, right)
      return false if compared.nil?

      compared.zero?
    end

    # 文本相等对大小写敏感与 Excel 一致（"a" = "A" 为 true）；这里保持严格相等
    def strict_equal?(left, right)
      return false if left.is_a?(ErrorValue) || right.is_a?(ErrorValue)
      return left == right if left.class == right.class
      return left.to_f == right.to_f if numeric?(left) && numeric?(right)

      false
    end
  end
end

