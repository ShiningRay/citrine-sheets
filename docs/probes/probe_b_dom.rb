# backtick_javascript: true
# frozen_string_literal: true

# 探针 B（Opal + DOM 桩）：问题 1 / 2 / 4 / 5 / 6 / 7 / 8 / 10
require "citrine"
require "citrine/dom"

TRACE = []

def tr(x)
  TRACE << x
end

def trace_reset
  TRACE.clear
end

def sec(t)
  puts "\n=== #{t} ==="
end

def obs(l, v)
  puts "  #{l}: #{v}"
end

def app
  `document.getElementById("app")`
end

def tree
  `dumpTree(#{app})`
end

# 每段探针前清空 #app（否则前面挂载的树会累积）
def remount(component)
  `(function(){ var a = document.getElementById("app"); a.children = []; a.textContent = ""; })()`
  Citrine::DomRenderer.mount_at("app", component)
end

# Native 包装器每次都是新对象，equal? 不可用于 DOM 身份比较 → 回到 JS ===
def same_node?(cls, idx, el)
  `byClass(#{app}, #{cls})[#{idx}] === #{el.to_n}`
end

def create_calls
  `$create_calls`
end

# backtick 返回的是裸 JS 对象，必须再包 Native 才能用 Ruby 语法调用 JS 方法
def nat(x)
  Native(x)
end

def q(cls)
  nat(`byClass(#{app}, #{cls})[0]`)
end

# ═══════════════════════════════════════════════════════════════
sec "问题 1：事件绑定矩阵（谁绑上了、谁被静默丢弃）"

class EvWidget < Citrine::Component
  state :text, default: ""

  def view
    box(on_click: :h_box_click, on_change: :h_box_change, on_enter: :h_box_enter,
        on_input: :h_box_input, on_blur: :h_box_blur, css_class: "container") do
      label(on_click: :h_label_click, on_change: :h_label_change, css_class: "lbl") { "L" }
      button(on_click: :h_btn_click, on_change: :h_btn_change, css_class: "btn") { "B" }
      text_input(value: signal(:text), placeholder: "ph", on_enter: :h_ti_enter,
                 on_change: :h_ti_change, on_input: :h_ti_input, on_click: :h_ti_click,
                 css_class: "ti")
      check_box(checked: true, on_change: :h_cb_change, on_click: :h_cb_click, css_class: "cb")
    end
  end

  def h_box_click(_e = nil); tr("box_click"); end
  def h_box_change(_e = nil); tr("box_change"); end
  def h_box_enter(_e = nil); tr("box_enter"); end
  def h_box_input(_e = nil); tr("box_input"); end
  def h_box_blur(_e = nil); tr("box_blur"); end
  def h_label_click(_e = nil); tr("label_click"); end
  def h_label_change(_e = nil); tr("label_change"); end
  def h_btn_click(_e = nil); tr("btn_click"); end
  def h_btn_change(_e = nil); tr("btn_change"); end
  def h_ti_enter(_e = nil); tr("ti_enter"); end
  def h_ti_change(_e = nil); tr("ti_change"); end
  def h_ti_input(_e = nil); tr("ti_input"); end
  def h_ti_click(_e = nil); tr("ti_click"); end
  def h_cb_change(v = nil); tr("cb_change(#{v})"); end
  def h_cb_click(_e = nil); tr("cb_click"); end
end

remount(EvWidget.new)
puts tree

box_el = q("container")
lbl_el = q("lbl")
btn_el = q("btn")
ti_el = q("ti")
cb_el = q("cb")

trace_reset
box_el.fire("click")
lbl_el.fire("click")
btn_el.fire("click")
ti_el.fire("click")
cb_el.fire("click")
puts "派发 5 个 click 后 TRACE = #{TRACE.inspect}"

trace_reset
cb_el[:checked] = false
cb_el.fire("change")
puts "check_box 派发 change 后 TRACE = #{TRACE.inspect}"

trace_reset
ti_el[:value] = "abc"
ti_el.fire("input")
puts "text_input 派发 input 后 TRACE = #{TRACE.inspect}（input 无 handler；value 信号被写入）"

trace_reset
ti_el.fire("keydown", { key: "Enter" })
puts "text_input keydown Enter 后 TRACE = #{TRACE.inspect}"

trace_reset
ti_el.fire("keydown", { key: "Escape" })
ti_el.fire("keydown", { key: "a" })
ti_el.fire("blur")
ti_el.fire("focus")
puts "text_input Escape / 普通键 / blur / focus 后 TRACE = #{TRACE.inspect}"

