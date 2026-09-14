# frozen_string_literal: true

# 探针 A：问题 4（非字符串返回值）、问题 9（样式边界，StringRenderer 侧）、
#          问题 10（静默失败入口，CRuby 侧）、问题 5（批量更新，computed 重算次数）
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "probe_helper"

def h(title)
  puts "\n=== #{title} ==="
end

# ─────────────────────────────────────────────────────────────
h "问题 4：block 返回值不是 String 时（Renderer#run_block 只认 String）"

class ReturnsWidget < Citrine::Component
  state :n, default: 3

  def view
    box do
      label { 42 }              # Integer
      label { nil }             # nil
      label { n * 2 }           # Integer（计算值）
      label { [1, 2].size }     # Integer
      label { 3.14 }            # Float
      label { :sym }            # Symbol
      label { ["a", "b"] }      # Array
      label { "ok #{n}" }       # String（对照）
    end
  end
end

r = Probe::Recorder.new
root = r.mount_component(ReturnsWidget.new, Probe::FakeEl.new(:root))
puts "set_text 实际收到的调用序列: #{r.text_log.inspect}"
labs = root.children.first.children
labels = %w[42 nil n*2 size 3.14 sym array string]
labs.each_with_index do |node, i|
  puts "  label(#{labels[i]}) -> text=#{node.text.inspect} dom.children=#{node.dom.children.size}"
end

puts "-- StringRenderer 侧同一组件 --"
puts Citrine.render(ReturnsWidget.new)

# ─────────────────────────────────────────────────────────────
h "问题 9：Style.normalize 支持的键值形态"

inputs = [
  { font_size: "18px" },
  { fontSize: "18px" },
  { "fontSize" => "18px" },
  { width: 18 },
  { width: 18.5 },
  { font_weight: :bold },
  { text_decoration: :line_through },
  { transform: :translate_x },
  { background_color: nil },
  { width: true },
  { :"font-size" => "18px" },
  { zIndex: 3 },
  { "--custom-var" => "red" },
  { width: "calc(100% - 20px)" }
]
inputs.each do |input|
  norm = Citrine::Style.normalize(input)
  puts format("  %-34s -> normalize %-30s camel=%-24s kebab=%s",
              input.inspect, norm.inspect,
              norm.keys.map { |k| Citrine::Style.camel(k) }.inspect,
              norm.keys.map { |k| Citrine::Style.kebab(k) }.inspect)
end

puts "\n-- normalize 值形态（Symbol / 数字 / 嵌套 Hash / 数组）--"
[{ border: { width: 1 } }, { grid_template_columns: ["1fr", "1fr"] }, { content: :none }].each do |i|
  puts "  #{i.inspect} -> #{Citrine::Style.normalize(i).inspect}"
end

class NumStyleWidget < Citrine::Component
  def view
    box(style: { width: 18, height: 18, border_radius: 20, padding: "4px" }) do
      label(style: { font_size: 15, line_height: 1.5, font_wieght: "600" }) { "x" }
    end
  end
end

puts "\n-- StringRenderer 产出（注意 width:18 / border-radius:20 / font-wieght）--"
puts Citrine.render(NumStyleWidget.new)

# ─────────────────────────────────────────────────────────────
h "问题 10：静默失败入口（CRuby 侧）"

class TypoWidget < Citrine::Component
  state :count, default: 0

  def view
    box do
      label(on_click: :nope, on_change: :nope, on_input: :nope,
            style: { font_wieght: "600" }) { "c=#{count}" }
      text_input(value: "字符串字面量", on_enter: :submit, on_input: :on_input_typo)
      check_box(checked: true, on_change: :toggled, on_click: :also_ignored)
    end
  end

  def nope; end
  def toggled; end
  def submit; end
end

puts "带错拼样式键 font_wieght / 多余事件名 on_input 仍正常渲染（无任何警告）："
puts Citrine.render(TypoWidget.new)
puts "→ 说明：CRuby/SSR 侧对未知 prop / 事件名 / 样式键 100% 静默。"

puts "\n-- 未声明 state 的读/写 --"
w = TypoWidget.new
begin
  w.signal(:cont) # 拼错 count
  puts "  signal(:cont) 未报错（异常！）"
rescue => e
  puts "  signal(:cont) -> #{e.class}: #{e.message}"
end
begin
  w.send(:computation, :doubl)
rescue => e
  puts "  computed(:doubl) -> #{e.class}: #{e.message}"
end
begin
  w.instance_eval { count = 99 } # 忘记 self.
  puts "  忘记 self. 的赋值 `count = 99` -> 无异常，signal=#{w.instance_eval { count }}（静默无效）"
rescue => e
  puts "  忘记 self. 的赋值 -> #{e.class}: #{e.message}"
end
begin
  w.instance_eval { self.count += 1 }
  puts "  self.count += 1 -> ok, count=#{w.instance_eval { count }}"
rescue => e
  puts "  self.count += 1 -> #{e.class}: #{e.message}"
end

puts "\n-- 未声明 prop --"
begin
  TypoWidget.new(cnt: 1)
rescue => e
  puts "  TypoWidget.new(cnt: 1) -> #{e.class}: #{e.message}"
end
begin
  TypoWidget.new(count: 1)
