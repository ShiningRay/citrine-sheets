# frozen_string_literal: true

require_relative "workbook"

module Sheets
  # 示例数据：12 个月损益表 + 统计 + 情景分析（含可改参数）+ 五种错误演示。
  #
  # 载入时一次性写入（一次重算、一次发布），且不进撤销栈——
  # 撤销不该把整张表撤没。
  #
  # 写法约定：数组元素为 [行, 列, 内容]，行列为 0 基；内容以 "=" 开头即公式。
  module Seed
    MONTHS = %w[1月 2月 3月 4月 5月 6月 7月 8月 9月 10月 11月 12月].freeze
    REVENUE = [120_000, 132_500, 118_900, 145_200, 151_800, 138_400,
               160_100, 172_300, 158_700, 181_500, 195_200, 208_900].freeze
    COST = [78_000, 84_100, 79_600, 88_700, 92_300, 87_500,
            95_800, 99_400, 96_200, 104_100, 108_600, 112_300].freeze

    # 表格布局（1 基行号，便于与公式对照）：
    #   第 1 行      表头
    #   第 2–13 行   12 个月：B 收入、C 成本、D 毛利、E 毛利率、F 累计毛利
    #   第 14 行     合计
    #   第 16–18 行  统计（月均/最好月份/毛利率区间）
    #   第 20–25 行  情景分析（C20 是可改的涨价系数）
    #   第 27–33 行  错误演示
    module_function

    def load!(workbook)
      workbook.set_many(entries, record: false)
      apply_formatting(workbook)
      workbook
    end

    def entries
      header_rows + month_rows + summary_rows + scenario_rows + error_rows
    end

    def header_rows
      [
        [0, 0, "月份"], [0, 1, "收入"], [0, 2, "成本"], [0, 3, "毛利"],
        [0, 4, "毛利率"], [0, 5, "累计毛利"]
      ]
    end

    def month_rows
      rows = []
      MONTHS.each_with_index do |month, i|
        row = i + 1
        n = row + 1 # 1 基行号
        rows << [row, 0, month]
        rows << [row, 1, REVENUE[i].to_s]
        rows << [row, 2, COST[i].to_s]
        rows << [row, 3, "=B#{n}-C#{n}"]
        rows << [row, 4, "=D#{n}/B#{n}"]
        rows << [row, 5, row == 1 ? "=D2" : "=F#{row}+D#{n}"]
      end
      rows
    end

    def summary_rows
      [
        [13, 0, "合计"], [13, 1, "=SUM(B2:B13)"], [13, 2, "=SUM(C2:C13)"],
        [13, 3, "=SUM(D2:D13)"], [13, 4, "=D14/B14"], [13, 5, "=MAX(F2:F13)"],
        [15, 0, "统计"], [15, 1, "=AVERAGE(B2:B13)"], [15, 2, "=MIN(B2:B13)"],
        [15, 3, "=MAX(B2:B13)"], [15, 4, "=COUNT(B2:B13)"],
        [15, 5, "=SUM(B2:B13)/COUNT(B2:B13)"],
        [16, 0, "累计毛利峰值"], [16, 1, "=MAX(F2:F13)"], [16, 3, "=IF(E14>0.25,\"健康\",\"偏薄\")"],
        [17, 0, "毛利率区间"], [17, 1, "=MIN(E2:E13)"], [17, 2, "=MAX(E2:E13)"]
      ]
    end

    def scenario_rows
      [
        [19, 0, "情景分析"], [19, 1, "涨价系数"], [19, 2, "1.08"],
        [20, 0, "调价后收入"], [20, 1, "=B14*C20"],
        [21, 0, "调价后毛利"], [21, 1, "=B21-C14"],
        [22, 0, "调价后毛利率"], [22, 1, "=IF(B21=0,0,B22/B21)"],
        [23, 0, "与原毛利率差"], [23, 1, "=B23-E14"],
        [24, 0, "结论"], [24, 1, "=IF(B24>0.02,\"提价显著改善\",IF(B24>0,\"略好\",\"无改善\"))"]
      ]
    end

    def error_rows
      [
        [26, 0, "错误演示"], [26, 1, "公式（B 列显示计算结果）"], [26, 2, "说明"],
        [27, 0, "除零"], [27, 1, "=10/0"], [27, 2, "分母为 0"],
        [28, 0, "循环引用"], [28, 1, "=B30"], [28, 2, "与下一格互相引用"],
        [29, 1, "=B29"], [29, 2, "环的另一半"],
        [30, 0, "越界引用"], [30, 1, "=ZZ999"], [30, 2, "超出表格范围"],
        [31, 0, "类型错误"], [31, 1, "=\"abc\"*2"], [31, 2, "文本不能做算术"],
        [32, 0, "未知函数"], [32, 1, "=NOPE(1)"], [32, 2, "函数名不存在"]
      ]
    end

    def apply_formatting(workbook)
      bold_row(workbook, 0, 0..5, "#182338")
      bold_row(workbook, 13, 0..5, "#1b2a40")
      bold_row(workbook, 15, 0..5, "#1b2a40")
      bold_row(workbook, 19, 0..2, "#1b2a40")
      bold_row(workbook, 26, 0..2, "#33172a")

      workbook.set_chrome((1..12).map { |r| [r, 4] }, { decimals: 4 }, record: false)
      workbook.set_chrome((1..13).map { |r| [r, 5] }, { decimals: 0 }, record: false)
      workbook.set_chrome((16..17).flat_map { |r| (1..3).map { |c| [r, c] } },
                          { decimals: 4 }, record: false)
      workbook.set_chrome([[13, 4], [22, 1], [23, 1]], { decimals: 4 }, record: false)
      workbook.set_chrome((1..13).map { |r| [r, 1] }, { decimals: 0 }, record: false)
      workbook.set_chrome((1..13).map { |r| [r, 2] }, { decimals: 0 }, record: false)
      workbook.set_chrome((1..13).map { |r| [r, 3] }, { decimals: 0 }, record: false)
      workbook.set_chrome((20..23).map { |r| [r, 1] }, { decimals: 2 }, record: false)
      workbook.set_chrome((27..32).map { |r| [r, 1] }, { bg: "#331720" }, record: false)
      workbook.set_chrome((27..32).map { |r| [r, 2] }, { bg: "#1a1f2e" }, record: false)
      workbook
    end

    def bold_row(workbook, row, cols, background)
      keys = cols.map { |col| [row, col] }
      workbook.set_chrome(keys, { bold: true, bg: background }, record: false)
    end
  end
end