trace_reset
box_el.fire("change")
lbl_el.fire("change")
btn_el.fire("change")
puts "在 box/label/button 上派发 change 后 TRACE = #{TRACE.inspect}"

# ═══════════════════════════════════════════════════════════════
sec "问题 4：block 返回非 String（DOM 侧）"

class NonString < Citrine::Component
  state :n, default: 3

  def view
    box do
      label(css_class: "int") { 42 }
      label(css_class: "nil") { nil }
      label(css_class: "calc") { n * 2 }
      label(css_class: "ok") { "n=#{n}" }
    end
  end
end

remount(NonString.new)
puts tree
obs("label{42} textContent", q("int")[:textContent].inspect)
obs("label{42} 的子树/属性", "空 <p>，无任何 JS 报错（stderr 干净）")

# ═══════════════════════════════════════════════════════════════
sec "问题 5：批量更新（DOM 侧 createElement 计数）"

class BatchWidget < Citrine::Component
  state :a, default: 0
  state :b, default: 0
  state :c, default: 0

  def view
    box(css_class: "batch") do
      label(css_class: "sum") { "sum=#{a + b + c}" }
      box(css_class: "dynamic") do
        s = a + b + c # 这个块订阅了 a、b、c 三个信号
        5.times { |i| label { "#{i}:#{s}" } }
      end
    end
  end

  def hit
    self.a += 1
    self.b += 1
    self.c += 1
  end
end

bw = BatchWidget.new
remount(bw)
puts "初始 createElement 调用数 = #{create_calls}"
before = create_calls
bw.hit
puts "一次用户操作（handler 内改 a,b,c 三个信号）：createElement 增量 = #{create_calls - before}"
obs("dynamic 块子节点数（应 5）", nat(`byClass(#{app}, "dynamic")[0].children`).length)
obs("dynamic 块文本", `byClass(#{app}, "dynamic")[0].children.map(function(e){return e.textContent}).join(" | ")`)
obs("sum 文本", q("sum")[:textContent])
before = create_calls
bw.hit
bw.hit
puts "再连续两次 hit：createElement 增量 = #{create_calls - before}（每次 hit 仍是 3 轮 × 5 节点）"
obs("监听器绑定累计次数", `$listener_binds.length`)

# ═══════════════════════════════════════════════════════════════
sec "问题 6 + 2：列表行内局部状态（陷阱 vs 绕过）"

class RowTrap < Citrine::Component
  state :items, default: %w[alpha beta gamma]

  def view
    box(css_class: "trap") do
      items.each_with_index do |it, _i|
        box(css_class: "trap-row") do
          label(css_class: "trap-text") { it }
          # 反模式：每次渲染新建 Signal（重建后就是另一个对象）
          text_input(value: Citrine::Signal.new("#{it}-draft"), css_class: "trap-input")
        end
      end
    end
  end
end

tw = RowTrap.new
remount(tw)
inp_before = nat(`byClass(#{app}, "trap-input")[1]`)
obs("第 2 行 input 初始 value", inp_before.value.inspect)
inp_before[:value] = "我输入的内容"
inp_before.fire("input")
obs("用户输入后 value", inp_before[:value].inspect)
before_create = create_calls
tw.items = tw.items + ["delta"]
obs("add_item 后 createElement 增量", create_calls - before_create)
inp_after = nat(`byClass(#{app}, "trap-input")[1]`)
obs("第 2 行 input 是新对象?", !same_node?("trap-input", 1, inp_before))
obs("旧 input 已从树摘除(parentElement==null)", inp_before[:parentElement].nil?)
obs("新 input 的 value", inp_after[:value].inspect + "   ← 用户输入丢失")
obs("旧 input 仍保留的监听器", `eventsOf(#{inp_before.to_n})`)
obs("行 DOM 身份", "全部 3 行都是新元素（无 keyed 复用）")
before_create = create_calls
tw.items = tw.items + ["epsilon"]
obs("再加一项 createElement 增量", create_calls - before_create)

class RowGood < Citrine::Component
  state :items, default: %w[alpha beta gamma]

  # 绕过姿势：每行一个自己的 Signal，存在普通 Hash 里（不是 state 宏）
  def row_signal(i)
    @row_signals ||= {}
    @row_signals[i] ||= Citrine::Signal.new("")
  end

  def view
    box(css_class: "good") do
      items.each_with_index do |it, i|
        box(css_class: "good-row") do
          label(css_class: "good-text") { "#{it}: #{row_signal(i).get.inspect}" }
          text_input(value: row_signal(i), css_class: "good-input")
        end
      end
    end
  end
