# frozen_string_literal: true

require_relative "test_helper"

# 自绘网格"画了什么"：断言绘制序列（列头文字、单元格值、对齐与着色、
# 选中/闪烁高亮、网格线）。
#
# 绘制回调就是普通方法（参数是 Painter），所以不需要控件树也能真跑一遍；
# 录制器用框架自己的 Citrine::Native::Painter::Recording——测的就是生产代码
# 面对的那个接口（颜色归一化、度量、无 width 时的对齐口径都算在内）。
class NativeGridPaintTest < Minitest::Test
  include NativeTestHelper

  def setup
    @app, @grid = build_grid
    @rec = recorder
  end

  def paint
    @grid.paint_grid(@rec)
    @rec
  end

  # ── 内容尺寸与底色 ──────────────────────────────────────────

  def test_content_size_is_all_cells
    # 26 列 × 60 行（+ 行号列 / 列头）
    assert_equal grid_class::HEAD_W + 26 * grid_class::CELL_W, @grid.content_width
    assert_equal grid_class::HEAD_H + 60 * grid_class::CELL_H, @grid.content_height
  end

  def test_background_covers_content
    paint
    first = @rec.calls_of(:rect).first
    assert_equal [0.0, 0.0, @grid.content_width.to_f, @grid.content_height.to_f],
                 [first[:x], first[:y], first[:w], first[:h]]
    assert_equal color(theme::CELL), first[:fill]
  end

  # ── 表头 ────────────────────────────────────────────────────

  def test_column_and_row_headers_are_drawn
    paint
    %w[A B F Z].each { |label| assert_includes strings(@rec), label, "缺列头 #{label}" }
    ["1", "2", "13", "60"].each { |label| assert_includes strings(@rec), label, "缺行号 #{label}" }
  end

  def test_header_text_is_centered
    paint
    col = text_for(@rec, "A")
    col_width = @rec.measure_text("A", size: col[:size], weight: col[:weight])[0]
    assert_equal grid_class::HEAD_W + (grid_class::CELL_W - col_width) / 2, col[:x]

    row = text_for(@rec, "60")
    row_width = @rec.measure_text("60", size: row[:size], weight: row[:weight])[0]
    assert_equal (grid_class::HEAD_W - row_width) / 2, row[:x]
  end

  # ── 单元格值与格式 ──────────────────────────────────────────

  def test_cell_values_are_drawn
    paint
    assert_includes strings(@rec), "月份"      # A1：文本
    assert_includes strings(@rec), "120,000"   # B2：常量数字（千分位）
    assert_includes strings(@rec), "42,000"    # D2：公式 =B2-C2 的计算值
  end

  def test_number_right_aligned_and_text_left_aligned
    paint
    numeric = text_for(@rec, "120,000")
    right_edge = @grid.cell_x(1) + grid_class::CELL_W - grid_class::PAD_X
    width = @rec.measure_text("120,000", size: numeric[:size], weight: numeric[:weight])[0]
    assert_equal right_edge, numeric[:x] + width

    assert_equal @grid.cell_x(0) + grid_class::PAD_X, text_for(@rec, "月份")[:x]
  end

  def test_bold_and_background_come_from_chrome
    paint
    assert_equal 700, text_for(@rec, "月份")[:weight]     # 种子把表头行设为加粗
    assert(rects(@rec, fill: "#182338").any?, "表头行底色没画")
  end

  def test_formula_and_error_colors
    paint
    assert_equal color(theme::FORMULA), text_for(@rec, "42,000")[:color]  # D2 是公式
    assert_equal color(theme::TEXT), text_for(@rec, "120,000")[:color]    # B2 是常量

    error = text_for(@rec, "#DIV/0!") # B28 = =10/0
    refute_nil error
    assert_equal color(theme::DANGER), error[:color]
    assert_equal 700, error[:weight]
  end

  def test_blank_cells_emit_no_text
    paint
    # 1560 格里绝大多数是空的：空白格不出 text 调用（省掉度量与布局）
    assert_operator texts(@rec).size, :<, 400
  end

  # ── 网格线 ──────────────────────────────────────────────────

  def test_grid_lines_cover_every_column_and_row
    paint
    lines = @rec.calls_of(:line)
    assert_equal 27, lines.count { |l| l[:x1] == l[:x2] } # 26 列 + 左边界
    assert_equal 61, lines.count { |l| l[:y1] == l[:y2] } # 60 行 + 上边界
    assert_equal color(theme::LINE_SOFT), lines.first[:color]
  end

  # ── 选中 / 闪烁 / 编辑中 ────────────────────────────────────

  def test_selection_highlight_rect
    @app.select_cell(1, 1) # B2
    paint
    rect = rects(@rec, fill: theme::SEL_FILL).first
    refute_nil rect, "选中高亮没画"
    assert_equal [(@grid.cell_x(1) + 1).to_f, (@grid.cell_y(1) + 1).to_f,
                  (grid_class::CELL_W - 1).to_f, (grid_class::CELL_H - 1).to_f],
                 [rect[:x], rect[:y], rect[:w], rect[:h]]
  end

  def test_selected_axis_headers_are_highlighted
    @app.select_cell(1, 1)
    paint
    # 一条列头 + 一条行号（单格选区）
    assert_equal 2, rects(@rec, fill: theme::ACCENT_SOFT).size
    assert_equal color(theme::ACCENT), text_for(@rec, "B")[:color]
  end

  def test_flash_highlight_uses_flash_color_and_clears
    @grid.sync_flash({ seq: 1, keys: [[1, 1], [2, 3]] })
    paint
    lights = rects(@rec, fill: theme::FLASH_SOFT).map { |r| [r[:x], r[:y]] }
    assert_includes lights, [(@grid.cell_x(1) + 1).to_f, (@grid.cell_y(1) + 1).to_f]
    assert_includes lights, [(@grid.cell_x(3) + 1).to_f, (@grid.cell_y(2) + 1).to_f]

    @grid.clear_flash
    @rec = recorder
    paint
    assert_empty rects(@rec, fill: theme::FLASH_SOFT)
  end

  def test_selection_wins_over_flash
    @app.select_cell(1, 1)
    @grid.sync_flash({ seq: 1, keys: [[1, 1]] })
    paint
    # 唯一闪烁格被选中 → 只剩 .cell.is-sel.is-flash 的底色
    assert_equal 1, rects(@rec, fill: theme::SEL_FLASH).size
    assert_empty rects(@rec, fill: theme::FLASH_SOFT)
  end

  def test_editing_cell_shows_buffer_instead_of_value
    @app.select_cell(1, 1)
    @app.start_edit("999")
    paint
    refute_nil text_for(@rec, "999"), "编辑缓冲没画"
    assert_nil text_for(@rec, "120,000"), "编辑中的格不该再画旧值"
    assert(rects(@rec, stroke: theme::ACCENT).any?, "编辑中的格没有输入焦点描边")
  end

  # ── 长值截断（SHEETS-1c 的 D3）─────────────────────────────
  #
  # 浏览器侧 .cell 是 overflow: hidden + text-overflow: ellipsis；原生侧之前整串直画，
  # 长值会压进邻格叠字（验收者用截图 + OCR 证实）。现在每个有值的格都 clip 到格内。

  def test_every_cell_text_is_wrapped_in_a_clip_block
    paint
    clips = @rec.calls_of(:clip_begin)
    assert_equal clips.size, @rec.calls_of(:clip_end).size, "clip 块不配平"
    assert_operator clips.size, :>, 100, "有值的格都应当被裁到格内"

    # 单元格裁剪 = 格的内容框（左右各留 PAD_X，与浏览器 .cell 的 padding + overflow: hidden 同口径）
    assert_equal [{ x: (@grid.cell_x(0) + grid_class::PAD_X).to_f, y: (@grid.cell_y(0) + 1).to_f,
                    w: (grid_class::CELL_W - grid_class::PAD_X * 2).to_f,
                    h: (grid_class::CELL_H - 1).to_f }],
                 clips.select { |c| c[:x] == @grid.cell_x(0) + grid_class::PAD_X && c[:y] == @grid.cell_y(0) + 1 },
                 "A1 的文本没有被裁到自己的格里"
  end

  def test_short_values_are_not_touched
    paint
    # 种子里的普通值照原样画（截断只对装不下的生效）
    assert_equal "120,000", text_for(@rec, "120,000")[:text]
    assert_equal @grid.cell_x(1) + grid_class::CELL_W - grid_class::PAD_X,
                 text_for(@rec, "120,000")[:x] +
                 @rec.measure_text("120,000", size: 13, weight: 400)[0]
  end

  def test_long_text_is_truncated_with_ellipsis_inside_the_cell
    @app.workbook.set_raw(1, 0, "超长文本" * 6) # A2：文本
    paint

    drawn = texts(@rec).map { |t| t[:text] }.find { |t| t.to_s.start_with?("超长文本") && t.to_s.end_with?("…") }
    refute_nil drawn, "长文本没有被截断加省略号（画出来的是 #{texts(@rec).map(&:to_s).grep(/超长/).inspect}）"
    width = @rec.measure_text(drawn, size: 13, weight: 400)[0]
    assert_operator width, :<=, grid_class::CELL_W - grid_class::PAD_X * 2, "截断后仍然装不下"
    assert_equal @grid.cell_x(0) + grid_class::PAD_X, texts(@rec).find { |t| t[:text] == drawn }[:x]
  end

  def test_long_number_is_right_aligned_without_ellipsis
    @app.workbook.set_raw(1, 0, "123456789012345678") # A2：数字
    paint

    long = @app.workbook.display(1, 0) # 千分位格式化后的实际绘制文本
    number = text_for(@rec, long)
    refute_nil number, "长数字没有画出来（期望 #{long.inspect}）"
    refute_includes number[:text], "…", "数字右对齐时浏览器不显示省略号（裁掉的是左边）"
    width = @rec.measure_text(long, size: 13, weight: 400)[0]
    assert_equal @grid.cell_x(0) + grid_class::CELL_W - grid_class::PAD_X, number[:x] + width,
                 "长数字仍然应当右对齐到格右边界"
    assert_operator number[:x], :<, @grid.cell_x(0), "前提：这个长数字确实装不下（否则本用例没意义）"
    # 装不下的部分靠 clip 挡在格内容框里（左半边越界不会再压进左邻格）
    assert_equal (@grid.cell_x(0) + grid_class::PAD_X).to_f, clip_of(@rec, long)[:x]
  end
end