rescue => e
  puts "  TypoWidget.new(count: 1)（把 state 名当 prop 传）-> #{e.class}: #{e.message}"
end

puts "\n-- prop 类型校验 --"
class TypedWidget < Citrine::Component
  prop :title, type: String, default: "t"

  def view
    label { title }
  end
end
begin
  TypedWidget.new(title: 42)
rescue => e
  puts "  TypedWidget.new(title: 42) -> #{e.class}: #{e.message}"
end
begin
  TypedWidget.new(title: nil)
  puts "  TypedWidget.new(title: nil) -> 未报错（nil 绕过 type 校验）"
rescue => e
  puts "  TypedWidget.new(title: nil) -> #{e.class}: #{e.message}"
end

puts "\n-- 没有渲染器时调用 DSL --"
begin
  w.instance_eval { label { "x" } }
rescue => e
  puts "  renderer=nil 时 label {} -> #{e.class}: #{e.message}"
end

puts "\n-- 事件处理器类型任意（错误只在触发时才暴露）--"
class BadHandler < Citrine::Component
  def view
    button(on_click: "not a handler") { "go" }
    button(on_click: ->(a, b) { a }) { "two-arg proc" }
  end
end
puts "  编译/挂载阶段：无异常"
puts "  #{Citrine.render(BadHandler.new)}"
b = BadHandler.new
[:handle_event_call, :str].each do |_x|
  begin
    b.handle_event("not a handler")
  rescue => e
    puts "  handle_event(\"not a handler\") -> #{e.class}: #{e.message}"
  end
  begin
    b.handle_event(->(a, b) { a })
  rescue => e
    puts "  handle_event(->(a,b){}) -> #{e.class}: #{e.message}"
  end
end

# ─────────────────────────────────────────────────────────────
h "问题 5：批量更新 —— 一个 handler 改多个信号触发几轮"

Probe.reset!

class Cascading < Citrine::Component
  state :a, default: 0
  state :b, default: 0
  state :c, default: 0
  computed(:sum) { Probe.tick(:computed_run); a + b + c }

  def view
    box do
      label { Probe.tick(:label_a); "a=#{a}" }
      label { Probe.tick(:label_b); "b=#{b}" }
      label { Probe.tick(:label_sum); "sum=#{sum}" }
      box do
        label { Probe.tick(:label_c_only_block_entered_but_maybe_not_c); "b-and-c=#{b + c}" }
      end
    end
  end

  def bump_all_three
    self.a += 1
    self.b += 1
    self.c += 1
  end

  def bump_all_three_via_sum
    self.a += 1
    self.b += 1
    self.c += 1
  end
end

w = Cascading.new
# 清掉构造期间计数（state/computed 断言式读取）
Probe.reset!
r = Probe::Recorder.new
root = r.mount_component(w, Probe::FakeEl.new(:root))
puts "首次挂载（1 轮）：create_dom=#{Probe.count(:create_dom)} " \
     "label_a=#{Probe.count(:label_a)} label_b=#{Probe.count(:label_b)} " \
     "label_sum=#{Probe.count(:label_sum)} c-block=#{Probe.count(:label_c_only_block_entered_but_maybe_not_c)} " \
     "computed=#{Probe.count(:computed_run)}"
puts "  dom 节点数=#{root.children.first.dom.children.size}"

Probe.reset!
w.bump_all_three
puts "handler 内连续改 a,b,c 三个信号（1 次用户操作）："
puts "  create_dom=#{Probe.count(:create_dom)} label_a=#{Probe.count(:label_a)} " \
     "label_b=#{Probe.count(:label_b)} label_sum=#{Probe.count(:label_sum)} " \
     "computed=#{Probe.count(:computed_run)}"

Probe.reset!
w.instance_eval do
  self.a += 1
  self.a += 1   # 同信号写两次（不同值）
  self.a += 1
end
puts "handler 内连续改同一个信号 a 三次：create_dom=#{Probe.count(:create_dom)} " \
     "label_a=#{Probe.count(:label_a)} computed=#{Probe.count(:computed_run)}"

# 中间态可见性（级联 glitch）
class Glitch < Citrine::Component
  state :first, default: "F0"
  state :last, default: "L0"
  computed(:full) { Probe.tick(:computed_run); "#{first}|#{last}" }

  def view
    label { Probe.tick(:label_render); full }
  end

  def rename
    self.first = "F1"
    self.last = "L1"
  end
end

Probe.reset!
g = Glitch.new
gr = Probe::Recorder.new
gr.mount_component(g, Probe::FakeEl.new(:root))
Probe.reset!
g.rename
puts "handler 改两个被同一 computed 依赖的信号：computed=#{Probe.count(:computed_run)} " \
     "label_render=#{Probe.count(:label_render)}"
puts "  set_text 收到的中间值序列=#{gr.text_log.inspect}（可见中间态即级联重跑的证据）"

Probe.reset!
w2 = Cascading.new
r2 = Probe::Recorder.new
r2.mount_component(w2, Probe::FakeEl.new(:root))
before = Probe.count(:create_dom)
w2.bump_all_three
puts "同一次 handler 中 create_dom 增量=#{Probe.count(:create_dom) - before}（挂载时 #{before}）"
