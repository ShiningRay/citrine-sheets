# frozen_string_literal: true

# 原生端口测试（纯 CRuby，无窗口）：
#
#   rake native:test
#
# 覆盖两层：
#   · 绘制：自绘网格"画了什么"——断言用**框架自带的** Citrine::Native::Painter::Recording
#     （设计文档 2.2 的录制实现，不是本仓库另写的替身）
#   · 事件：点击/方向键/打字/提交/取消/撤销 → Application 的选区、编辑、重算、撤销栈
# 第三层（与框架 area 能力的控件级对接）见 native_area_contract_test.rb。
require "minitest/autorun"
require_relative "../app"

module NativeTestHelper
  # 未挂载的应用：绘制与事件逻辑都在数据层，不需要控件树（无窗口硬要求）
  def build_app
    app = Sheets::Native::NativeApp.new
    Sheets::Seed.load!(app.workbook)
    app
  end

  def build_grid(app = build_app)
    [app, Sheets::Native::Views::Grid.new(app: app)]
  end

  # 键盘一律走 window_key 的入口（原生侧的唯一键盘通道）
  def press(app, key, **modifiers)
    app.global_key(Citrine::KeyEvent.new(key, **modifiers))
  end

  # ── 录制器的断言辅助（Painter::Recording 的 calls 是 [[:rect, {...}], …]）──

  def recorder(width: 400, height: 300)
    Citrine::Native::Painter::Recording.new(width: width, height: height)
  end

  def texts(rec) = rec.calls_of(:text)
  def strings(rec) = texts(rec).map { |t| t[:text] }
  def text_for(rec, string) = texts(rec).find { |t| t[:text] == string.to_s }

  # 某条文本所属的 clip 块（记录序列的顺序就是绘制顺序：clip_begin … text … clip_end）
  def clip_of(rec, string)
    depth = 0
    current = nil
    rec.calls.each do |(type, args)|
      case type
      when :clip_begin
        current = args
        depth += 1
      when :clip_end
        depth -= 1
      when :text
        return current if depth.positive? && args[:text] == string.to_s
      end
    end
    nil
  end

  def rects(rec, fill: nil, stroke: nil)
    rec.calls_of(:rect).select do |rect|
      (fill.nil? || rect[:fill] == color(fill)) && (stroke.nil? || rect[:stroke] == color(stroke))
    end
  end

  # 颜色归一化直接用框架自己的实现（hex 字符串 → 0..1 浮点数组）：
  # 测试不重复写一份换算，也就不会与框架的颜色口径漂移
  def color(value)
    probe = Citrine::Native::Painter::Recording.new
    probe.rect(0, 0, 1, 1, fill: value)
    probe.calls_of(:rect).first[:fill]
  end

  def theme = Sheets::Native::Theme
  def grid_class = Sheets::Native::Views::Grid
end
