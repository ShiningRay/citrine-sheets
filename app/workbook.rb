# frozen_string_literal: true

require "citrine"
require_relative "formula"
require_relative "evaluator"
require_relative "format"
require_relative "value"

module Sheets
  # 工作簿：单元格内容、公式依赖图、增量重算、撤销栈、面向 UI 的信号发布。
  #
  # ── 为什么不用 Citrine 的信号直接做依赖图？──────────────────────
  # 信号天然就是"依赖图 + 自动重算"，本可以让每个公式单元格持一个 computed。
  # 没有这样做，有三个具体原因：
  #   1. 循环引用：A1 引用 B1、B1 引用 A1 时，信号会在写入瞬间递归重算到爆栈；
  #      电子表格必须把循环引用当成**可显示的普通错误值**（#CIRC!）。
  #   2. v1 没有批量更新（FRICTION F3）：一条 20 格的依赖链会触发 20 轮渲染；
  #      表格的语义是"一次编辑 → 一次重算 → 一次刷新"。
  #   3. 依赖必须**静态**可得：IF 未走到的分支也要计入依赖，否则在 B1 写
  #      =IF(A1>0,C1,0) 时，把 C1 改成引用 B1 不会被告知形成了环。
  # 因此这里自建依赖图 + 拓扑排序，只把**结果**经信号发布给 UI。
  #
  # 每格两个信号（按更新频率拆分，直接决定渲染开销）：
  #   值信号   → 每次重算都发；订阅它的叶子只改文字，0 个 DOM 节点重建
  #   外观信号 → 仅选中/格式/错误态变化时发；订阅它的块会重建该格（1~2 个节点）
  # v1 没有 keyed 复用与 props 热更新，"更新频率"只能由信号边界表达。
  class Workbook
    DEFAULT_ROWS = 60
    DEFAULT_COLS = 26
    UNDO_LIMIT = 60

    attr_reader :rows, :cols

    def initialize(rows: DEFAULT_ROWS, cols: DEFAULT_COLS)
      @rows = rows
      @cols = cols
      @raw = {}         # [row, col] => 原始输入文本
      @ast = {}         # [row, col] => AST（公式格）
      @values = {}      # [row, col] => 计算值
      @deps = {}        # [row, col] => { 依赖的格 => true }
      @dependents = {}  # [row, col] => { 依赖它的格 => true }
      @chrome = {}      # [row, col] => { bold:, bg:, decimals: }
      @value_signals = {}
      @chrome_signals = {}
      @undo = []
      @redo = []
      @edit_seq = 0
      @last_recalc = empty_report
      @recalc_signal = Citrine::Signal.new(@last_recalc)
    end

    # ── 读取 ────────────────────────────────────────────────

    def raw(row, col)
      @raw[[row, col]]
    end

    def value(row, col)
      @values[[row, col]]
    end

    # 求值器（Evaluator）依赖的上下文接口
    alias cell_value value

    def in_bounds?(row, col)
      row.is_a?(Integer) && col.is_a?(Integer) &&
        row >= 0 && col >= 0 && row < @rows && col < @cols
    end

    def dependencies(row, col)
      (@deps[[row, col]] || {}).keys
    end

    def dependents(row, col)
      (@dependents[[row, col]] || {}).keys
    end

    def chrome(row, col)
      @chrome[[row, col]] || {}
    end

    def display(row, col)
      Format.display(value(row, col), chrome(row, col)[:decimals])
    end

    def error?(row, col)
      Coerce.error?(value(row, col))
    end

    def kind(row, col)
      v = value(row, col)
      return :blank if v.nil?
      return :error if Coerce.error?(v)
      return :number if v.is_a?(Numeric)
      return :bool if v.is_a?(TrueClass) || v.is_a?(FalseClass)

      :text
    end

    def filled_cells
      @raw.keys
    end

    def filled_count
      @raw.size
    end

    def formula_count
      @ast.size
    end

    def error_count
      @values.count { |_, v| Coerce.error?(v) }
    end

    def cyclic_count
      @values.count { |_, v| v.is_a?(ErrorValue) && v.code == "#CIRC!" }
    end

    def last_recalc
      @last_recalc
    end

    def recalc_signal
      @recalc_signal
    end

    def value_signal(row, col)
      @value_signals[[row, col]] ||= Citrine::Signal.new(snapshot(row, col))
    end

    def chrome_signal(row, col)
      @chrome_signals[[row, col]] ||= Citrine::Signal.new(chrome_state(row, col))
    end

    def signal_count
      @value_signals.size + @chrome_signals.size + 1
    end

    def snapshot(row, col)
      {
        row: row, col: col,
        display: display(row, col),
        value: value(row, col),
        kind: kind(row, col),
        error: error?(row, col)
      }
    end

    def chrome_state(row, col)
      style = chrome(row, col)
      {
        row: row, col: col,
        bold: style[:bold] ? true : false,
        bg: style[:bg],
        error: error?(row, col),
        kind: kind(row, col)
      }
    end

    # ── 编辑 ────────────────────────────────────────────────

    def set_raw(row, col, text, record: true)
      set_many([[row, col, text]], record: record)
    end

    # 批量写入（粘贴 / 撤销恢复 / 模板载入）：一次重算、一次发布
    def set_many(entries, record: true)
      normalized = []
      entries.each do |(row, col, text)|
        next unless in_bounds?(row, col)

        value = text.nil? ? nil : text.to_s
        value = nil if value == ""
        next if value == @raw[[row, col]]

        normalized << [row, col, value]
      end
      return empty_report if normalized.empty?

      push_undo if record
      normalized.each do |(row, col, value)|
        @raw[[row, col]] = value
        compile(row, col)
      end
      apply(normalized.map { |entry| [entry[0], entry[1]] })
    end

    def clear_range(r1, c1, r2, c2)
      entries = []
      chrome_keys = []
      (r1..r2).each do |row|
        (c1..c2).each do |col|
          entries << [row, col, nil] if @raw.key?([row, col])
          next unless @chrome.key?([row, col])

          @chrome.delete([row, col])
          chrome_keys << [row, col]
        end
      end
      return empty_report if entries.empty? && chrome_keys.empty?

      push_undo
      report = entries.empty? ? empty_report : set_many(entries, record: false)
      chrome_keys.each { |key| publish_chrome(key) }
      report
    end

    def set_chrome(keys, patch, record: true)
      return empty_report if keys.empty?

      push_undo if record
      keys.each do |(row, col)|
        next unless in_bounds?(row, col)

        @chrome[[row, col]] = chrome(row, col).merge(patch)
        publish_chrome([row, col])
      end
      empty_report
    end

    # 全量重算：范围要覆盖"曾有信号但已被清空"的格子，否则 UI 会留下陈旧值
    def recalculate_all
      affected = {}
      all_known_keys.each { |key| affected[key] = true }
      apply(affected.keys, affected: affected)
    end

    def all_known_keys
      keys = {}
      (@raw.keys + @ast.keys + @values.keys + @value_signals.keys).each { |key| keys[key] = true }
      keys.keys
    end

    # ── 撤销 / 重做 ─────────────────────────────────────────

    def undo_depth
      @undo.size
    end

    def redo_depth
      @redo.size
    end

    def undo
      return nil if @undo.empty?

      @redo << capture
      restore(@undo.pop)
      :undo
    end

    def redo
      return nil if @redo.empty?

      @undo << capture
      restore(@redo.pop)
      :redo
    end

    def capture
      { raw: @raw.dup, chrome: @chrome.dup }
    end

    def restore(snapshot)
      @raw = snapshot[:raw].dup
      @chrome = snapshot[:chrome].dup
      rebuild_graph
      recalculate_all
    end

    private

    def push_undo
      @undo << capture
      @undo.shift while @undo.size > UNDO_LIMIT
      @redo.clear
      @edit_seq += 1
    end

    def compile(row, col)
      key = [row, col]
      previous = @deps[key]
      previous&.each_key { |target| unlink(target, key) }

      if Formula.formula?(@raw[key])
        result = Formula.parse(Formula.body(@raw[key]))
        if result[0] == :ok
          @ast[key] = result[1]
          edges = {}
          Formula.references(result[1], max_row: @rows, max_col: @cols).each do |target|
            edges[target] = true
            link(target, key)
          end
          @deps[key] = edges
          return
        end

        @ast.delete(key)
        @deps[key] = {}
        return
      end

      @ast.delete(key)
      @deps[key] = {}
    end

    def link(target, source)
      (@dependents[target] ||= {})[source] = true
    end

    def unlink(target, source)
      edges = @dependents[target]
      return if edges.nil?

      edges.delete(source)
      @dependents.delete(target) if edges.empty?
    end

    def rebuild_graph
      @ast = {}
      @deps = {}
      @dependents = {}
      @values = {}
      @raw.each_key { |(row, col)| compile(row, col) }
    end

    def collect_affected(keys)
      affected = {}
      queue = keys.dup
      until queue.empty?
        key = queue.shift
        next if affected[key]

        affected[key] = true
        (@dependents[key] || {}).each_key { |dependent| queue << dependent }
      end
      affected
    end

    # 重算受影响子图（拓扑序）；Kahn 排序后仍未出队的节点即处于环中或环的下游
    def apply(keys, affected: nil)
      affected ||= collect_affected(keys)
      return empty_report if affected.empty?

      indegree = {}
      affected.each_key do |key|
        count = 0
        (@deps[key] || {}).each_key { |dep| count += 1 if affected[dep] }
        indegree[key] = count
      end

      queue = affected.keys.select { |key| indegree[key].zero? }
      order = []
      until queue.empty?
        key = queue.shift
        order << key
        (@dependents[key] || {}).each_key do |dependent|
          next unless affected[dependent]

          indegree[dependent] -= 1
          queue << dependent if indegree[dependent].zero?
        end
      end

      done = {}
      order.each { |key| done[key] = true }
      cyclic = affected.keys.reject { |key| done[key] }

      evaluator = Evaluator.new(self)
      changed = []
      order.each do |key|
        new_value = compute(key, evaluator)
        changed << key unless same_value?(@values[key], new_value)
        @values[key] = new_value
      end
      cyclic.each do |key|
        changed << key unless same_value?(@values[key], CIRC_ERR)
        @values[key] = CIRC_ERR
      end

      @last_recalc = {
        cells: changed,
        computed: order.size + cyclic.size,
        cyclic: cyclic.size,
        at: @edit_seq
      }
      publish(affected.keys)
      @recalc_signal.set(@last_recalc)
      @last_recalc
    end

    def compute(key, evaluator)
      return literal(key) unless Formula.formula?(@raw[key])

      ast = @ast[key]
      return PARSE_ERR if ast.nil?

      evaluator.evaluate(ast)
    end

    # 非公式单元格：数字 / 布尔 / 文本
    def literal(key)
      text = @raw[key]
      return nil if text.nil?

      stripped = text.strip
      return true if stripped.upcase == "TRUE"
      return false if stripped.upcase == "FALSE"
      return Coerce.to_number(stripped) if Coerce.numeric_string?(stripped)

      text
    end

    def same_value?(old, new)
      return true if old.nil? && new.nil?
      return false if old.nil? || new.nil?

      if old.is_a?(Numeric) && new.is_a?(Numeric)
        old.to_f == new.to_f
      else
        old == new
      end
    end

    def publish(keys)
      keys.each do |key|
        row, col = key
        value_signal(row, col).set(snapshot(row, col))
        chrome_signal(row, col).set(chrome_state(row, col))
      end
    end

    def publish_chrome(key)
      row, col = key
      chrome_signal(row, col).set(chrome_state(row, col))
      # 显示文本依赖小数位设置：改格式必须同时刷新值快照，否则单元格还显示旧文本
      value_signal(row, col).set(snapshot(row, col))
    end

    def empty_report
      { cells: [], computed: 0, cyclic: 0, at: @edit_seq }
    end
  end
end
