# frozen_string_literal: true

require_relative "value"
require_relative "num"

module Sheets
  # 函数库：接收已求值（区间已展开）的参数，返回一个值或错误值。
  # 控制流函数（IF / AND / OR / NOT / IFERROR）在 Evaluator 里实现以获得短路求值。
  module Functions
    ALIASES = { "AVG" => "AVERAGE" }.freeze

    module_function

    def known?(name)
      table.key?(ALIASES.fetch(name.to_s.upcase, name.to_s.upcase))
    end

    def call(name, args)
      key = ALIASES.fetch(name.to_s.upcase, name.to_s.upcase)
      fn = table[key]
      return NAME_ERR if fn.nil?

      fn.call(args)
    end

    def table
      @table ||= {
        "SUM" => ->(args) { sum(args) },
        "PRODUCT" => ->(args) { product(args) },
        "AVERAGE" => ->(args) { average(args) },
        "MIN" => ->(args) { extremum(args, :min) },
        "MAX" => ->(args) { extremum(args, :max) },
        "COUNT" => ->(args) { numerics(args).size.to_f },
        "COUNTA" => ->(args) { args.count { |v| !Coerce.blank?(v) && !Coerce.error?(v) }.to_f },
        "ABS" => ->(args) { unary_number(args) { |n| n.abs } },
        "SQRT" => ->(args) { unary_number(args) { |n| n.negative? ? NUM_ERR : Math.sqrt(n) } },
        "INT" => ->(args) { unary_number(args) { |n| n.floor.to_f } },
        "ROUND" => ->(args) { round(args) },
        "POWER" => ->(args) { power(args) },
        "CONCAT" => ->(args) { args.map { |v| Coerce.to_text(v) }.join },
        "LEN" => ->(args) { text_result(args) { |s| s.length.to_f } },
        "UPPER" => ->(args) { text_result(args) { |s| s.upcase } },
        "LOWER" => ->(args) { text_result(args) { |s| s.downcase } },
        "TRUE" => ->(_args) { true },
        "FALSE" => ->(_args) { false }
      }
    end

    # ── 实现 ────────────────────────────────────────────────

    def first_error(args)
      args.find { |v| Coerce.error?(v) }
    end

    def numerics(args)
      out = []
      args.each do |value|
        next if Coerce.blank?(value)
        next if value.is_a?(TrueClass) || value.is_a?(FalseClass)

        out << Coerce.to_number(value).to_f if Coerce.numeric?(value)
      end
      out
    end

    def sum(args)
      err = first_error(args)
      return err if err

      numerics(args).inject(0.0) { |acc, v| acc + v }
    end

    def product(args)
      err = first_error(args)
      return err if err

      values = numerics(args)
      return 0.0 if values.empty?

      values.inject(1.0) { |acc, v| acc * v }
    end

    def average(args)
      err = first_error(args)
      return err if err

      values = numerics(args)
      return DIV_ZERO if values.empty?

      values.inject(0.0) { |acc, v| acc + v } / values.size
    end

    def extremum(args, kind)
      err = first_error(args)
      return err if err

      values = numerics(args)
      return 0.0 if values.empty?

      values.inject { |a, b| kind == :min ? (a < b ? a : b) : (a > b ? a : b) }
    end

    def unary_number(args)
      err = first_error(args)
      return err if err
      return VALUE_ERR if args.empty?

      number = Coerce.to_number(args[0])
      return number if Coerce.error?(number)

      result = yield(number.to_f)
      Coerce.error?(result) ? result : guard(result)
    end

    def text_result(args)
      err = first_error(args)
      return err if err
      return VALUE_ERR if args.empty?

      yield(Coerce.to_text(args[0]))
    end

    def round(args)
      err = first_error(args)
      return err if err
      return VALUE_ERR if args.empty?

      number = Coerce.to_number(args[0])
      return number if Coerce.error?(number)

      digits = args.size > 1 ? Coerce.to_number(args[1]) : 0.0
      return digits if Coerce.error?(digits)

      guard(Num.round_to(number.to_f, digits.to_i))
    end

    def power(args)
      err = first_error(args)
      return err if err
      return VALUE_ERR if args.size < 2

      base = Coerce.to_number(args[0])
      exponent = Coerce.to_number(args[1])
      return base if Coerce.error?(base)
      return exponent if Coerce.error?(exponent)

      guard(base.to_f**exponent.to_f)
    end

    # 结果护栏：NaN / Infinity 一律转为错误值（避免把 NaN 传进后续计算）
    def guard(value)
      return value unless value.is_a?(Numeric)
      return value if Num.finite?(value)

      NUM_ERR
    end
  end
end
