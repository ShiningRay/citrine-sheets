# frozen_string_literal: true

# 探针 C：Effect 在信号通知过程中被销毁 → Signal#set 遍历陈旧快照 → 崩溃
# 平台无关（纯 CRuby）；这解释了 DOM 侧"输入框所在块订阅了该输入框自己的信号"时的崩溃
$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "probe_helper"

def sec(t)
  puts "\n=== #{t} ==="
end

sec "最小复现：订阅者 A 的 block 销毁了订阅者 B（A 在 B 之前订阅）"
s = Citrine::Signal.new(0)
log = []
b = nil
a = Citrine::Effect.create do
  s.get
  log << :a
  b.dispose if b
end
b = Citrine::Effect.create do
  s.get
  log << :b
end
puts "订阅顺序 = [a, b]；a 的 block 会 dispose b"
begin
  s.set(1)
  puts "s.set(1) 未报错，log=#{log.inspect}"
rescue StandardError => e
  puts "s.set(1) → #{e.class}: #{e.message}"
end
puts "崩溃前执行到 log=#{log.inspect}"

sec "变体：被销毁者在快照中位于最后一个（不进 release_deps 的坑）"
s2 = Citrine::Signal.new(0)
log2 = []
c2 = nil
c1 = Citrine::Effect.create do
  s2.get
  log2 << :c1
  c2.dispose if c2
end
c2 = Citrine::Effect.create do
  s2.get
  log2 << :c2
end
c3 = Citrine::Effect.create do
  s2.get
  log2 << :c3
end
begin
  s2.set(1)
  puts "s2.set(1) → log=#{log2.inspect}"
rescue StandardError => e
  puts "s2.set(1) → #{e.class}: #{e.message}"
end

sec "同一套机制在渲染器里的真实触发路径（MemoryRenderer）"
class SelfReading < Citrine::Component
  state :text, default: ""
  state :other, default: 0

  def view
    box do
      label { "text=#{text}" } # effect#1（先创建）
      box do
        t = text # 让这个 box 块订阅 text（先创建）
        label { "inner=#{t}" }
        label { "other=#{other}" } # 末位订阅者（相当于 input 的 value effect）
      end
    end
  end
end

w = SelfReading.new
root = Probe::Recorder.new.mount_component(w, Probe::FakeEl.new(:root))
begin
  w.text = "x"
  puts "w.text = 'x' → 正常，inner 块重建"
rescue StandardError => e
  puts "w.text = 'x' → #{e.class}: #{e.message}"
end
begin
  w.other = 1
  puts "w.other = 1 → 正常"
rescue StandardError => e
  puts "w.other = 1 → #{e.class}: #{e.message}"
end
