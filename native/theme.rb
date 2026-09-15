# frozen_string_literal: true

module Sheets
  module Native
    # 原生自绘用的配色集中地。
    #
    # 取值与 `app/sheets.html` 的 `:root` 设计令牌**同名同值**（含 `rgba(...)` 的
    # `#rrggbbaa` 形式），改配色时两边对着看；Painter 的颜色接口接受
    # `#rgb` / `#rrggbb` / `#rrggbbaa`（见 docs/design/native-area.md 2.2）。
    #
    # 为什么要有这个文件：着色散在绘制代码里就再也调不动了——原生的"样式"只有颜色，
    # 集中一处是唯一的杠杆点。
    module Theme
      BG = "#080d18"
      PANEL = "#101a2e"
      PANEL_2 = "#14203a"
      CELL = "#0e1626"
      LINE = "#1e2c48"
      LINE_SOFT = "#17233b"
      TEXT = "#e6ecf8"
      DIM = "#7a88a3"
      ACCENT = "#4f9cf9"
      ACCENT_SOFT = "#4f9cf929" # rgba(79,156,249,.16)
      FLASH = "#d8a13a"
      FLASH_SOFT = "#d8a13a38" # rgba(216,161,58,.22)
      DANGER = "#f2686f"
      OK = "#30c48d"

      # 网格自绘专用：浏览器侧由 CSS 类表达（.cell.is-sel / .cell.is-sel.is-flash /
      # .fx-input:focus），自绘侧必须给出具体颜色
      SEL_FILL = "#16294a"
      SEL_FLASH = "#2b3448"
      EDIT_FILL = "#0d1728"
      # 原生侧新增：公式格的数值用一个偏冷的色调标出来（浏览器侧不区分公式格，
      # 自绘网格里"哪些数是算出来的"值得一眼可辨）
      FORMULA = "#93b8f0"

      # 工具条的底色按钮（与 app/panels/toolbar.rb 里的取值一致）
      SWATCH_AMBER = "#3a2f14"
      SWATCH_GREEN = "#12351f"
      SWATCH_RED = "#3a1a22"
    end
  end
end
