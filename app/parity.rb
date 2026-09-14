# frozen_string_literal: true

# 跨平台一致性输出：同一份内核（公式解析 / 求值 / 函数 / 工作簿）在
# CRuby 与 Opal(JS) 下应给出逐字节相同的输出。
#
#   rake parity
#
# 存在意义：表格引擎里到处是除法、取整与浮点显示，而 Opal 在这些点上与
# CRuby 有**静默**语义差异（整数除法返回浮点、负数取整方向不同）。
# 这个脚本是那类差异的回归防护——本仓库已经靠它抓到过一次显示层差异。
require_relative "workbook"

def line(label, value)
  puts "#{label}=#{value}"
end

def show(label, value)
  case value
  when Sheets::ErrorValue then line(label, value.code)
  when Float then line(label, Sheets::Format.display(value))
  when nil then line(label, "")
  else line(label, Sheets::Format.display(value))
  end
end

# ── 1. 解析与求值 ──────────────────────────────────────────
FORMULAS = [
  "1+2*3", "(1+2)*3", "2^3^2", "-2^2", "2^-3", "10/4", "7/2", "1/3",
  "-3.14159", "-0.005", "1/0", "0/0", "1e10/3", '"1"+2', '"abc"+1',
  '"a"&"b"&1', "2<10", "2=2.0", "TRUE+1", "1&2", "--3", "-(-5)",
  "ROUND(3.14159,2)", "ROUND(-3.14159,2)", "ROUND(2.5,0)", "ROUND(-2.5,0)",
  "INT(-3.7)", "ABS(-2.5)", "SQRT(2)", "SQRT(-1)", "POWER(2,10)",
  "IF(1>0,\"y\",\"n\")", "IFERROR(1/0,\"e\")", "NOT(TRUE)", "AND(TRUE,FALSE)",
  "LEN(\"hello\")", "UPPER(\"ab\")", "NOPE(1)", "SUM()", "AVERAGE(1,2,3)"
].freeze

class LiteralContext
  def cell_value(_row, _col)
    nil
  end

  def in_bounds?(_row, _col)
    true
  end
end

FORMULAS.each do |formula|
  result = Sheets::Formula.parse(formula)
  if result[0] == :ok
    show("F:#{formula}", Sheets::Evaluator.new(LiteralContext.new).evaluate(result[1]))
  else
    show("F:#{formula}", result[1])
  end
end

# ── 2. 工作簿：依赖链、区间、错误、循环 ────────────────────
sheet = Sheets::Workbook.new(rows: 24, cols: 8)

MONTHS = %w[1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月].freeze
REVENUE = [120_000, 132_500, 118_900, 145_200, 151_800, 138_400,
           160_100, 172_300, 158_700, 181_500, 195_200, 208_900].freeze
COST = [78_000, 84_100, 79_600, 88_700, 92_300, 87_500,
        95_800, 99_400, 96_200, 104_100, 108_600, 112_300].freeze

sheet.set_raw(0, 0, "月份")
sheet.set_raw(0, 1, "收入")
sheet.set_raw(0, 2, "成本")
sheet.set_raw(0, 3, "毛利")
sheet.set_raw(0, 4, "毛利率")
sheet.set_raw(0, 5, "累计毛利")
MONTHS.each_with_index do |month, i|
  row = i + 1
  sheet.set_raw(row, 0, month)
  sheet.set_raw(row, 1, REVENUE[i].to_s)
  sheet.set_raw(row, 2, COST[i].to_s)
  sheet.set_raw(row, 3, "=B#{row + 1}-C#{row + 1}")
  sheet.set_raw(row, 4, "=D#{row + 1}/B#{row + 1}")
  sheet.set_raw(row, 5, row == 1 ? "=D2" : "=F#{row}+D#{row + 1}")
