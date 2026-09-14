# frozen_string_literal: true

# 电子表格内核单测（纯 CRuby，不需要 Opal / 浏览器）
#
#   rake test
#
# 覆盖：公式解析（优先级 / 结合性 / 引用 / 区间 / 错误）、求值与值语义、
#       函数库、依赖图与增量重算、循环引用、撤销重做、格式与显示
require "minitest/autorun"
require "citrine"
require_relative "../app/workbook"

class FormulaParseTest < Minitest::Test
  def parse(text)
    result = Sheets::Formula.parse(text)
    assert_equal :ok, result[0], "解析失败：#{text} → #{result[1]}"
    result[1]
  end

  def test_arithmetic_precedence
    assert_equal [:binop, :+, [:num, 1.0], [:binop, :*, [:num, 2.0], [:num, 3.0]]], parse("1+2*3")
    assert_equal [:binop, :*, [:binop, :+, [:num, 1.0], [:num, 2.0]], [:num, 3.0]], parse("(1+2)*3")
    assert_equal [:binop, :-, [:num, 5.0], [:num, 3.0]], parse("5-3")
  end

  def test_power_is_left_associative_like_excel
    # Excel：=2^3^2 → 64（左结合），不是 512
    assert_equal [:binop, :^, [:binop, :^, [:num, 2.0], [:num, 3.0]], [:num, 2.0]], parse("2^3^2")
  end

  def test_unary_minus
    assert_equal [:unary, :-, [:num, 3.0]], parse("-3")
    assert_equal [:unary, :-, [:unary, :-, [:num, 3.0]]], parse("--3")
    assert_equal [:binop, :*, [:unary, :-, [:num, 2.0]], [:num, 3.0]], parse("-2*3")
  end

  def test_references_and_dollar
    assert_equal [:ref, 0, 0], parse("A1")
    assert_equal [:ref, 2, 1], parse("$B$3")
    assert_equal [:ref, 11, 26], parse("AA12")
    assert_equal [:binop, :+, [:ref, 0, 0], [:num, 1.0]], parse("A1+1")
  end

  def test_ranges_normalize_corners
    assert_equal [:range, 0, 0, 9, 0], parse("A1:A10")
    # 反向书写也要归一
    assert_equal [:range, 0, 0, 9, 1], parse("B10:A1")
  end

  def test_strings_and_escaped_quotes
    assert_equal [:str, "abc"], parse('"abc"')
    assert_equal [:str, 'a"b'], parse('"a""b"')
  end

  def test_numbers_with_exponent
    assert_equal [:num, 150.0], parse("1.5e2")
    assert_equal [:num, 0.5], parse(".5")
  end

  def test_function_names_are_not_confused_with_references
    assert_equal [:call, "LOG10", [[:num, 2.0]]], parse("LOG10(2)")
    assert_equal [:call, "SUM", []], parse("SUM()")
  end

  def test_boolean_literals
    assert_equal [:bool, true], parse("TRUE")
    assert_equal [:bool, false], parse("FALSE")
  end

  def test_parse_errors
    ["", "A1+", "1+2)", "SUM(", "@", "1 2"].each do |bad|
      result = Sheets::Formula.parse(bad)
      assert_equal :err, result[0], "#{bad.inspect} 应当解析失败"
      assert_equal "#PARSE!", result[1].code
    end
  end

  def test_reference_extraction_includes_both_branches
    ast = parse("IF(A1>0,C1,0)")
    refs = Sheets::Formula.references(ast).sort
    assert_equal [[0, 0], [0, 2]], refs, "IF 未走到的分支也必须计入依赖"
  end
end

