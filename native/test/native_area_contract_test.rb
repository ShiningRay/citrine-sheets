# frozen_string_literal: true

require_relative "test_helper"

# 与 citrine-native 的 area 能力在**控件级**对接（Memory 桩后端，无窗口）：
# 断言框架真的按冻结接口建了自绘面板、真的把点击/按键送到了应用、
# 以及"一次编辑 → 面板排队重绘"。
#
# 与前两个测试文件的分工：
#   · grid_paint_test / interaction_test —— 绘制与事件映射的**应用侧逻辑**（不需要控件树）
#   · 本文件 —— 元素契约与派发路径（挂载级）
class NativeAreaContractTest < Minitest::Test
  include NativeTestHelper

  def setup
    @backend = Citrine::Native::Widgets.memory
    @app = Sheets::Native.build
    @native = Citrine::Native.start(@app, widgets: @backend, title: "契约测试",
                                           width: 900, height: 600)
    @area = @backend.find(@native.root.dom, kind: :area)
    @grid = grid_class.new(app: @app)
  end

  def teardown
    @native&.teardown
  end

  # ── 元素契约 ────────────────────────────────────────────────

  def test_area_widget_is_created_with_content_size_and_scroll
    refute_nil @area, "原生应用挂载后没有 area 控件（element(:area) 没被渲染器接住）"
    assert_equal [@grid.content_width, @grid.content_height], @backend.area_size(@area)
    assert @backend.scrolling?(@area), "网格应当是滚动面板（26 列 × 60 行装不进视口）"
  end

  # 启动即需键盘（设计 2.3）：挂载后应用应当把焦点交给面板，否则方向键/打字都收不到。
  # 真窗口里这一次会失败（on_mount 早于 window_show + 应用激活，还没有 key window），
  # 由 Views::Grid 的延迟重试兜住——那一段只有真窗口能验（见 native/README.md）。
  def test_grid_takes_keyboard_focus_on_mount
    assert @backend.focused?(@area), "挂载后没有把键盘焦点交给网格面板"
  end

  # D2（SHEETS-1c）：根元素必须**自己**声明 flex_grow，否则它只占内容自然高度，
  # 窗口下半空白、网格的 flex_grow 链断在这一环（真窗口实测：网格控件 596×232 → 596×684，
  # 可见区 578×214 → 579×667；口径见 native/README.md 的实测表）。
  def test_root_view_stretches_in_the_window_container
    style = Citrine::Style.normalize(@native.root.children.first.props[:style])
    assert_operator style[:flex_grow].to_f, :>, 0,
                    "根元素没有声明 flex_grow：窗口容器不会给它剩余空间，网格视口撑不满"
  end

  def test_draw_records_headers_values_and_selection
    rec = @backend.fire_draw(@area)
    assert_equal [@grid.content_width, @grid.content_height], [rec.width, rec.height],
                 "绘制尺寸应当是内容尺寸（滚动面板下 Draw 不报尺寸，只能来自 size:）"

    assert_includes strings(rec), "A", "列头没画"
    assert_includes strings(rec), "120,000", "单元格值没画（种子数据 B2）"

    @app.select_cell(1, 1)
    rec = @backend.fire_draw(@area)
    assert(rects(rec, fill: theme::SEL_FILL).any?, "选中高亮矩形没画")
  end

  # ── 事件派发（控件 → 组件 → Application）────────────────────

  def test_click_through_widget_changes_selection
    grid = grid_class
    @backend.fire_click(@area, grid::HEAD_W + 2 * grid::CELL_W + 10, grid::HEAD_H + 3 * grid::CELL_H + 10)
    assert_equal "C4", @app.selection_label
  end

  def test_click_on_column_header_selects_whole_column
    # 列 B 的表头区间：x ∈ [HEAD_W + CELL_W, HEAD_W + 2*CELL_W)
    @backend.fire_click(@area, grid_class::HEAD_W + grid_class::CELL_W + 5, 5)
    assert_equal "B1:B60", @app.range_label
  end

  def test_key_through_widget_edits_and_commits
    @backend.fire_key(@area, "ArrowDown")
    assert_equal "A2", @app.selection_label
    @backend.fire_key(@area, "5")
    assert @app.editing?, "可打印字符应当进入编辑态"
    @backend.fire_key(@area, "Enter")
    assert_equal 5.0, @app.workbook.value(1, 0)
  end

  # ── 重绘调度 ────────────────────────────────────────────────

  def test_edit_queues_a_repaint
    before = @backend.redraw_count(@area)
    @app.select_cell(1, 1)
    @app.start_edit("77")
    @app.commit_edit(1, 0)
    assert_operator @backend.redraw_count(@area), :>, before,
                    "一次编辑之后面板应当被排队重绘（设计 2.4 的兜底）"
  end

  # ── 启动焦点（D1）：晚到的成功要把提示撤掉 ───────────────────

  def test_late_focus_success_drops_the_hint
    # 未挂载的网格 = 拿不到面板句柄 = 取不到焦点（真窗口里 on_mount 那一次就是这样）
    grid = grid_class.new(app: @app)
    grid.instance_variable_set(:@focus_attempts, grid_class::FOCUS_HINT_ATTEMPTS - 1)
    grid.attempt_focus
    assert_equal grid_class::FOCUS_HINT, @app.notice.get[:text], "到点还没拿到焦点应当给提示"

    # 激活晚到：拿到真句柄后下一次重试成功（桩后端的 focus 恒成功）
    grid.refs[:grid] = Citrine::Native::AreaHandle.new(widgets: @backend, handle: @area)
    grid.attempt_focus
    assert @backend.focused?(@area), "晚到的成功应当真的把焦点交给面板"
    refute_equal grid_class::FOCUS_HINT, @app.notice.get[:text], "拿到焦点后提示不能继续挂着"
    assert_equal "点选单元格或直接输入；方向键移动，Enter 编辑，Esc 取消", @app.notice.get[:text]
  end

  # N2（SHEETS-1d）：用户在公式栏 entry 里打字 → 启动取焦点让位，重试 tick 不再抢焦点。
  # 这是"焦点在输入框里不被抢走"在控件级（挂载后的真句柄）的断言。
  def test_entry_edit_yields_the_startup_focus_retry
    grid = area_node.owner
    entry = @backend.find(@native.root.dom, kind: :entry)
    refute_nil entry, "公式栏没有 entry 控件"
    refute @app.editor_input_seen?, "前置条件：还没人在输入框里打过字"

    entry.value = "中文" # 用户点进输入框并打字（受控绑定：改值后触发 change）
    entry.fire(:change)

    assert @app.editor_input_seen?, "entry 的编辑应当让启动取焦点让位（N2）"

    # 让位之后，重试 tick 不得把焦点从输入框抢回面板：
    # 把桩后端的焦点记账清零，看重试有没有再伸手
    @area.instance_variable_set(:@focused, false)
    grid.attempt_focus
    refute @backend.focused?(@area), "用户已经在用输入框，重试 tick 不得抢走焦点"
  end

  private

  # 挂载树里的自绘面板节点（要拿挂载后的组件实例时用）
  def area_node
    find = lambda do |node|
      return node if node.type == :area

      node.children.each { |child| (found = find.call(child)) && (return found) }
      nil
    end
    find.call(@native.root)
  end
end