end

gw = RowGood.new
remount(gw)
ginp = nat(`byClass(#{app}, "good-input")[1]`)
obs("第 2 行 label 初始", `byClass(#{app}, "good-text")[1].textContent`.inspect)
ginp[:value] = "我输入的内容"
ginp.fire("input")
before_create = create_calls
obs("输入后（只 set 那一个行信号）createElement 增量", create_calls - before_create)
obs("同行 label 文本", `byClass(#{app}, "good-text")[1].textContent`)
obs("input 元素身份保持", same_node?("good-input", 1, ginp))
obs("input.value", ginp[:value].inspect + "   ← 未被框架覆盖")
before_create = create_calls
gw.row_signal(1).set("再改一次")
obs("再次 set 同一行信号 createElement 增量", create_calls - before_create)
obs("label / input 同步", "#{`byClass(#{app}, "good-text")[1].textContent`} / #{`byClass(#{app}, "good-input")[1].value`.inspect}")
before_create = create_calls
gw.items = gw.items + ["delta"]
obs("★ 改 items（重建列表）后：行元素全换新，但值从 per-row Signal 恢复 → input.value", `byClass(#{app}, "good-input")[1].value`.inspect)
obs("   createElement 增量", create_calls - before_create)

# ═══════════════════════════════════════════════════════════════
sec "问题 7：键盘/焦点 —— 框架外 backtick JS 绕过"

class KeySpike < Citrine::Component
  state :text, default: ""

  def view
    box(css_class: "spike") do
      t = text # 让 box 块本身订阅 text（这样 text 变化会重建其中的 input）
      node = text_input(value: signal(:text), css_class: "spike-input")
      el = node.dom
      el.addEventListener("blur", ->(_e) { tr("manual_blur") })
      el.addEventListener("keydown", ->(e) { tr("manual_keydown:#{`#{e}.key`}") })
      label(css_class: "spike-label") { "text=#{t}" }
    end
  end
end

ks = KeySpike.new
remount(ks)
puts tree
sinp = nat(`byClass(#{app}, "spike-input")[0]`)
trace_reset
sinp.fire("blur")
sinp.fire("keydown", { key: "Escape" })
obs("手动绑定的 blur / Escape 触发结果", TRACE.inspect)
obs("代价 1：需要拿到 node.dom（DSL 返回值）+ Opal Native/backtick", "上面 3 行代码里混入了 JS")
obs("代价 2：框架不知道自己绑了这些监听器", "renderer.rb#dispose 只处理 node.owned_effects")
before_create = create_calls
begin
  sinp[:value] = "y"
  sinp.fire("input") # 触发 box 块重跑（块内读了 text）
  obs("★ 输入触发重建", "未报错")
rescue StandardError => e
  obs("★ 输入触发重建 → 框架崩溃", "#{e.class}: #{e.message}")
  obs("（这不是探针的错，见 probe_c_crash.rb 的最小复现）", "崩溃点：Signal#set 遍历 @subs.dup 陈旧快照")
end
obs("重跑后 input 是否换对象（旧元素被销毁）", !same_node?("spike-input", 0, sinp))
obs("旧 input 已摘除", sinp[:parentElement].nil?)
obs("旧 input 上的 blur 监听器数量", `((#{sinp.to_n}._listeners.blur) || []).length`)
trace_reset
sinp.fire("blur") if `((#{sinp.to_n}._listeners.blur) || []).length` > 0
obs("手动 fire 已被摘除的旧元素的 blur", TRACE.inspect + "   ← 监听器 + 闭包仍存活（泄漏）")

# ═══════════════════════════════════════════════════════════════
sec "问题 8：定时器 / 外部资源 与 dispose"

class TimerWidget < Citrine::Component
  state :ticks, default: 0

  def view
    box(css_class: "timer") do
      label(css_class: "ticks") { "ticks=#{ticks}" }
      button(on_click: :start) { "start" }
    end
  end

  def start
    cb = -> { self.ticks = ticks + 1 }
    `window.setInterval(#{cb}, 100)`
  end
end

