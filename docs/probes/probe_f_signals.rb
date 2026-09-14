# frozen_string_literal: true

# 探针 F（CRuby）：问题 6（动态信号）+ 问题 5 的补充（同一信号重复写 / 原地修改）
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "probe_helper"

Signal = Citrine::Signal # 注意：CRuby 顶层也有 ::Signal（信号处理），所以必须写全名

def sec(t)
  puts "\n=== #{t} ==="
end

sec "问题 6a：非 state 宏的动态信号（Hash + 直接实例化）能否参与依赖追踪"
runs = Hash.new(0)
cells = {}
cells[:a] = Signal.new("A0")
cells[:b] = Signal.new("B0")
effects = {}
cells.each do |k, s|
  effects[k] = Citrine::Effect.create do
    runs[k] += 1
    s.get
  end
end
puts "初始 runs = #{runs.inspect}"
cells[:b].set("B1")
puts "set cells[:b] = 'B1' → runs = #{runs.inspect}（只有 b 的 Effect 重跑 ✓）"
puts "Effect 个数 = #{effects.size}；Signal 完全能脱离 state 宏工作 ✓"

sec "问题 6b：Signal#set 的相等性短路 —— 原地修改不会被通知"
calls = 0
arr = Signal.new([])
Citrine::Effect.create do
  arr.get
  calls += 1
end
puts "初始 calls（含 Effect.create 的那次） = #{calls}"
arr.set(arr.get.push(1)) # 同一个数组对象 → == 为真 → 短路
puts "arr.set(arr.get.push(1)) → calls = #{calls}，数组内容 = #{arr.get.inspect}"
puts "  ↑ 内容变了但没人被通知（signal.rb:21 `return self if new_value == @value`）"
arr.set(arr.get + [2]) # 新对象
puts "arr.set(arr.get + [2]) → calls = #{calls}，内容 = #{arr.get.inspect}"

sec "问题 6c：同值写入短路（重复 set 不会重渲染）"
s2 = Signal.new(1)
n = 0
Citrine::Effect.create do
  s2.get
  n += 1
end
before = n
5.times { s2.set(1) }
puts "连续 5 次写同值 → Effect 重跑次数增量 = #{n - before}"
s2.set(2)
puts "写不同值 → 重跑次数增量 = #{n - before}"

sec "问题 6d：动态信号没有生命周期归属（谁销毁它？）"
# 组件里的 state 信号挂在该组件实例上（signals hash），随组件对象一起被 GC；
# 但直接 new 出来的 Signal 只被 Effect 的 @deps 与自己的 @subs 互相引用：
s3 = Signal.new(0)
e = Citrine::Effect.create { s3.get }
puts "Effect#dispose 会 unsubscribe，但 Signal 自己没有任何 dispose/owner 概念"
puts "Effect 可销毁 = #{e.respond_to?(:dispose)}；Signal 可销毁 = #{s3.respond_to?(:dispose)}"
puts "（浏览器侧的真实泄漏只有定时器/DOM 监听器；信号本身的引用环由 JS GC 处理）"

sec "问题 5 补充：一次 handler 里写同一信号多次 / 写多个信号"
class Multi < Citrine::Component
  state :a, default: 0
  state :b, default: 0

  def view
    box(css_class: "m") do
      s = a + b # 该块同时订阅 a 与 b
      3.times { label { "row:#{s}" } }
    end
  end

  def hit
    self.a = a + 1
    self.b = b + 1
  end
end

m = Multi.new
Probe.reset!
r = Probe::Recorder.new
r.mount_component(m, Probe::FakeEl.new(:root))
base = Probe.count(:create_dom)
m.hit
puts "改造 a、b 各一次 → createElement 增量 = #{Probe.count(:create_dom) - base}（3 个 label × 2 轮）"
base = Probe.count(:create_dom)
m.instance_eval do
  self.a = a + 1
  self.a = a + 1
  self.a = a + 1
end
puts "同一信号连写 3 次 → createElement 增量 = #{Probe.count(:create_dom) - base}（3 轮 × 3 节点）"

sec "问题 4 补充：block 同时返回 String 又建了子节点 → 文字被静默丢弃"
class TextAndChildren < Citrine::Component
  def view
    box do
      label(css_class: "both") do
        box { label { "inner" } }
        "尾巴文字"
      end
      label(css_class: "orphantext") { "control" }
    end
  end
end

r2 = Probe::Recorder.new
root2 = r2.mount_component(TextAndChildren.new, Probe::FakeEl.new(:root))
puts "set_text 收到的调用 = #{r2.text_log.inspect}（'尾巴文字' 不在其中）"
puts "StringRenderer 输出 = #{Citrine.render(TextAndChildren.new).inspect}"

sec "问题 9 补充：style 传非 Hash / 值形态异常"
class WeirdStyle < Citrine::Component
  def view
    box(style: "color:red") { label { "x" } }
  end
end
begin
  Citrine.render(WeirdStyle.new)
  puts 'style: "color:red" → 未报错（!）'
rescue StandardError => e
  puts "style: \"color:red\" → #{e.class}: #{e.message}"
end

class WeirdStyle2 < Citrine::Component
  def view
    box(style: { font_size: nil, color: :red, width: [1, 2] }) { label { "x" } }
  end
end
begin
  puts "style 值形态异常（nil / Symbol / Array）→ #{Citrine.render(WeirdStyle2.new).inspect}"
rescue StandardError => e
  puts "style 值形态异常 → #{e.class}: #{e.message}"
end

sec "问题 10 补充：DSL 层未知 prop vs 构造器层未知 prop"
class UnknownProp < Citrine::Component
  def view
    box(totally_unknown: 1, on_input: :x, aria_label: "y") { label { "x" } }
  end
end
begin
  puts "DSL: box(totally_unknown: 1, on_input: :x) → #{Citrine.render(UnknownProp.new).inspect}（无任何报错）"
rescue StandardError => e
  puts "DSL 未知 prop → #{e.class}: #{e.message}"
end
