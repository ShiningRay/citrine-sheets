# frozen_string_literal: true

# 原生入口：把 Sheets 的**同一份逻辑**（app/application.rb 的选区/编辑/撤销/格式/
# 重算）挂到 citrine-native 的原生窗口上，视图换成 native/views/**。
#
#   bin/native          （推荐）
#   ruby native/app.rb  （等价：本文件自带加载路径引导）
#
# 三个仓库的关系（默认同级目录，可用环境变量改写）：
#   citrine/         框架（平台无关核心 + Opal 浏览器后端）
#   citrine-native/  CRuby 原生运行时（libui 后端，实现 Citrine::Renderer 协议）
#   本仓库           demo：app/ 是逻辑与浏览器视图，native/ 是原生视图
repo_root = File.expand_path("..", __dir__)
{
  "CITRINE_ROOT" => "citrine",
  "CITRINE_NATIVE_ROOT" => "citrine-native",            # 核心包（Renderer/App/协议）
  "CITRINE_NATIVE_LIBUI_ROOT" => "citrine-native-libui" # libui 后端（Widgets::Libui）
}.each do |env, name|
  lib = File.join(ENV[env] || File.expand_path("../#{name}", repo_root), "lib")
  $LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
end
app_lib = File.join(repo_root, "app")
$LOAD_PATH.unshift(app_lib) unless $LOAD_PATH.include?(app_lib)

require "citrine"
require "citrine/native"
require "citrine-native-libui" # 加载即登记后端 :libui 并设为默认
require_relative "../app/application"
require_relative "../app/seed"
require_relative "../app/telemetry"
require_relative "theme"
require_relative "views/grid"
require_relative "views/panels"

