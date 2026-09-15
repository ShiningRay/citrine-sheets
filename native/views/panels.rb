# frozen_string_literal: true

require "citrine"
require_relative "../theme"
require_relative "../../app/format"

module Sheets
  module Native
    module Views
      # 工具条/公式栏/检查器/状态栏/埋点面板的原生视图。
      #
      # 这些面板在原生侧**一律用原生控件**（label / button / text_input）：它们没有
      # 自绘的必要（设计文档的非目标：不做 CSS 全集、不做像素级还原），
      # 背景/边框类样式在原生侧不做。逻辑动作全部转调 Application 的公开入口
      # （undo / apply_chrome / commit_edit / select_cell …），本文件不含业务逻辑。
      #
      # 视图纪律（与浏览器侧面板同一口径）：容器块不读信号、会变的值放进叶子块，
      # 只是原生侧"重建一个 label"的代价是微秒级，粒度不必像 DOM 那样抠。
      module Text
        def text_or_dash(value)
          text = value.to_s
          text.empty? ? "（空）" : text
        end

        def number_text(value)
          value.nil? ? "—" : Format.compact(value)
        end
      end

      # 工具条：撤销重做 · 格式 · 清空 · 重算（对应浏览器侧 Panels::Toolbar）
      class Toolbar < Citrine::Component
        prop :app

        def view
          row(gap: 6) do
            label { "#{app.selection_label} · #{app.workbook.rows} 行 × #{app.workbook.cols} 列" }
            button(on_click: -> { app.undo }) { "↶ 撤销" }
            button(on_click: -> { app.redo }) { "↷ 重做" }
            button(on_click: -> { app.apply_chrome(bold: true) }) { "B 加粗" }
            button(on_click: -> { app.apply_chrome(bold: false) }) { "常规" }
            button(on_click: -> { app.apply_chrome(bg: Theme::SWATCH_AMBER) }) { "底色" }
            button(on_click: -> { app.apply_chrome(bg: Theme::SWATCH_GREEN) }) { "底色" }
            button(on_click: -> { app.apply_chrome(bg: Theme::SWATCH_RED) }) { "底色" }
            button(on_click: -> { app.apply_chrome(bg: nil) }) { "无底色" }
            button(on_click: -> { app.apply_chrome(decimals: nil) }) { "自动位" }
            button(on_click: -> { app.apply_chrome(decimals: 2) }) { "2 位" }
            button(on_click: -> { app.clear_selection }) { "清空选区" }
            button(on_click: -> { app.recalculate_all }) { "重算全部" }
            label { history_text }
          end
        end

        # 撤销栈深度不是信号：跟随 last_action 刷新（浏览器侧 Toolbar 同一口径）
        def history_text
          app.last_action.get
          "#{app.last_action.get}（撤销 #{app.workbook.undo_depth} / 重做 #{app.workbook.redo_depth}）"
        end
      end

      # 公式栏：地址 + 编辑缓冲（受控 text_input）+ 确认/取消。
      #
      # 编辑态与焦点在浏览器侧是 FormulaBar 自己的视图关注点（watch 订阅 edit_mode
      # 决定何时 focus 输入框）。原生侧做不到"程序化 focus entry"（冻结接口没有
      # entry 的 focus，设计 2.3 只给了 area 的 focus），因此键盘流改为：
      # 打字/编辑键由 area 侧接管（见 NativeApp#global_key），输入框用于鼠标点选后续改；
      # 提交/取消两条路都有——按钮，以及编辑态下 area 收到的 Enter/Esc。
      class FormulaBar < Citrine::Component
        prop :app

        def view
          stack(gap: 4) do
            row(gap: 6) do
              label { "位置 #{app.selection_label}" }
              # entry 的 on_change = "用户在输入框里改了文本"（程序化写入是静默的，不会误报）
              # → 启动取焦点让位，不再抢走输入框（见 NativeApp#note_editor_input 的注释）。
              text_input(value: app.edit_text, on_change: ->(_text) { app.note_editor_input })
              button(on_click: -> { app.commit_edit(1, 0) }) { "确认 ↵" }
              button(on_click: -> { app.cancel_edit }) { "取消 Esc" }
            end
            label { hint_text }
          end
        end

        def hint_text
          if app.edit_mode.get
            "编辑中 #{app.active_key}：Enter/确认 提交并下移 · Esc/取消 退回原值"
          else
            app.notice.get[:text]
          end
        end
      end

      # 检查器：当前格内容/值/类型 + 依赖跳转 + 上次重算报告（对应 Panels::Inspector）
      class Inspector < Citrine::Component
        include Text
        prop :app

        def view
          stack(gap: 3) do
            label { info_title }
            label { "原始输入 #{text_or_dash(app.active_info[:raw])}" }
            label { "计算值 #{text_or_dash(app.active_info[:display])}" }
            label { deps_title }
            row(gap: 4) { jump_buttons(app.active_dependencies) }
            label { dependents_title }
            row(gap: 4) { jump_buttons(app.active_dependents) }
            label { recalc_text }
          end
        end

        def info_title
          info = app.active_info
          "地址 #{info[:key_label]} · 类型 #{info[:kind_label]}"
        end

        def deps_title
          "← 本格引用了 #{app.active_dependencies.size} 格"
        end

        def dependents_title
          "→ 有 #{app.active_dependents.size} 格引用本格"
        end

        def recalc_text
          report = app.recalc_view.get
          "上次重算 #{report[:label]}：重算 #{report[:computed].to_i} 格 · " \
            "显示变化 #{report[:cells].to_i} 格 · #{report[:elapsed].to_i} ms"
        end

        # 依赖标签（最多 6 个）——点一下跳过去，与浏览器侧的 chip 同语义。
        # 末尾的 label 兜"无依赖"，同时保证这个块总有子节点（原生容器没有文本位，
        # 块返回非字符串又没有子节点时框架会给一条 dev 提醒）
        def jump_buttons(keys)
          keys.first(6).each do |(row, col)|
            key = Format.cell_key(row, col)
            button(on_click: -> { app.select_cell(row, col) }) { key }
          end
          label { keys.empty? ? "无（不是公式格）" : "" }
        end
      end

      # 状态栏：选区聚合统计 + 全表统计（对应 Panels::StatusBar）
      class StatusBar < Citrine::Component
        include Text
        prop :app

        def view
          stack(gap: 2) do
            label { stats_text }
            label { summary_text }
          end
        end

        def stats_text
          stats = app.live_stats # 读选区 + 重算信号（值变了统计才需要重算）
          "选区 #{app.selection_label} · 单元格 #{stats[:cells]} · 数值 #{stats[:numeric_count]} · " \
            "求和 #{number_text(stats[:sum])} · 平均 #{number_text(stats[:average])} · " \
            "最小 #{number_text(stats[:min])} · 最大 #{number_text(stats[:max])} · 错误 #{stats[:errors]}"
        end

        def summary_text
          app.last_action.get
          app.sheet_summary
        end
      end

      # 埋点面板：框架在"一次用户动作"里做了多少工作（对应 Panels::DebugBar）
      class DebugBar < Citrine::Component
        prop :app

        def view
          stack(gap: 2) do
            label { metrics_text }
            label { "口径：一次编辑 = 从动作开始到发布完成；原生侧的『新建控件』= 控件树重建次数" }
          end
        end

        def metrics_text
          report = Sheets::Telemetry.report
          app.last_action.get # 每次动作刷新
          "挂载 #{app.mount_ms} ms · 本轮 Effect 重跑 #{report[:effect_runs]} · " \
            "本轮新建控件 #{report[:node_creates]} · 累计 #{report[:total_node_creates]} · " \
            "信号对象 #{app.signal_count} · 编辑轮次 #{report[:rounds]}"
        end
      end
    end
  end
end