tw2 = TimerWidget.new
root = remount(tw2)
tbtn = nat(`byTag(#{app}, "button")[0]`)
tbtn.fire("click")
obs("点击 start 后注册的 interval 数", `$intervals.length`)
obs("clearInterval 被调用次数（框架内）", `$cleared.length`)
`$intervals[0].fn()`
`$intervals[0].fn()`
obs("手动 tick 两次后 label", q("ticks")[:textContent])
obs("组件可见的生命周期方法", "Component 实例方法: #{Citrine::Component.instance_methods(false).sort.inspect}")
obs("是否有 on_mount/on_unmount/effect/watch",
    %i[on_mount on_unmount unmount effect watch dispose].map { |m| [m, tw2.respond_to?(m)] }.to_h.inspect)

Citrine.renderer.send(:dispose, root)
obs("调用 renderer.send(:dispose, root) 后：DOM 是否清空", `walk(#{app}).length`)
trace_reset
`$intervals[0].fn()` # interval 仍在跑
obs("销毁后 interval 回调再执行一次", "ticks = #{tw2.ticks}（无人 clearInterval → 泄漏）")
obs("销毁后 signal 还在被写", tw2.ticks.positive? ? "是，且已无订阅者（静默）" : "否")
begin
  tw2.send(:signal, :ticks).set(999)
  obs("销毁后直接写信号", "无异常，无渲染（silent no-op）")
rescue StandardError => e
  obs("销毁后直接写信号", "#{e.class}: #{e.message}")
end

# ═══════════════════════════════════════════════════════════════
sec "问题 10：DOM 侧的静默失败 + 渲染期异常"

class SilentWidget < Citrine::Component
  state :n, default: 0

  def view
    box(css_class: "silent", style: { width: 18, height: 18, border_radius: 20, font_wieght: "600" }) do
      label(css_class: "s1", style: { font_size: 15 }) { "n=#{n}" }
      text_input(value: "字面量不是 Signal", on_input: :never_called, css_class: "s2")
      check_box(checked: signal(:n), on_change: :never_called2, css_class: "s3")
      button(on_click: :never_defined_method, css_class: "s4") { "boom" }
    end
  end
end

remount(SilentWidget.new)
puts tree
obs(%(style {width: 18} → el.style["width"]), nat(`byClass(#{app}, "silent")[0].style`)["width"].inspect + "  ← 赋给 CSSOM 的是字符串 \"18\"")
obs(%(style {font_wieght: "600"} → el.style["fontWieght"]), nat(`byClass(#{app}, "s1")[0].style`)["fontWieght"].inspect)
obs(%(style {font_size: 15} → el.style["fontSize"]), nat(`byClass(#{app}, "s1")[0].style`)["fontSize"].inspect)
obs("text_input(value: 字面量) 的 DOM value", q("s2")[:value].inspect + "  ← 字面量被丢弃（只接受 Signal）")
obs("check_box(checked: signal) 的 checked", q("s3")[:checked].to_s + "  ← Signal 对象恒真")
obs("拼错事件名的绑定情况", `eventsOf(byClass(#{app}, "s2")[0])` + " / " + `eventsOf(byClass(#{app}, "s3")[0])`)

begin
  `byClass(#{app}, "s4")[0].fire("click")`
  obs("点击 on_click: :never_defined_method", "抛出异常（见上一行 stderr）")
rescue StandardError => e
  obs("点击 on_click: :never_defined_method", "#{e.class}: #{e.message}")
end

class ExplodingView < Citrine::Component
  state :x, default: 1

  def view
    box(css_class: "boom") do
      label(css_class: "b1") { "x=#{x}" }
      raise ArgumentError, "view 中途爆炸（模拟拼错方法名）"
    end
  end
end

ew = ExplodingView.new
begin
  remount(ew)
  puts "  ExplodingView 挂载未报错？"
rescue StandardError => e
  puts "  挂载 ExplodingView → 抛出 #{e.class}: #{e.message}"
end
obs("异常后页面处于半渲染态", "剩余节点数 = #{(tree.strip.empty? ? 0 : `walk(#{app}).length`)}")
obs("树内容", tree.strip.split("\n").first(3).join(" / "))
# 半注册的 Effect 是否还在偷跑
trace_reset
begin
  ew.instance_eval { @x } # noop
  ew.send(:signal, :x).set(2)
  obs("挂载失败后 set 信号 x", "无异常（孤儿 Effect 仍订阅着？）")
rescue StandardError => e
  obs("挂载失败后 set 信号 x", "抛出 #{e.class}: #{e.message}  ← 孤儿 Effect 在 Signal#set 里再次爆炸")
end