module Sheets
  module Native
    DEFAULT_WINDOW = { title: "Citrine Sheets（原生）", width: 1240, height: 860, margined: true }.freeze

    # 应用根组件：**只覆盖视图与平台钩子**，逻辑方法（select_cell / global_key 转发的
    # handle_key / commit_edit / cancel_edit / undo / redo / apply_chrome / clear_selection /
    # recalculate_all / active_info / live_stats …）全部原样复用 Sheets::Application——
    # 这也是本移植的验收点：换掉视图层之后，键盘流与重算链路应当一模一样。
    #
    # 唯一"原生适配"是键盘入口：浏览器侧 Enter/Esc/Tab 由 <input> 自己接管
    # （Application#handle_key 用 `raw[:target].tagName == "INPUT"` 把全局层摘出去），
    # 原生 entry 根本收不到这些键（libui 的限制，设计文档 2.3），所以编辑态的按键
    # 由 area 侧补上（见 edit_key）——逻辑仍落在 Application 的公开入口上。
    class NativeApp < Sheets::Application
      on_mount :record_mount_ms

      # ── 原生视图协作位（不是业务状态）────────────────────────
      # 用户有没有在应用自己的输入控件里打字（= 公式栏 entry 的文本被改过，由
      # Views::FormulaBar 的 on_change 记下）。启动取焦点（Views::Grid#schedule_focus）
      # 据此让位，不再把焦点从他手里抢回网格（SHEETS-2b 的 N2）。
      #
      # 为什么把它放在 app 上：公式栏与网格是两个兄弟组件，app 是它们共享的上下文。
      # 为什么判据是"文本被改过"而不是"焦点在输入框里"：libui 的 entry 不上报焦点/点击
      # 事件，应用侧看不到后者（程序化 set 是静默的，所以这个判据不会误报）。
      def note_editor_input = (@editor_input_seen = true)

      def editor_input_seen? = @editor_input_seen == true

      def initialize(workbook: Workbook.new, clock: nil)
        @boot_ms = Native.now_ms
        super(workbook: workbook, clock: clock || Native.method(:now_ms))
      end

      def view
        # 根元素**必须自己声明 flex_grow: 1**（SHEETS-1c 的 D2 实测）：框架把组件树的
        # 根元素追加进"窗口内的根容器"时，stretchy 取的是根元素自己的样式；不声明就只有
        # 内容自然高度——窗口下半截全空白，而且里面所有 flex_grow 都分不到空间
        # （子控件的 flex_grow 只能分父容器已经撑开的余量）。
        #
        # 窗口 1240×860 时的实测（口径见 native/README.md 的实测表）：
        #   · 网格控件本身（NSScrollView，含滚动条位）596×232 → 596×684
        #   · 网格可见区（去掉滚动条）578×214 → 579×667 ≈ 27 行——`Painter#clip_rect`
        #     现在报的就是它（只有首帧瞬态会报回控件尺寸，见 README 的限制表）
        # 两个口径别混：控件尺寸含滚动条、可见区才是"能看见几行"。
        stack(gap: 8, style: { flex_grow: 1 }) do
          render(Views::Toolbar, app: self)
          render(Views::FormulaBar, app: self)
          row(gap: 8, style: { flex_grow: 1 }) do
            stack(gap: 0, style: { flex_grow: 3 }) { render(Views::Grid, app: self) }
            stack(gap: 8, style: { flex_grow: 2 }) do
              render(Views::Inspector, app: self)
              render(Views::DebugBar, app: self)
            end
          end
          render(Views::StatusBar, app: self)
        end
      end

      # ── 键盘 ────────────────────────────────────────────────

      # 全局键盘（G-9 的原生形态）：由聚焦的网格面板转发进来（Views::Grid 声明 window_key），
      # 逻辑仍在 Application#handle_key；本方法只补平台差异（见 edit_key / sanitized_key）。
      def global_key(ev)
        editing? ? edit_key(ev) : handle_key(sanitized_key(ev))
      end

      # 编辑态的按键：浏览器侧这些键落在 <input> 上（FormulaBar 的 on_enter/on_key），
      # 原生 entry 拿不到，改由 area 侧按同一语义补上——
      # Enter 提交并下移 / Tab 提交并横移 / Esc 取消 / Backspace 删一个字符 /
      # Delete 清缓冲 / 可打印字符追加进缓冲 / ⌘ 组合键交给 Application#handle_key
      # （⌘Z 撤销、⌘B 加粗）。
      #
      # **方向键在编辑态什么都不做**（与浏览器一致：那边方向键被 <input> 自己吞掉，
      # 既不改缓冲也不动选区）：下面是 case/else，方向键的 key 名长度 > 1 且不带 ⌘，
      # 因此既不提交也不移动。SHEETS-1c 之前这里的注释写成"方向键经 move 提交后移动"，
      # 与实现不符（D5）；本轮选择**对齐浏览器行为**并把注释改成事实，没有悄悄改语义。
      def edit_key(ev)
        key = ev.key
        return handle_key(sanitized_key(ev)) if ev.command?

        case key
        when "Enter" then commit_edit(1, 0)
        when "Tab" then commit_edit(0, ev.shift? ? -1 : 1)
        when "Escape" then cancel_edit
        when "Backspace" then edit_text_input(edit_text.get[0..-2].to_s)
        when "Delete" then edit_text_input("")
        else
          edit_text_input(edit_text.get + key) if key.length == 1 && !ev.alt?
        end
        self
      end

      # Application#handle_key 用 `ev.raw[:target][:tagName] == "INPUT"` 判断"焦点在
      # 输入框里 → 全局层不接管"，那是 DOM 专有的判据。原生侧的 raw 多半不是 DOM 事件
      # （libui 的事件结构，`[]` 语义未知：对 Integer 之类直接索引会抛错），
      # 因此只放行"与 DOM 判据同构"的 Hash 形态，其余换成 raw 为 nil 的等价视图 ——
      # tag 判断退化成"不跳过"（原生 entry 的按键本来就由控件自己消费，到不了这里）。
      def sanitized_key(ev)
        raw = ev.raw
        return ev if raw.nil? || raw.is_a?(Hash)

        Citrine::KeyEvent.new(ev.key, shift: ev.shift?, meta: ev.meta?, ctrl: ev.ctrl?, alt: ev.alt?,
                                      prevent_default: -> { ev.prevent_default })
      end

      # 挂载耗时：只有整棵树挂完之后才知道（埋点面板读这个信号）。浏览器侧由入口
      # 回填（sheets.rb 的 mark_mounted），原生侧没有"挂载完成后"的入口点，用 on_mount。
      def record_mount_ms
        mark_mounted((Native.now_ms - @boot_ms).round)
      end
    end

    class << self
      def now_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end

      # 建应用：埋点先装（包 Effect#run 计数）、载入示例数据（不进撤销栈）
      def build(workbook: Workbook.new)
        Sheets::Telemetry.install!
        app = NativeApp.new(workbook: workbook)
        Sheets::Seed.load!(app.workbook)
        app
      end

      def run!(**options)
        # signals: :default —— Ctrl+C / SIGTERM 走"退出主循环 → 有序拆解"（框架按
        # `Signal.list` 过滤平台实际存在的信号，见 App#trap_quit!）。在此之前这里是硬杀：
        # libui 的控件销毁记账会整个跳过。
        Citrine::Native.run(build, signals: :default, **DEFAULT_WINDOW.merge(options))
      end
    end
  end
end

Sheets::Native.run! if $PROGRAM_NAME == __FILE__
