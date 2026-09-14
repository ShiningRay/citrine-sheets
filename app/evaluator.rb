# frozen_string_literal: true

require_relative "formula"
require_relative "functions"
require_relative "value"

module Sheets
  # 求值器：把 AST 求值为一个值（数字 / 字符串 / 布尔 / nil / ErrorValue）。
  # 区间参数求值为数组，交给函数库展开。
  #
  # context 需响应 #cell_value(row, col) 与 #in_bounds?(row, col)。
  class Evaluator
    def initialize(context)
      @context = context
    end

    def evaluate(node)
      case node[0]
      when :num then node[1]
      when :str then node[1]
      when :bool then node[1]
      when :ref then reference(node)
      when :range then range_values(node)
      when :unary then unary(node)
      when :binop then binary(node)
      when :call then call(node)
      else VALUE_ERR
      end
    end

    private

    def reference(node)
      row = node[1]
      col = node[2]
      return REF_ERR unless @context.in_bounds?(row, col)

      @context.cell_value(row, col)
    end

    def range_values(node)
      r1, c1, r2, c2 = node[1], node[2], node[3], node[4]
      out = []
      (r1..r2).each do |row|
        (c1..c2).each do |col|
          out << (in_bounds?(row, col) ? @context.cell_value(row, col) : REF_ERR)
        end
      end
      out
    end

    def in_bounds?(row, col)
      @context.in_bounds?(row, col)
    end

    def unary(node)
      value = evaluate(node[2])
      return value if Coerce.error?(value)

      number = Coerce.to_number(value)
      return number if Coerce.error?(number)

      -number.to_f
    end

    def binary(node)
      op = node[1]
      left = evaluate(node[2])
      return left if Coerce.error?(left)

      right = evaluate(node[3])
      return right if Coerce.error?(right)

      case op
      when :+ then arithmetic(left, right) { |a, b| a + b }
      when :- then arithmetic(left, right) { |a, b| a - b }
      when :* then arithmetic(left, right) { |a, b| a * b }
      when :/ then divide(left, right)
      when :^ then power(left, right)
      when :& then Coerce.to_text(left) + Coerce.to_text(right)
      when :"=" then Coerce.equal?(left, right)
      when :"<>" then !Coerce.equal?(left, right)
      when :<, :>, :<=, :>=
        compare(left, right, op)
      else
        VALUE_ERR
      end
    end

    def arithmetic(left, right)
      a = Coerce.to_number(left)
      return a if Coerce.error?(a)

      b = Coerce.to_number(right)
      return b if Coerce.error?(b)

      Functions.guard(yield(a.to_f, b.to_f))
    end

    def divide(left, right)
      a = Coerce.to_number(left)
      return a if Coerce.error?(a)

      b = Coerce.to_number(right)
      return b if Coerce.error?(b)
      return DIV_ZERO if b.to_f.zero?

      Functions.guard(a.to_f / b.to_f)
    end

    def power(left, right)
      a = Coerce.to_number(left)
      return a if Coerce.error?(a)

      b = Coerce.to_number(right)
      return b if Coerce.error?(b)

      Functions.guard(a.to_f**b.to_f)
    end

    def compare(left, right, op)
      compared = Coerce.compare(left, right)
      return VALUE_ERR if compared.nil?

      case op
      when :< then compared.negative?
      when :> then compared.positive?
      when :<= then !compared.positive?
      else !compared.negative?
      end
    end

    # 控制流函数在这里实现（短路求值）；其余交给函数库
    def call(node)
      name = node[1]
      args = node[2]

      case name
      when "IF" then if_function(args)
      when "AND" then and_function(args)
      when "OR" then or_function(args)
      when "NOT" then not_function(args)
      when "IFERROR" then iferror_function(args)
      else
        return NAME_ERR unless Functions.known?(name)

        values = args.map { |arg| evaluate(arg) }
        Functions.call(name, values.flatten)
      end
    end

    def if_function(args)
      return VALUE_ERR if args.size < 2

      condition = evaluate(args[0])
      return condition if Coerce.error?(condition)

      if truthy?(condition)
        evaluate(args[1])
      elsif args.size > 2
        evaluate(args[2])
      else
        false
      end
    end

    def and_function(args)
      args.each do |arg|
        value = evaluate(arg)
        return value if Coerce.error?(value)
        return false unless truthy?(value)
      end
      true
    end

    def or_function(args)
      args.each do |arg|
        value = evaluate(arg)
        return value if Coerce.error?(value)
        return true if truthy?(value)
      end
      false
    end

    def not_function(args)
      return VALUE_ERR if args.empty?

      value = evaluate(args[0])
      return value if Coerce.error?(value)

      !truthy?(value)
    end

    def iferror_function(args)
      return VALUE_ERR if args.empty?

      value = evaluate(args[0])
      return value unless Coerce.error?(value)

      args.size > 1 ? evaluate(args[1]) : ""
    end

    def truthy?(value)
      return false if value.nil?
      return value if value.is_a?(TrueClass) || value.is_a?(FalseClass)
      return !value.to_f.zero? if value.is_a?(Numeric)

      !value.to_s.empty?
    end
  end
end
