# frozen_string_literal: true

require_relative "test_helper"

# 事件路径：点击 / 键盘 → Application 的选区、编辑缓冲、工作簿、撤销栈。
#
# 键盘一律经 `app.global_key`（原生根组件的 window_key 入口）；点击经网格的
# `click_at`（area 的 on_click 处理器体）。两条都是**面板本地坐标/KeyEvent** 这一层，
# 与框架的控件事件投递无关——控件事件的对接在 native_area_contract_test.rb。
class NativeInteractionTest < Minitest::Test
  include NativeTestHelper

  def setup
    @app, @grid = build_grid
  end

  # ── 点击 ────────────────────────────────────────────────────

  def test_click_selects_cell
    @grid.click_at(@grid.cell_x(2) + 10, @grid.cell_y(3) + 10)
    assert_equal "C4", @app.selection_label
    assert_equal "C4", @app.active_key
  end

  def test_click_outside_the_grid_is_ignored
    @grid.click_at(-5, -5)   # 左上角外：原选区不动
    assert_equal "A1", @app.selection_label
  end

  def test_click_column_header_selects_whole_column
    @grid.click_at(@grid.cell_x(1) + 5, 5)
    assert_equal "B1:B60", @app.range_label
    assert_equal 60, @app.selection_size
  end

  def test_click_row_header_selects_whole_row
    @grid.click_at(5, @grid.cell_y(2) + 5)
    assert_equal "A3:Z3", @app.range_label
  end

  # ── 方向键 / 选区 ───────────────────────────────────────────

  def test_arrow_keys_move_selection
    press(@app, "ArrowDown")
    press(@app, "ArrowRight")
    assert_equal "B2", @app.selection_label
  end

  def test_shift_arrow_extends_selection
    @app.select_cell(1, 1)
    press(@app, "ArrowDown", shift: true)
    assert_equal "B2:B3", @app.range_label
    assert_equal 2, @app.selection_size
  end

  def test_tab_moves_and_command_arrow_jumps_to_data_edge
    press(@app, "Tab")
    assert_equal "B1", @app.selection_label

    @app.select_cell(39, 4) # E40：下方整列为空 → ⌘↓ 跳到表格尽头
    press(@app, "ArrowDown", meta: true)
    assert_equal "E60", @app.selection_label
  end

  # ── 编辑：直接打字 / 提交 / 取消 ────────────────────────────

  def test_typing_starts_edit_and_appends_further_chars
    press(@app, "1")
    assert @app.editing?, "首个可打印字符应当开启编辑"
    assert_equal "1", @app.edit_text.get
    press(@app, "2")
    press(@app, "3")
    assert_equal "123", @app.edit_text.get, "后续字符应当追加进编辑缓冲"
  end

  def test_enter_commits_and_moves_down
    @app.select_cell(1, 1) # B2
    press(@app, "9")
    press(@app, "Enter")
    refute @app.editing?
    assert_equal 9.0, @app.workbook.value(1, 1)
    assert_equal "B3", @app.selection_label
    assert_equal "已写入 B2", @app.last_action.get
  end

  def test_tab_commits_and_moves_sideways
    @app.select_cell(1, 1)
    press(@app, "7")
    press(@app, "Tab")
    assert_equal 7.0, @app.workbook.value(1, 1)
    assert_equal "C2", @app.selection_label

    press(@app, "8")
    press(@app, "Tab", shift: true)
    assert_equal 8.0, @app.workbook.value(1, 2)
    assert_equal "B2", @app.selection_label
  end

  def test_escape_cancels_edit
    @app.select_cell(1, 1)
    press(@app, "7")
    press(@app, "Escape")
    refute @app.editing?
    assert_equal 120_000.0, @app.workbook.value(1, 1), "取消后原值不变"
    assert_equal "120000", @app.edit_text.get, "取消后缓冲回到原内容"
  end

  def test_backspace_edits_buffer_while_editing_and_clears_when_not
    @app.select_cell(1, 1)
    press(@app, "4")
    press(@app, "2")
    press(@app, "Backspace")
    assert_equal "4", @app.edit_text.get

    press(@app, "Escape")
    press(@app, "Backspace") # 非编辑态：清空后编辑（浏览器侧同语义）
    assert @app.editing?
    assert_equal "", @app.edit_text.get
  end

  def test_delete_clears_selection_when_not_editing
    @app.select_cell(1, 1)
    press(@app, "Delete")
    assert_nil @app.workbook.raw(1, 1)
    assert_nil @app.workbook.value(1, 1)
  end

  # ── 提交后的重算链与检查器 ──────────────────────────────────

  def test_edit_recalculates_dependents_and_syncs_inspector
    inspector = Sheets::Native::Views::Inspector.new(app: @app)
    @app.select_cell(1, 1) # B2 = 收入
    press(@app, "1")
    press(@app, "0")
    press(@app, "0")
    press(@app, "0")
    press(@app, "0")
    press(@app, "0") # 100000
    press(@app, "Enter")

    assert_equal 100_000.0, @app.workbook.value(1, 1)
    assert_equal 22_000.0, @app.workbook.value(1, 3), "D2 = B2 - C2 没跟着重算"
    refute_nil @app.workbook.value(1, 4), "E2 = D2/B2 没跟着重算"

    report = @app.recalc_view.get
    assert_operator report[:computed].to_i, :>, 0
    assert_equal "已写入 B2", report[:label]

    @app.select_cell(1, 3) # D2
    assert_equal "地址 D2 · 类型 公式 → 数字", inspector.info_title
    assert_equal "← 本格引用了 2 格", inspector.deps_title
    assert_includes inspector.recalc_text, "已写入 B2"
  end

  # ── 快捷键（⌘ 系列）─────────────────────────────────────────

  def test_command_z_undoes_and_reshift_redoes
    @app.select_cell(1, 1)
    press(@app, "5")
    press(@app, "Enter")
    assert_equal 5.0, @app.workbook.value(1, 1)

    press(@app, "z", meta: true)
    assert_equal 120_000.0, @app.workbook.value(1, 1)
    assert_equal 1, @app.workbook.redo_depth

    press(@app, "z", meta: true, shift: true)
    assert_equal 5.0, @app.workbook.value(1, 1)
  end

  # 注意：Application#handle_meta 里的 ⌘B 本意是"切换加粗"，但判据读的是不存在的
  # @active_row/@active_col（恒为 nil → chrome 为空 → 恒算成 bold: true），因此
  # ⌘B 只能加粗、不能取消（既有缺陷，未在本任务里改：那是共享逻辑，见返回说明）。
  # 本测试锁"能加粗 + 工具条能取消"这条可用路径。
  def test_command_b_applies_bold_and_toolbar_can_clear_it
    @app.select_cell(1, 1)
    press(@app, "b", meta: true)
    assert_equal true, @app.workbook.chrome(1, 1)[:bold]
    @app.apply_chrome(bold: false) # 工具条的「常规」
    refute @app.workbook.chrome(1, 1)[:bold]
  end

  def test_command_z_still_reaches_history_while_editing
    @app.select_cell(1, 1)
    press(@app, "5")
    press(@app, "Enter")
    press(@app, "9") # 进入编辑态
    assert @app.editing?

    press(@app, "z", meta: true)
    assert_equal 120_000.0, @app.workbook.value(1, 1), "编辑态下 ⌘Z 仍应走撤销"
  end

  # ── 与 DOM 判据不同构的 raw 不应炸 ──────────────────────────

  def test_non_dom_raw_key_event_is_sanitized
    # Application#handle_key 判 `ev.raw[:target][:tagName]`（DOM 专有）；原生的 raw
    # 可能是 libui 的事件结构，直接索引会抛错 → 原生入口把它换成 raw: nil 的等价视图
    @app.global_key(Citrine::KeyEvent.new("ArrowDown", raw: 42))
    assert_equal "A2", @app.selection_label
  end

  def test_dom_like_raw_pointing_at_input_is_left_alone
    @app.global_key(Citrine::KeyEvent.new("ArrowDown", raw: { target: { tagName: "INPUT" } }))
    assert_equal "A1", @app.selection_label, "焦点在输入框时全局层不接管（既有语义保留）"
  end

  # ── 启动取焦点（SHEETS-1c 的 D1）───────────────────────────
  #
  # 焦点必须在窗口显示 + 应用激活之后才取得到；框架契约是"能力缺口时 AreaHandle#focus
  # 如实返回 false"，所以失败必须变成一句看得见的提示，而不是静默地让方向键落空。

  # 如实返回 false 的句柄替身（模拟"窗口还没激活 / 平台不支持 focus"）
  RefusingHandle = Struct.new(:reason) do
    def focus = false
  end
  AcceptingHandle = Struct.new(:reason) do
    def focus = true
  end

  # 记账句柄替身（SHEETS-1d 的 N2）：既能决定"平台此刻能不能给焦点"，又能断言
  # **有没有伸手去抢**——"不抢"只能靠"没调用过 focus"来证。
  RecordingHandle = Struct.new(:result) do
    def focus
      @calls = (@calls || 0) + 1
      result
    end

    def calls = (@calls || 0)
  end

  def test_focus_area_reports_the_platform_answer
    assert @grid.focus_area(AcceptingHandle.new("ok"))
    refute @grid.focus_area(RefusingHandle.new("no key window"))
    refute @grid.focus_area(nil), "没有面板句柄（未挂载）= 没取到焦点"
  end

  # 把网格推到"到点该给提示"的状态（未挂载 = 拿不到面板句柄 = 取不到焦点，走失败分支）
  def show_hint!
    @grid.instance_variable_set(:@focus_attempts, grid_class::FOCUS_HINT_ATTEMPTS - 1)
    @grid.attempt_focus
    assert_equal grid_class::FOCUS_HINT, @app.notice.get[:text], "前置条件：到点应当先挂出提示"
  end

  # 真窗口里第一次必然失败（on_mount 早于 window_show + 激活）→ 到点先给提示，但不放弃重试
  def test_focus_failure_shows_actionable_hint_and_keeps_retrying
    @grid.schedule_focus # 未挂载 = 拿不到面板句柄，第一次尝试必定失败
    assert @grid.instance_variable_get(:@focus_timer).running?, "取不到焦点应当排上重试定时器"

    while @grid.instance_variable_get(:@focus_attempts) < grid_class::FOCUS_HINT_ATTEMPTS
      @grid.attempt_focus
    end
    assert_equal grid_class::FOCUS_HINT, @app.notice.get[:text]
    assert_includes @app.notice.get[:text], "点一下网格"
    assert @grid.instance_variable_get(:@focus_timer).running?, "给提示之后仍应继续重试（激活可能是晚到的）"
    @grid.stop_focus_timer # 测试不留活线程
  end

  def test_hint_is_dropped_when_a_key_reaches_the_grid
    before = @app.notice.get[:text]
    show_hint!

    # 键能从面板转发进来 = 焦点已经在网格上 → 提示作废，恢复应用自己的首条提示
    @grid.global_key(Citrine::KeyEvent.new("ArrowDown"))
    assert_equal "A2", @app.selection_label
    assert_equal before, @app.notice.get[:text]
  end

  # N1（SHEETS-2b 复审）：提示撤掉之后不能再被重试 tick 点亮。撤提示有两种触发——
  # 用户点了网格、或键打进网格；两种都必须让提示进入"终态"（复审实测：修复前点击后
  # +180~240ms 提示又回来了，而那时用户已经在用键盘了 = 撒谎）。
  def test_dismissed_hint_is_not_relit_by_retry_ticks
    before = @app.notice.get[:text]
    show_hint!

    @grid.click_at(@grid.cell_x(1) + 5, @grid.cell_y(1) + 5)
    assert_equal before, @app.notice.get[:text], "点了网格应当把提示撤掉"

    5.times { @grid.attempt_focus } # 之后的重试 tick（仍然拿不到焦点：没有面板句柄）
    assert_equal before, @app.notice.get[:text], "撤掉的提示不能被重试 tick 重新点亮"
  end

  def test_dismissed_hint_stays_off_after_keys_reached_the_grid
    before = @app.notice.get[:text]
    show_hint!

    @grid.global_key(Citrine::KeyEvent.new("ArrowDown"))
    assert_equal before, @app.notice.get[:text]

    3.times { @grid.attempt_focus }
    assert_equal before, @app.notice.get[:text], "用户已经在用键盘了，提示不该回来"
  end

  # N2（SHEETS-2b 复审）：用户在公式栏输入框里打字（README 的中文输入路径）时，
  # 重试 tick 不得把焦点抢回网格——否则他得再点一次输入框。
  # 应用侧能观察到的判据只有"entry 的文本被改过"（libui 的 entry 不上报焦点/点击）。
  def test_retry_does_not_steal_focus_while_the_user_is_using_an_input
    handle = RecordingHandle.new(false) # 窗口还没激活：如实返回 false（这正是重试窗口）
    @grid.refs[:grid] = handle
    @grid.schedule_focus
    assert_equal 1, handle.calls, "第一次尝试应当真的去取过焦点"

    @app.note_editor_input # 用户在公式栏输入框里打字（Views::FormulaBar 的 on_change）
    3.times { @grid.attempt_focus }

    assert_equal 1, handle.calls, "用户已经在用输入控件，重试不得再抢焦点"
    assert_nil @grid.instance_variable_get(:@focus_timer), "让位之后应当停掉重试定时器"
  end

  # 让位只关掉"抢占"这一件事：网格自己的键盘流与点击不受影响
  def test_yielding_leaves_the_grid_keyboard_flow_intact
    @grid.refs[:grid] = RecordingHandle.new(false)
    @grid.schedule_focus
    @app.note_editor_input
    @grid.attempt_focus
    refute_equal grid_class::FOCUS_HINT, @app.notice.get[:text]

    @grid.global_key(Citrine::KeyEvent.new("ArrowDown"))
    assert_equal "A2", @app.selection_label
    @grid.global_key(Citrine::KeyEvent.new("7"))
    assert @app.editing?
    @grid.global_key(Citrine::KeyEvent.new("Enter"))
    assert_equal 7.0, @app.workbook.value(1, 0), "让位之后打字 + 提交仍照常"
    @grid.click_at(@grid.cell_x(2) + 5, @grid.cell_y(3) + 5)
    assert_equal "C4", @app.selection_label
  end

  def test_hint_is_dropped_on_click
    before = @app.notice.get[:text]
    show_hint!

    @grid.click_at(@grid.cell_x(1) + 5, @grid.cell_y(1) + 5)
    assert_equal "B2", @app.selection_label, "点了网格应当照常选中"
    assert_equal before, @app.notice.get[:text], "点了网格应当把提示撤掉"
  end

  # 提示已经被应用自己的新提示换掉时，撤提示只作废自己的标记、不动别人的文本
  def test_clearing_the_hint_does_not_clobber_a_newer_notice
    show_hint!
    @app.set_notice(:warn, "别的提示")

    @grid.clear_focus_hint
    assert_equal "别的提示", @app.notice.get[:text]
  end

  def test_unmounted_grid_exhausts_retries_and_stops_cleanly
    # 未挂载 = 拿不到面板句柄 = 没取到焦点（与"窗口还没激活"同一条兜底路径）
    @grid.schedule_focus
    refute_nil @grid.instance_variable_get(:@focus_timer), "取不到焦点时应当排延迟重试"

    @grid.stop_focus_timer
    assert_nil @grid.instance_variable_get(:@focus_timer), "卸载后不该留着重试定时器"
  end
end