end
sheet.set_raw(13, 0, "合计")
sheet.set_raw(13, 1, "=SUM(B2:B13)")
sheet.set_raw(13, 2, "=SUM(C2:C13)")
sheet.set_raw(13, 3, "=SUM(D2:D13)")
sheet.set_raw(13, 4, "=D14/B14")
sheet.set_raw(13, 5, "=MAX(F2:F13)")
sheet.set_raw(15, 0, "统计")
sheet.set_raw(15, 1, "=AVERAGE(B2:B13)")
sheet.set_raw(15, 2, "=MIN(B2:B13)")
sheet.set_raw(15, 3, "=MAX(B2:B13)")
sheet.set_raw(15, 4, "=COUNT(B2:B13)")
sheet.set_raw(15, 5, "=SUM(B2:B13)/COUNT(B2:B13)")
sheet.set_raw(17, 0, "参数")
sheet.set_raw(17, 1, "1.08")
sheet.set_raw(18, 0, "涨价情景收入")
sheet.set_raw(18, 1, "=B14*B18")
sheet.set_raw(19, 0, "涨价情景毛利率")
sheet.set_raw(19, 1, "=IF(B14=0,0,(B19-C14)/B19)")

(0..13).each do |row|
  cells = (0..5).map { |col| "#{Sheets::Format.cell_key(row, col)}:#{sheet.display(row, col)}" }
  puts "ROW#{row}|#{cells.join('|')}"
end
(15..19).each do |row|
  cells = (0..5).map { |col| "#{Sheets::Format.cell_key(row, col)}:#{sheet.display(row, col)}" }
  puts "ROW#{row}|#{cells.join('|')}"
end

line "合计行毛利率", sheet.display(13, 4)
line "涨价情景收入", sheet.display(18, 1)
line "涨价情景毛利率", sheet.display(19, 1)
line "公式格数", sheet.formula_count
line "错误格数", sheet.error_count

# ── 3. 错误与循环 ──────────────────────────────────────────
sheet.set_raw(2, 6, "=10/0")
sheet.set_raw(3, 6, "=G3+1")
line "除零传播", sheet.display(3, 6)
sheet.set_raw(5, 6, "=G7")
sheet.set_raw(6, 6, "=G6")
line "循环引用", sheet.display(5, 6)
line "循环引用下游", sheet.display(6, 6)
line "循环计数", sheet.cyclic_count
sheet.set_raw(8, 6, "=1+")
line "解析错误", sheet.display(8, 6)
sheet.set_raw(9, 6, "=ZZ999")
line "越界引用", sheet.display(9, 6)

# ── 4. 增量重算：报告与依赖 ────────────────────────────────
report = sheet.set_raw(1, 1, "200000")
line "重算格数", report[:computed]
line "显示变化格数", report[:cells].size
line "受影响明细", report[:cells].map { |r, c| Sheets::Format.cell_key(r, c) }.sort.join(",")
line "B2 直接依赖数", sheet.dependencies(1, 1).size
line "B2 被依赖数", sheet.dependents(1, 1).size
line "新收入", sheet.display(1, 1)
line "新毛利", sheet.display(1, 3)
line "新毛利率", sheet.display(1, 4)
line "新合计收入", sheet.display(13, 1)

# ── 5. 批量写入与撤销 ──────────────────────────────────────
batch = sheet.set_many([[0, 6, "批量1"], [1, 6, "批量2"], [2, 6, "批量3"]])
line "批量重算格数", batch[:computed]
line "批后取值", (0..2).map { |r| sheet.display(r, 6) }.join(",")
sheet.undo
line "撤销后取值", (0..2).map { |r| sheet.display(r, 6) }.join(",")
sheet.redo
line "重做后取值", (0..2).map { |r| sheet.display(r, 6) }.join(",")
line "撤销栈深", sheet.undo_depth
line "重做栈深", sheet.redo_depth

# ── 6. 格式与显示 ──────────────────────────────────────────
sheet.set_raw(21, 0, "1234567.891")
line "默认显示", sheet.display(21, 0)
sheet.set_chrome([[21, 0]], { decimals: 2 })
line "两位小数", sheet.display(21, 0)
sheet.set_chrome([[21, 0]], { decimals: 0 })
line "整数显示", sheet.display(21, 0)
sheet.set_chrome([[21, 0]], { decimals: 4 })
line "四位小数", sheet.display(21, 0)
show("纯数字文本0.1+0.2", 0.1 + 0.2)
line "列标签", (0..27).map { |i| Sheets::Format.column_label(i) }.join("")
line "千分位", Sheets::Format.grouped(-1_234_567)
line "清空区间前", sheet.display(21, 0)
sheet.clear_range(21, 0, 21, 0)
line "清空区间后", sheet.display(21, 0)
line "填充格数", sheet.filled_count