class EvaluatorTest < Minitest::Test
  # 简易上下文：单元格值预先给定
  class Ctx
    def initialize(map = {})
      @map = map
    end

    def cell_value(row, col)
      @map.fetch([row, col], nil)
    end

    def in_bounds?(row, col)
      row >= 0 && col >= 0 && row < 100 && col < 50
    end
  end

  def evaluate(formula, map = {})
    ast = Sheets::Formula.parse(formula)[1]
    Sheets::Evaluator.new(Ctx.new(map)).evaluate(ast)
  end

  def test_arithmetic
    assert_in_delta 7.0, evaluate("1+2*3"), 1e-9
    assert_in_delta 2.5, evaluate("10/4"), 1e-9, "电子表格除法是真除法"
    assert_in_delta 512.0, evaluate("2^9"), 1e-9
    assert_in_delta -6.0, evaluate("-2*3"), 1e-9
    assert_in_delta 64.0, evaluate("2^3^2"), 1e-9, "^ 左结合（同 Excel）"
    assert_in_delta 4.0, evaluate("-2^2"), 1e-9, "一元负号优先于 ^（同 Excel：= -2^2 得 4）"
    assert_in_delta 0.125, evaluate("2^-3"), 1e-9
  end

  def test_division_by_zero_is_error_value
    assert_equal "#DIV/0!", evaluate("1/0").code
    assert_equal "#DIV/0!", evaluate("A1/0", { [0, 0] => 5.0 }).code
  end

  def test_cell_references
    assert_in_delta 5.0, evaluate("A1", { [0, 0] => 5.0 }), 1e-9
    assert_in_delta 8.0, evaluate("A1+B1*3", { [0, 0] => 5.0, [0, 1] => 1.0 }), 1e-9
    # 空白按 0
    assert_in_delta 1.0, evaluate("A1+1", {}), 1e-9
  end

  def test_out_of_range_reference
    assert_equal "#REF!", evaluate("A1", {}).code if false # 占位：见 workbook 测试的越界用例

    ctx = Class.new do
      def cell_value(_row, _col)
        raise "不应被调用"
      end

      def in_bounds?(_row, _col)
        false
      end
    end.new
    ast = Sheets::Formula.parse("ZZ999")[1]
    assert_equal "#REF!", Sheets::Evaluator.new(ctx).evaluate(ast).code
  end

  def test_text_coercion
    assert_in_delta 3.0, evaluate('"1"+2'), 1e-9, "数字文本参与算术"
    assert_equal "#VALUE!", evaluate('"abc"+1').code
    assert_equal "ab", evaluate('"a"&"b"')
    assert_equal "a1", evaluate('"a"&1')
  end

  def test_comparisons
    assert_equal true, evaluate("2<10")
    assert_equal false, evaluate("2>10")
    assert_equal true, evaluate("2<=2")
    assert_equal true, evaluate('"a"="a"')
    assert_equal true, evaluate("A1=5", { [0, 0] => 5.0 })
    assert_equal false, evaluate("A1<>5", { [0, 0] => 5.0 })
  end

  def test_error_propagation
    assert_equal "#DIV/0!", evaluate("(1/0)+1").code
    assert_equal "#DIV/0!", evaluate('(1/0)*"abc"').code, "多个错误时返回最先遇到的那个"
    assert_equal "#DIV/0!", evaluate('"abc"*(1/0)').code, "错误值优先于类型错误传播"
  end

  def test_if_with_short_circuit
    assert_in_delta 1.0, evaluate("IF(TRUE,1,1/0)"), 1e-9, "未走到的分支不应产生错误"
    assert_in_delta 2.0, evaluate("IF(FALSE,1/0,2)"), 1e-9
    assert_equal false, evaluate("IF(FALSE,1)")
    assert_equal "#DIV/0!", evaluate("IF(1/0,1,2)").code, "条件本身出错要传播"
  end

  def test_logic_functions
    assert_equal true, evaluate("AND(TRUE,1=1)")
    assert_equal false, evaluate("AND(TRUE,FALSE)")
    assert_equal true, evaluate("OR(FALSE,TRUE)")
    assert_equal false, evaluate("NOT(TRUE)")
    assert_equal true, evaluate("NOT(FALSE)")
  end

  def test_iferror
    assert_equal "兜底", evaluate('IFERROR(1/0,"兜底")')
    assert_in_delta 5.0, evaluate("IFERROR(5,0)"), 1e-9
  end

  def test_unknown_function
    assert_equal "#NAME?", evaluate("NOPE(1)").code
  end
end

