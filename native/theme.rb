# frozen_string_literal: true

require_relative "../app/tokens"

module Sheets
  module Native
    # 原生自绘用的配色集中地——**常量全部从 app/tokens.rb 派生**，本文件不再出现
    # 字面量色值：设计令牌的唯一来源是 Tokens（浏览器 CSS 同吃这一份），改配色
    # 只改 app/tokens.rb。Painter 的颜色接口接受 #rgb / #rrggbb / #rrggbbaa
    # （见 docs/design/native-area.md 2.2）。
    #
    # 为什么要有这个文件：着色散在绘制代码里就再也调不动了——这里给原生侧一个
    # 与浏览器 CSS 语义对得上的名字层；个别只在原生存在的色值（见 FORMULA）留在
    # 本文件并注明缘由。
    module Theme
      BG = Tokens[:bg]
      PANEL = Tokens[:panel]
      PANEL_2 = Tokens[:panel_2]
      CELL = Tokens[:cell]
      LINE = Tokens[:line]
      LINE_SOFT = Tokens[:line_soft]
      TEXT = Tokens[:text]
      DIM = Tokens[:dim]
      ACCENT = Tokens[:accent]
      ACCENT_SOFT = Tokens[:accent_soft]
      FLASH = Tokens[:flash]
      FLASH_SOFT = Tokens[:flash_soft]
      DANGER = Tokens[:danger]
      OK = Tokens[:ok]

      # 网格自绘专用：浏览器侧由 CSS 类表达（.cell.is-sel / .cell.is-sel.is-flash /
      # .fx-input:focus），色值在 Tokens（cell_sel / cell_sel_flash / edit_fill）
      SEL_FILL = Tokens[:cell_sel]
      SEL_FLASH = Tokens[:cell_sel_flash]
      EDIT_FILL = Tokens[:edit_fill]

      # 原生侧新增：公式格的数值用一个偏冷的色调标出来（浏览器侧不区分公式格，
      # 自绘网格里"哪些数是算出来的"值得一眼可辨）——只此一处使用，不进 Tokens
      FORMULA = "#93b8f0"

      # 工具条的底色按钮（与 browser 侧 app/panels/toolbar.rb 同源：Tokens 的
      # swatch_amber / swatch_green / swatch_red）
      SWATCH_AMBER = Tokens[:swatch_amber]
      SWATCH_GREEN = Tokens[:swatch_green]
      SWATCH_RED = Tokens[:swatch_red]
    end
  end
end
