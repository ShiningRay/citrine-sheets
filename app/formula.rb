# frozen_string_literal: true

require_relative "format"
require_relative "value"

module Sheets
  # 公式语言：词法分析 + 递归下降解析 + 静态依赖提取。
  #
  # 支持（简化自电子表格惯例）：
  #   字面量    12  -3.5  1.2e3  "文本"  TRUE  FALSE
  #   引用      A1  $A$1  （$ 表绝对引用，本引擎不做填充，仅保证解析与显示一致）
  #   区间      A1:B10
  #   运算符    + - * / ^ &   比较 = <> < > <= >=   一元 -
  #   函数      SUM AVERAGE MIN MAX COUNT COUNTA ABS ROUND INT SQRT
  #             IF AND OR NOT CONCAT LEN UPPER LOWER
  #
  # AST 用数组表示（紧凑、Opal 友好）：
  #   [:num, 1.5] [:str, "s"] [:bool, true] [:ref, row, col]
  #   [:range, r1, c1, r2, c2] [:unary, :- , node] [:binop, :+, l, r] [:call, "SUM", [..]]
  module Formula
    module_function

    # 解析公式正文（不含前导 "="）。返回 [:ok, ast] 或 [:err, ErrorValue]
    def parse(source)
      tokens = Lexer.new(source).tokens
      parser = Parser.new(tokens)
      ast = parser.parse_expression
      parser.expect_end!
      [:ok, ast]
    rescue ParseError => e
      [:err, e.error]
    end

    def formula?(text)
      text.is_a?(String) && text.start_with?("=")
    end

    def body(text)
      text.to_s.sub(/\A=/, "")
    end

    # 静态依赖：遍历 AST 收集引用（区间展开）。不依赖求值，因此
    # IF 的两个分支都会计入依赖，循环检测也因此可靠。
    def references(ast, max_row: 10_000, max_col: 100)
      out = {}
      walk(ast, out, max_row, max_col)
      out.keys
    end

    def walk(node, out, max_row, max_col)
      return if node.nil?

      case node[0]
      when :ref
        out[[node[1], node[2]]] = true if in_bounds?(node[1], node[2], max_row, max_col)
      when :range
        r1, c1, r2, c2 = node[1], node[2], node[3], node[4]
        (r1..r2).each do |r|
          (c1..c2).each do |c|
            out[[r, c]] = true if in_bounds?(r, c, max_row, max_col)
          end
        end
      when :unary
        walk(node[2], out, max_row, max_col)
      when :binop
        walk(node[2], out, max_row, max_col)
        walk(node[3], out, max_row, max_col)
      when :call
        node[2].each { |arg| walk(arg, out, max_row, max_col) }
      end
    end

    def in_bounds?(row, col, max_row, max_col)
      row >= 0 && col >= 0 && row < max_row && col < max_col
    end

    class ParseError < StandardError
      attr_reader :error

      def initialize(error)
        @error = error
        super(error.code)
      end
    end

    # ── 词法 ────────────────────────────────────────────────
    class Lexer
      # 单元格引用：可选 $、字母、可选 $、数字；后面不能紧跟字母/数字/小数点/左括号
      # （`(?!...)` 是为了避免把函数名 LOG10( 误判成引用）
      REFERENCE = /\A\$?([A-Za-z]+)\$?(\d+)(?![\w.(])/

      def initialize(source)
        @src = source.to_s
        @pos = 0
        @tokens = []
      end

      def tokens
        until eof?
          ch = current
          case ch
          when " ", "\t", "\n", "\r" then advance
          when "(" then push_and_advance([:lparen])
          when ")" then push_and_advance([:rparen])
          when "," then push_and_advance([:comma])
          when ":" then push_and_advance([:colon])
          when '"' then read_string
          when "$" then read_word
          else
            if digit?(ch) || (ch == "." && digit?(peek(1)))
              read_number
            elsif operator_char?(ch)
              read_operator
            elsif letter?(ch)
              read_word
            else
              advance
              raise ParseError, PARSE_ERR
            end
          end
        end
        @tokens
      end

      private

      def eof?
        @pos >= @src.length
      end

      def current
        @src[@pos]
      end

      def peek(offset)
        @src[@pos + offset]
      end

      def advance
        @pos += 1
      end

      def rest
        @src[@pos, @src.length - @pos].to_s
      end

      def push(token)
        @tokens << token
        true
      end

      def push_and_advance(token)
        push(token)
        advance
      end

      def digit?(ch)
        !ch.nil? && ch >= "0" && ch <= "9"
      end

      def letter?(ch)
        !ch.nil? && ((ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z"))
      end

      def operator_char?(ch)
        !ch.nil? && %w[< > = + - * / ^ &].include?(ch)
      end

      def read_number
        start = @pos
        advance while digit?(current)
        if current == "."
          advance
          advance while digit?(current)
        end
        if current == "e" || current == "E"
          save = @pos
          advance
          advance if current == "+" || current == "-"
          if digit?(current)
            advance while digit?(current)
          else
            @pos = save
          end
        end
        push([:num, @src[start, @pos - start].to_f])
      end

      def read_string
        advance # 开引号
        buffer = ""
        until eof?
          ch = current
          if ch == '"'
            if peek(1) == '"' # Excel 风格："" 表示一个引号
              buffer = buffer + '"'
              advance
              advance
              next
            end
            advance
            return push([:str, buffer])
          end
          # 注意：Opal 不支持 String#<<（可变字符串），必须用 + 重建
          buffer = buffer + ch
          advance
        end
        raise ParseError, PARSE_ERR
      end

      def read_operator
        ch = current
        two = @src[@pos, 2]
        if %w[<= >= <>].include?(two)
          advance
          advance
          push([:op, two])
        else
          advance
          push([:op, ch])
        end
      end

      # 以字母或 $ 开头的词：先试单元格引用，否则按标识符（函数名 / TRUE / FALSE）
      def read_word
        if (match = REFERENCE.match(rest))
          @pos += match[0].length
          return push([:ref, match[2].to_i - 1, Format.column_index(match[1]), match[0].include?("$")])
        end

        start = @pos
        advance while letter?(current) || digit?(current) || current == "_" || current == "."
        raise ParseError, PARSE_ERR if start == @pos

        upcased = @src[start, @pos - start].upcase
        return push([:bool, true]) if upcased == "TRUE"
        return push([:bool, false]) if upcased == "FALSE"

        push([:ident, upcased])
      end
    end

    # ── 语法 ────────────────────────────────────────────────
    class Parser
      def initialize(tokens)
        @tokens = tokens
        @pos = 0
      end

      def parse_expression
        parse_comparison
      end

      def expect_end!
        raise ParseError, PARSE_ERR unless peek.nil?
      end

      private

      def peek
        @tokens[@pos]
      end

      def take
        token = @tokens[@pos]
        @pos += 1
        token
      end

      def accept(type, value = nil)
        token = peek
        return nil if token.nil? || token[0] != type
        return nil if !value.nil? && token[1] != value

        take
      end

      # 只看不取：仅当下一 token 是给定集合中的运算符时才消费并返回它。
      # （早先版本直接 accept(:op) 再判断，会把不属于本层的运算符吃掉丢弃，
      #   导致 "1+2*3" 这类表达式解析失败——这是个真 bug，已有测试锁定。）
      def accept_operator(chars)
        token = peek
        return nil if token.nil? || token[0] != :op || !chars.include?(token[1])

        take
        token[1]
      end

      def expect(type, value = nil)
        token = accept(type, value)
        raise ParseError, PARSE_ERR if token.nil?

        token
      end

      def parse_comparison
        node = parse_concat
        while (op = accept_operator(%w[= <> < > <= >=]))
          node = [:binop, op.to_sym, node, parse_concat]
        end
        node
      end

      def parse_concat
        node = parse_additive
        while accept_operator(%w[&])
          node = [:binop, :&, node, parse_additive]
        end
        node
      end

      def parse_additive
        node = parse_multiplicative
        while (op = accept_operator(%w[+ -]))
          node = [:binop, op.to_sym, node, parse_multiplicative]
        end
        node
      end

      def parse_multiplicative
        node = parse_power
        while (op = accept_operator(%w[* /]))
          node = [:binop, op.to_sym, node, parse_power]
        end
        node
      end

      # 一元 +/- 的优先级高于 ^（与 Excel 一致：-2^2 = 4）；^ 左结合（2^3^2 = 64）
      def parse_power
        node = parse_signed_primary
        while accept_operator(%w[^])
          node = [:binop, :^, node, parse_signed_primary]
        end
        node
      end

      def parse_signed_primary
        op = accept_operator(%w[- +])
        if op
          operand = parse_signed_primary
          return op == "-" ? [:unary, :-, operand] : operand
        end

        parse_primary
      end

      def parse_primary
        token = peek
        raise ParseError, PARSE_ERR if token.nil?

        case token[0]
        when :num then take and [:num, token[1]]
        when :str then take and [:str, token[1]]
        when :bool then take and [:bool, token[1]]
        when :ref then parse_reference
        when :ident then parse_call
        when :lparen
          take
          node = parse_expression
          expect(:rparen)
          node
        when :op
          # 允许 +A1 这类前缀
          raise ParseError, PARSE_ERR unless %w[+ -].include?(token[1])

          take
          node = parse_primary
          token[1] == "-" ? [:unary, :-, node] : node
        else
          raise ParseError, PARSE_ERR
        end
      end

      def parse_reference
        token = take
        left = [:ref, token[1], token[2]]
        return left unless accept(:colon)

        right = expect(:ref)
        r1, r2 = [token[1], right[1]].minmax
        c1, c2 = [token[2], right[2]].minmax
        [:range, r1, c1, r2, c2]
      end

      def parse_call
        name = take[1]
        expect(:lparen)
        args = []
        unless accept(:rparen)
          loop do
            args << parse_expression
            break if accept(:rparen)
            expect(:comma)
          end
        end
        [:call, name, args]
      end
    end
  end
end