class FunctionsTest < Minitest::Test
  def call(name, *args)
    Sheets::Functions.call(name, args)
  end

  def test_sum_and_average_ignore_text_and_blanks
    assert_in_delta 6.0, call("SUM", 1.0, 2.0, 3.0), 1e-9
    assert_in_delta 6.0, call("SUM", 1.0, nil, "文本", 2.0, 3.0), 1e-9
    assert_in_delta 2.0, call("AVERAGE", 1.0, 2.0, 3.0), 1e-9
    assert_equal "#DIV/0!", call("AVERAGE", nil, "x").code
    assert_in_delta 2.0, call("AVG", 1.0, 3.0), 1e-9, "AVG 是 AVERAGE 的别名"
  end

  def test_min_max_count
    assert_in_delta 1.0, call("MIN", 3.0, 1.0, 2.0), 1e-9
    assert_in_delta 3.0, call("MAX", 3.0, 1.0, 2.0), 1e-9
    assert_in_delta 0.0, call("MIN", nil), 1e-9, "无数值时 MIN 返回 0"
    assert_in_delta 3.0, call("COUNT", 1.0, 2.0, 3.0, nil, "x"), 1e-9
    assert_in_delta 4.0, call("COUNTA", 1.0, nil, "x", true, 2.0), 1e-9, "空白不计入 COUNTA"
  end

  def test_math_functions
    assert_in_delta 5.0, call("ABS", -5.0), 1e-9
    assert_in_delta 3.0, call("SQRT", 9.0), 1e-9
    assert_equal "#NUM!", call("SQRT", -1.0).code
    assert_in_delta 3.0, call("INT", 3.7), 1e-9
    assert_in_delta 3.14, call("ROUND", 3.14159, 2.0), 1e-9
    assert_in_delta -3.14, call("ROUND", -3.14159, 2.0), 1e-9
    assert_in_delta 3.15, call("ROUND", 3.145, 2.0), 1e-9, "四舍五入到 2 位"
    assert_in_delta 8.0, call("POWER", 2.0, 3.0), 1e-9
  end

  def test_text_functions
    assert_equal "abc", call("CONCAT", "a", "b", "c")
    assert_equal "a1", call("CONCAT", "a", 1.0)
    assert_in_delta 3.0, call("LEN", "abc"), 1e-9
    assert_equal "ABC", call("UPPER", "abc")
    assert_equal "abc", call("LOWER", "ABC")
  end

  def test_error_propagation_in_functions
    assert_equal "#VALUE!", call("SUM", 1.0, Sheets::VALUE_ERR).code
    assert_equal "#DIV/0!", call("MAX", Sheets::DIV_ZERO).code
  end

  def test_guard_against_non_finite
    assert_equal "#NUM!", call("POWER", 1e308, 10.0).code
  end
end

