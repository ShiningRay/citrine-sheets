# backtick_javascript: true
# frozen_string_literal: true

# 浏览器外挂层。
#
# citrine v1 没有全局键盘事件、没有生命周期钩子、没有定时器、没有 ref
# （FRICTION F7 / F10），所以"键盘优先的电子表格"这些都得在框架外自己接：
#   · window.addEventListener("keydown") —— 方向键导航、打字即编辑、快捷键
#   · window.setInterval —— 清理上一次编辑的闪烁标注（框架无调度器）
#   · 原生 focus()/blur() —— 编辑框焦点控制（框架无 ref）
#   · window.sheetsTestApi —— 供 Node 桩验收脚本无头驱动
require "native"
require "citrine"
require "citrine/dom"

module Sheets
  class Glue
    TICK_MS = 110

    # ⚠ 参数不能叫 window：反引号里的 `window` 编译成 JS 标识符引用，
    #    会被同名 Ruby 参数遮蔽（生成 self.$Native(window) → 传进来的是参数 nil）。
    #    这是 Opal 互操作的隐蔽陷阱，命名避开即可。
    def initialize(app, host = nil)
      @app = app
      @host = host || Native(`window`)
      @interval = nil
      @ticks = 0
      @last_key = ""
    end

    def start
      @host.addEventListener("keydown", ->(event) { handle_key(Native(event)) })
      @host.addEventListener("beforeunload", ->(_event) { stop })
      @interval = @host.setInterval(-> { tick }, TICK_MS)
      self
    end

    def stop
      @host.clearInterval(@interval) if @interval
      @interval = nil
      self
    end

    def tick
      @ticks += 1
      @app.tick_visuals
      self
    end

    # ── 键盘 ────────────────────────────────────────────────

    def handle_key(event)
      key = event[:key].to_s
      @last_key = key
      target = event[:target]
      tag = target ? target[:tagName].to_s.upcase : ""
      shift = event[:shiftKey]
      meta = event[:metaKey] || event[:ctrlKey]

      if tag == "INPUT"
        # 编辑框内：只接管 Esc / Tab；Enter 交给 text_input 的 on_enter；
        # 方向键留给光标移动（不拦截）
        case key
        when "Escape" then swallow(event) { @app.cancel_edit }
        when "Tab" then swallow(event) { @app.commit_edit(0, shift ? -1 : 1) }
        end
        return self
      end

      if meta
        handle_meta(event, key, shift)
        return self
      end

      case key
      when "ArrowUp" then swallow(event) { arrow(-1, 0, shift) }
      when "ArrowDown" then swallow(event) { arrow(1, 0, shift) }
      when "ArrowLeft" then swallow(event) { arrow(0, -1, shift) }
      when "ArrowRight" then swallow(event) { arrow(0, 1, shift) }
      when "Enter" then swallow(event) { @app.start_edit }
      when "Tab" then swallow(event) { @app.move(0, shift ? -1 : 1) }
      when "Escape" then @app.set_notice(:info, "方向键移动 · 直接打字即编辑 · Enter 编辑 · Esc 取消")
      when "Delete" then swallow(event) { @app.clear_selection }
      when "Backspace" then swallow(event) { @app.start_edit("") }
      else
        # 可打印字符 → 直接开始编辑（Excel 的习惯）
        swallow(event) { @app.start_edit(key) } if printable?(key, event)
      end
      self
    end

    def last_key
      @last_key
    end

    private

    def handle_meta(event, key, shift)
      case key
      when "z", "Z" then swallow(event) { shift ? @app.redo : @app.undo }
      when "b", "B" then swallow(event) { @app.apply_chrome(bold: !@app.workbook.chrome(@app.active_row, @app.active_col)[:bold]) }
      when "s", "S" then swallow(event) { @app.set_notice(:info, "这是本地模拟表格，没有文件保存") }
      when "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"
        swallow(event) { arrow(*delta(key), shift, jump: true) }
      end
    end

    def arrow(dr, dc, extend, jump: false)
      if jump
        @app.jump(dr, dc, extend: extend)
      else
        @app.move(dr, dc, extend: extend)
      end
    end

    def delta(key)
      case key
      when "ArrowUp" then [-1, 0]
      when "ArrowDown" then [1, 0]
      when "ArrowLeft" then [0, -1]
      else [0, 1]
      end
    end

    def printable?(key, event)
      key.length == 1 && !event[:altKey]
    end

    def swallow(event)
      event.preventDefault
      yield
      self
    end

    public

    # 供 Node 桩验收脚本调用（见 test/sheets_stub_check.js）
    def expose_test_api
      app = @app
      breakdown = Sheets::Telemetry.breakdown.map { |k, v| "#{k}:#{v}" }.join(", ")
      `window.sheetsTestApi = {
         state: function () { return #{app}.$test_state_text(); },
         tick: function () { #{app}.$tick_visuals(); },
         breakdown: function () { return #{breakdown.inspect}; },
         focusEditor: function () { #{app}.$focus_editor(); return document.activeElement ? document.activeElement.className : "none"; }
       }`
      self
    end
  end
end