class WorkbookTest < Minitest::Test
  def sheet
    @sheet ||= Sheets::Workbook.new(rows: 20, cols: 8)
  end

  def test_literal_kinds
    sheet.set_raw(0, 0, "42")
    sheet.set_raw(1, 0, "3.5")
    sheet.set_raw(2, 0, "abc")
    sheet.set_raw(3, 0, "TRUE")
    assert_in_delta 42.0, sheet.value(0, 0), 1e-9
    assert_equal :number, sheet.kind(0, 0)
    assert_in_delta 3.5, sheet.value(1, 0), 1e-9
    assert_equal "abc", sheet.value(2, 0)
    assert_equal :text, sheet.kind(2, 0)
    assert_equal true, sheet.value(3, 0)
    assert_equal :bool, sheet.kind(3, 0)
    assert_equal :blank, sheet.kind(9, 9)
  end

  def test_formula_evaluation_and_dependencies
    sheet.set_raw(0, 0, "10")
    sheet.set_raw(1, 0, "20")
    sheet.set_raw(2, 0, "=A1+A2")
    sheet.set_raw(3, 0, "=SUM(A1:A2)*2")
    assert_in_delta 30.0, sheet.value(2, 0), 1e-9
    assert_in_delta 60.0, sheet.value(3, 0), 1e-9
    assert_equal [[0, 0], [1, 0]], sheet.dependencies(2, 0).sort
    assert_equal [[0, 0], [1, 0]], sheet.dependencies(3, 0).sort, "A1:A2 区间展开成逐格依赖"
    assert_includes sheet.dependents(0, 0), [2, 0]
    assert_includes sheet.dependents(0, 0), [3, 0], "区间引用也要建立依赖"
    assert_equal 2, sheet.formula_count
  end

  def test_incremental_recalc_touches_only_dependents
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(1, 0, "=A1*2")
    sheet.set_raw(2, 0, "=A2*2")
    sheet.set_raw(0, 3, "100") # 无关单元格
    report = sheet.set_raw(0, 0, "5")
    assert_equal 3, report[:computed], "受影响集合 = 被改单元格 + 两个传递后继（A1、A2、A3）"
    assert_equal [[0, 0], [1, 0], [2, 0]], report[:cells].sort
    assert_in_delta 10.0, sheet.value(1, 0), 1e-9
    assert_in_delta 20.0, sheet.value(2, 0), 1e-9
  end

  def test_error_propagates_through_chain
    sheet.set_raw(0, 0, "0")
    sheet.set_raw(1, 0, "=10/A1")
    sheet.set_raw(2, 0, "=A2+1")
    assert_equal "#DIV/0!", sheet.value(1, 0).code
    assert_equal "#DIV/0!", sheet.value(2, 0).code
    sheet.set_raw(0, 0, "2")
    assert_in_delta 5.0, sheet.value(1, 0), 1e-9
    assert_in_delta 6.0, sheet.value(2, 0), 1e-9
  end

  def test_parse_error_is_displayed_not_raised
    sheet.set_raw(0, 0, "=1+")
    assert_equal "#PARSE!", sheet.value(0, 0).code
    assert_equal "#PARSE!", sheet.display(0, 0)
  end

  def test_circular_reference_becomes_error_value
    sheet.set_raw(0, 0, "=B1")
    sheet.set_raw(0, 1, "=A1")
    assert_equal "#CIRC!", sheet.value(0, 0).code
    assert_equal "#CIRC!", sheet.value(0, 1).code
    assert_equal 2, sheet.cyclic_count
    sheet.set_raw(0, 1, "5")
    assert_in_delta 5.0, sheet.value(0, 0), 1e-9, "打破环后应恢复计算"
    assert_equal 0, sheet.cyclic_count
  end

  def test_longer_cycle_detected
    sheet.set_raw(0, 0, "=C1")
    sheet.set_raw(0, 1, "=A1")
    sheet.set_raw(0, 2, "=B1")
    assert_equal "#CIRC!", sheet.value(0, 0).code
    assert_equal "#CIRC!", sheet.value(0, 1).code
    assert_equal "#CIRC!", sheet.value(0, 2).code
  end

  def test_out_of_bounds_reference
    sheet.set_raw(0, 0, "=ZZ999")
    assert_equal "#REF!", sheet.value(0, 0).code
  end

  def test_range_functions_over_columns
    (0..3).each { |r| sheet.set_raw(r, 0, (r + 1).to_s) }
    sheet.set_raw(5, 0, "=SUM(A1:A4)")
    sheet.set_raw(6, 0, "=AVERAGE(A1:A4)")
    sheet.set_raw(7, 0, "=MAX(A1:A4)")
    sheet.set_raw(8, 0, "=COUNT(A1:A4)")
    assert_in_delta 10.0, sheet.value(5, 0), 1e-9
    assert_in_delta 2.5, sheet.value(6, 0), 1e-9
    assert_in_delta 4.0, sheet.value(7, 0), 1e-9
    assert_in_delta 4.0, sheet.value(8, 0), 1e-9
  end

  def test_editing_formula_changes_dependency_graph
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(0, 1, "2")
    sheet.set_raw(1, 0, "=A1")
    assert_equal [[0, 0]], sheet.dependencies(1, 0)
    sheet.set_raw(1, 0, "=B1")
    assert_equal [[0, 1]], sheet.dependencies(1, 0)
    assert_empty sheet.dependents(0, 0), "旧依赖边必须被摘掉"
    report = sheet.set_raw(0, 1, "5")
    assert_in_delta 5.0, sheet.value(1, 0), 1e-9
    assert_equal 2, report[:computed], "受影响集合 = B1 与依赖它的 A2"
  end

  def test_batch_write_recalculates_once
    (0..4).each { |r| sheet.set_raw(r, 0, "=1") }
    sheet.set_raw(9, 0, "=SUM(A1:A5)")
    report = sheet.set_many([[0, 0, "10"], [1, 0, "20"], [2, 0, "30"]])
    assert_in_delta 62.0, sheet.value(9, 0), 1e-9
    assert_equal 4, report[:computed], "三处改动 + 汇总格 = 一次重算"
  end

  def test_undo_redo_restores_values_and_graph
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(1, 0, "=A1*10")
    assert_in_delta 10.0, sheet.value(1, 0), 1e-9
    sheet.set_raw(0, 0, "7")
    assert_in_delta 70.0, sheet.value(1, 0), 1e-9
    assert_equal :undo, sheet.undo
    assert_in_delta 1.0, sheet.value(0, 0), 1e-9
    assert_in_delta 10.0, sheet.value(1, 0), 1e-9, "撤销后依赖链要一起恢复"
    assert_equal :redo, sheet.redo
    assert_in_delta 70.0, sheet.value(1, 0), 1e-9
  end

  def test_undo_depth_and_redo_cleared_on_new_edit
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(0, 0, "2")
    assert_equal 2, sheet.undo_depth
    sheet.undo
    assert_equal 1, sheet.redo_depth
    sheet.set_raw(0, 0, "3")
    assert_equal 0, sheet.redo_depth, "新编辑应清空重做栈"
  end

  def test_formatting_and_chrome
    sheet.set_raw(0, 0, "1234.5678")
    assert_equal "1,234.57", sheet.display(0, 0)
    sheet.set_chrome([[0, 0]], { decimals: 4 })
    assert_equal "1,234.5678", sheet.display(0, 0)
    sheet.set_chrome([[0, 0]], { decimals: 0 })
    assert_equal "1,235", sheet.display(0, 0)
    sheet.set_chrome([[0, 0]], { bold: true, bg: "#fff2cc" })
    assert_equal true, sheet.chrome(0, 0)[:bold]
    assert_equal "#fff2cc", sheet.chrome(0, 0)[:bg]
  end

  def test_display_of_various_values
    sheet.set_raw(0, 0, "0.5")
    sheet.set_raw(1, 0, "2")
    sheet.set_raw(2, 0, "=1/3")
    sheet.set_raw(3, 0, "hello")
    assert_equal "0.5", sheet.display(0, 0)
    assert_equal "2", sheet.display(1, 0)
    assert_equal "0.33", sheet.display(2, 0)
    assert_equal "hello", sheet.display(3, 0)
    assert_equal "", sheet.display(9, 9)
  end

  def test_clear_range
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(0, 1, "=A1")
    sheet.set_chrome([[0, 0]], { bold: true })
    sheet.clear_range(0, 0, 0, 1)
    assert_nil sheet.raw(0, 0)
    assert_nil sheet.raw(0, 1)
    assert_nil sheet.value(0, 0)
    assert_empty sheet.chrome(0, 0)
    assert_equal 0, sheet.formula_count
  end

  def test_signals_published_on_edit
    signal = sheet.value_signal(0, 0)
    before = signal.get
    sheet.set_raw(0, 0, "42")
    after = signal.get
    refute_equal before[:display], after[:display]
    assert_equal "42", after[:display]
  end

    def test_chrome_signal_stable_when_only_value_changes
    sheet.set_raw(0, 0, "1")
    signal = sheet.chrome_signal(0, 0)
    first = signal.get
    sheet.set_raw(0, 0, "2")
    assert first.equal?(signal.get), "仅数值变化时，外观信号不应发布新对象（否则每改一个数都要重建单元格）"
    sheet.set_raw(0, 0, "=1/0")
    refute first.equal?(signal.get), "变成错误值后外观要更新（错误色）"
  end

  def test_recalculate_all
    sheet.set_raw(0, 0, "2")
    sheet.set_raw(1, 0, "=A1^10")
    report = sheet.recalculate_all
    assert_in_delta 1024.0, sheet.value(1, 0), 1e-9
    assert report[:computed] >= 2
  end

  def test_filled_and_error_counts
    sheet.set_raw(0, 0, "1")
    sheet.set_raw(1, 0, "=1/0")
    assert_equal 2, sheet.filled_count
    assert_equal 1, sheet.error_count
    assert_equal 1, sheet.formula_count
  end
end
