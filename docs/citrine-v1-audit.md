# Citrine v1 API 审计报告（实测版）

- 审计对象：`/Users/shiningray/projects/__playground__/rubyreact/citrine`（ruby 3.4.8 / Opal 1.8.3 / node v24.7.0 / Chrome headless）
- 审计方式：**只读**。所有探针写在 `/tmp/citrine_audit/`，`citrine/` 下未做任何修改
  （`git status --porcelain` 只看到 `examples/market/`、`test/market_test.rb` 两个**未跟踪**条目，
  它们是本会话期间**另一个 agent 正在写的真实应用**，与本次探针无关——恰好成了本报告最有力的交叉验证，见「附录 A」）。
- 证据分级：**【实测】**=有跑出来的输出；**【推理】**=无法在该环境观测，只有源码/浏览器语义推演。
- 复现入口：

| 探针 | 覆盖问题 | 运行方式 |
| --- | --- | --- |
| `probe_a_cruby.rb` → `out_a_cruby.txt` | 4 / 5 / 9(SSR) / 10(CRuby) | `ruby -I<repo>/lib probe_a_cruby.rb` |
| `probe_b_dom.rb` + `probe_b_stub.js` → `out_b.txt` | 1 / 2 / 4(DOM) / 5(DOM) / 6 / 7 / 8 / 10(DOM) | `opal -c -I<repo>/lib -I. -o probe_b_dom.js probe_b_dom.rb && node probe_b_stub.js` |
| `probe_c_crash.rb` → `out_c_crash.txt` | ★崩溃最小复现 | `ruby -I<repo>/lib probe_c_crash.rb` |
| `probe_f_signals.rb` → `out_f_signals.txt` | 6 / 4 补充 / 9 补充 / 10 补充 | `ruby -I<repo>/lib probe_f_signals.rb` |
| `browser/probe_d.rb` + `browser/measure.html` → `browser/out_measure.json` | 3 / 9(真实 CSSOM) / 2(真实焦点) / 7(真实崩溃) / TodoApp 真实观感 | `cd browser && opal -c -I<repo>/lib -I<repo>/examples -I. -o probe_d.js probe_d.rb` 后用 Chrome headless `--dump-dom` 打开 `measure.html` |
| `browser/probe_e.rb` + `browser/measure2.html` → `browser/out_measure2.json` | 同页两次 `mount_at` 的破坏性 | 同上，打开 `measure2.html` |

---

## ★ 0. 崩溃级缺陷（不在原 10 条里，但伤害最大，先放前面）

### 0.1 祖先块与后代订阅同一信号 → 首次交互就抛未捕获异常，DOM 被拆一半 【实测】

**【结论】** 不可行。这是一个真实的框架崩溃，不需要任何框架外手段就能触发，而且触发它的写法非常自然
（"输入框 / 列表项外面套一个读了该信号的容器"）。

**【证据】**
- 最小复现（纯 CRuby，与平台无关）：`probe_c_crash.rb`
  ```
  订阅顺序 = [a, b]；a 的 block 会 dispose b
  s.set(1) → NoMethodError: undefined method 'each' for nil
  ```
- DOM 桩复现（`probe_b_dom.rb` 问题 7 段）：在输入框里打字 → `★ 输入触发重建 → 框架崩溃: NoMethodError: undefined method 'each' for nil`
- **真实浏览器复现**（`browser/out_measure.json` → `Q7_crash`）：输入一个字符后
  ```json
  {"errors": ["Uncaught each: undefined method `each' for nil"],
   "input_is_same_node": false, "old_node_in_document": false,
   "echo_label": "echo=x", "new_input_value": "x"}
  ```
  即：每敲一个字符都抛一次未捕获异常，同时输入框被销毁重建（焦点与光标位置丢失）；页面"看起来"还能用，控制台里一直在报错。
  复现写法（`browser/probe_d.rb` 的 `CrashWidget`）：
  ```ruby
  box(css_class: "crashwrap") do
    t = q                             # ← 容器块订阅了 q
    text_input(value: signal(:q))     # ← 输入框把 q 写回去
    label { "echo=#{t}" }
  end
  ```

**【源码位置】**
- `signal.rb:25` `@subs.dup.each(&:run)`：通知时遍历的是**快照副本**；
- `signal.rb:74-78` `Effect#dispose` → `release_deps` 后把 `@deps` 置为 `nil`；
- `renderer.rb:66-75` `run_block` 先 `dispose(child)`（销毁子树，含子节点的 Effect），再执行 block。
  于是"先创建、先订阅"的祖先 Effect 在重跑时销毁了仍在 `@subs` 快照里的后代 Effect，快照随后对已销毁 Effect 调 `run`
  → `release_deps` 对 `nil` 调 `each` → `NoMethodError`。

**【建议改法】** 二选一（都很小）：
1. `Effect#dispose` 不要把 `@deps` 置为 `nil`，改成 `@deps = []`（`signal.rb:74-78`），
   并让 `Effect#run` 在 `@block.nil?` 时直接 `return`——这样陈旧快照里的 run 变成幂等空操作；
2. 或把 `Signal#set` 的遍历改成"每轮重新读 `@subs`，并在 run 前检查 `subs.include?(self)`"。
   另外建议给 `Signal#set` 加一个"通知中"状态，禁止在通知过程中 dispose 订阅者（或延后到本轮结束执行）。

### 0.2 同一页面调用两次官方入口 `DomRenderer.mount_at` → 先挂载的组件被清空 【实测】

**【结论】** 不可行（v1 事实上只支持"整页一个渲染根 + 一个 mount_at"）。

**【证据】** `browser/out_measure2.json`：
```json
"before":            {"app5": "<div class=\"mini\">…<p>a0</p><button>add</button>…", "app6": 同左}
"after_click_app5":  {"html": "<div class=\"mini\" style=\"display: flex;\"></div>",
                      "errors": ["Uncaught children: undefined method `children' for nil"],
                      "app6_html": "…完整（未被影响）"}
"after_click_app6":  {"html": "…<div class=\"mini-item\"><p>a0</p></div><div class=\"mini-item\"><p>x1</p></div>…"}
```
点第一个组件的按钮 → 抛 `undefined method 'children' for nil`，**该组件的整个子树被清空**（连按钮自己都没了，界面彻底死掉）；
点第二个（最后挂载的）组件则正常。

**【源码位置】** `dom.rb:16-19`：`mount_at` 每次都 `Citrine.renderer = new`（全局变量，最后挂载者胜出，
`renderer.rb:22-25` 的注释也承认了这个设计）；`renderer.rb:34-38` `mount` 用 `@parents.last.children << node`，
而被替换后的新渲染器 `@parents` 是空的 → `nil.children`。

**【建议改法】** 把"当前父节点"从全局渲染器状态改为**跟随 Node 树**（如 `Renderer#mount(node, parent)`，
父节点由调用链传递，`Component#emit` 从 `@current_parent` 取，而 `@current_parent` 保存在 `Component` 实例上），
并让 `mount_at` 复用/显式接受渲染器实例（`DomRenderer.mount_at(id, comp, renderer: r)`），
不要在入口处无条件重置全局状态。最低成本的临时补丁：`mount_at` 只在 `Citrine.renderer.nil?` 时新建，
并在 `mount` 里对 `@parents.last` 为 nil 的情况抛带解释的异常（而不是 `nil.children` 的裸 NoMethodError）。

---

## 1. 非按钮容器的事件绑定

**【结论】**
- **可行**：`on_click` 是**类型无关**的——`box(on_click:)`、`label(on_click:)`、`text_input(on_click:)`、`check_box(on_click:)` 都能绑上。
  （原假设"只有 button 能绑"不成立：`apply_props` 只看 `props[:on_click]`，不看节点类型。）
- **静默丢弃**（不报错、不生效、无警告）：
  `on_change` 只在 `check_box` 上生效；`on_enter` 只在 `text_input` 上生效；
  其余组合——`box/label/button` 上的 `on_change`/`on_enter`/`on_input`/`on_blur`/`on_focus`/`on_keydown`、
  `text_input` 上的 `on_change`/`on_input`、`check_box` 上的 `on_enter` ——**全部无声消失**。

**【证据】**
- `out_b.txt` 问题 1 的监听器矩阵（DOM 桩直接列出每个元素真实绑了什么）：
  ```
  <div class="container"> ev=[click]
    <p class="lbl">        ev=[click]
    <button class="btn">   ev=[click]
    <input class="ti">     ev=[click,input,keydown]
    <input class="cb">     ev=[click,change]
  ```
  注意：容器同时传了 `on_change:`/`on_enter:`/`on_input:`/`on_blur:`，绑定结果只有 `click`。
- 逐事件派发后 `TRACE`：5 个 click → `["box_click","label_click","btn_click","ti_click","cb_click"]`（都通了）；
  `box/label/button` 上派发 `change` → `[]`；`text_input` 上 `Escape`/普通键/`blur`/`focus` → `[]`。
- `check_box` 的 `change` → `["cb_change()"]`（注意回调参数是布尔值 `checked`，不是事件对象）。
- CRuby/SSR 侧同样静默：`out_a_cruby.txt` 中带 `on_input: :on_input_typo`、`on_click: :also_ignored` 的组件正常渲染，无任何警告。

**【源码位置】** `dom.rb:44-56`（`apply_props` 只处理 `:on_click`，对所有节点类型生效）、
`dom.rb:69-84`（`on_enter` 只在 `setup_text_input`，且只认 `ev[:key] == "Enter"`）、
`dom.rb:86-96`（`on_change` 只在 `setup_check_box`）；
`component.rb:96-116`（`box(**props, &block)` / `label(**props, &block)` 接受任意 kwargs 后原样透传，故错拼事件名不报错）。

**【建议改法】** 在 `Component#emit`（`component.rb:148-153`）或 `DomRenderer#apply_props` 之前加一层**按 widget 类型的事件白名单校验**：
```ruby
EVENTS = { box: %i[on_click], label: %i[on_click], button: %i[on_click],
           text_input: %i[on_click on_enter on_change on_input on_blur on_focus],
           check_box:  %i[on_click on_change] }
unknown = props.keys.grep(/^on_/) - EVENTS.fetch(type, [])
raise ArgumentError, "#{type} 不支持事件 #{unknown.join(', ')}" unless unknown.empty?
```
（若要兼容，就先 `warn` 再忽略；关键是**别静默**。顺带把 `on_input`/`on_blur`/`on_focus`/`on_keydown` 真正接上——
`dom.rb:75` 已经有 `input` 监听器了，暴露出来几乎零成本。）

---

## 2. 列表条目内的局部状态

**【结论】**
- **不可行**（默认写法）：父块一重建，行内任何局部状态必然丢失，且**输入内容与焦点一起丢**。
- **需绕过**（可行，但与 state 宏体验差距巨大）：把行状态提到"每行一个 `Citrine::Signal`"里，
  用普通 Hash memoize，然后**直接 `signal.set`**（不要 `self.items = ...`）——这样更新只改文字/值，
  **0 个元素重建**，DOM 身份保持、光标不丢。
- 陷阱：在行 block 里**每次渲染都 `Citrine::Signal.new`** 是无效的（下次重建换了对象，外部再也拿不到它），
  且不会有任何报错。

**【证据】**（`out_b.txt` 问题 6+2；真机见 `browser/out_measure.json`）
- 陷阱版（每行 `text_input(value: Citrine::Signal.new("…-draft"))`）：
  ```
  第 2 行 input 初始 value: "beta-draft"
  用户输入后 value: "我输入的内容"
  改 items 后 createElement 增量: 12
  第 2 行 input 是新对象?: true
  旧 input 已从树摘除(parentElement==null): true
  新 input 的 value: "beta-draft"   ← 用户输入丢失
  旧 input 仍保留的监听器: input      ← 而且旧监听器不会被清理
  行 DOM 身份: 全部 3 行都是新元素（无 keyed 复用）
  ```
- 绕过版（`@row_signals[i] ||= Citrine::Signal.new("")`）：
  ```
  输入后（只 set 那一个行信号）createElement 增量: 0
  同行 label 文本: beta: "我输入的内容"
  input 元素身份保持: true
  ★ 改 items（重建列表）后：行元素全换新，但值从 per-row Signal 恢复 → input.value: "再改一次"
  ```
  即：**值能保住，但 DOM 身份/焦点仍然丢**（重建时新 input 不会自动 focus）。
- **真实浏览器**（`Q2_before` / `Q2_after_add_item`）：
  ```json
  "Q2_before":          {"activeElement": "focus-input", "value": "我输入的内容"}
  "Q2_after_add_item":  {"input_is_same_node": false, "old_node_still_in_document": false,
                         "old_node_value": "我输入的内容", "new_node_value": "", "activeElement": "BODY"}
  ```
  → 添加一条待办后：输入框换对象、**内容清空、焦点掉到 body**（用户得重新点回输入框）。

**【源码位置】** `renderer.rb:66-75`（`run_block` 一律 `dispose` 全部子节点后重建，无 diff、无 key）、
`renderer.rb:77-83`（`dispose` 只处理 Effect + detach）、`dom.rb:74-76`（input 值由独立 Effect 从 Signal 同步）。

**【建议改法】** 短期把"每行一个 Signal"抬成官方姿势：给 `Component` 加
`dynamic_state(key) { |k| ... }`（内部就是 `@dynamic[key] ||= Signal.new(...)`）+ 文档明示"改它而不是改 `items`"；
中期按 Roadmap P0-1 做 keyed 复用（`box(key: item[:id])`），至少保证"列表重建时按 key 复用行 DOM 与行信号"，
并在重建后恢复 `document.activeElement` 与 `selectionStart`。

---

## 3. CSS 过渡 / 动画与块级重建

**【结论】**
- **实测**：块重建后同一位置的元素是**全新 DOM 节点**，因此
  1) **CSS 动画会从头重播**：不在重建范围内的对照元素已推进到 717ms，被重建的行仍是 0ms；
  2) **state 驱动的 `transition` 永远不会播放**：新节点一出生就是终值，`getAnimations()` 里 0 个 `CSSTransition`；
     而同一个节点上原地改 `style` 则有 1 个正在运行的过渡。
- 也就是说：**v1 里"状态变化 → 动画"这条路是断的**，能用的只有"进入动画"（新节点自带的动画跑一遍）。

**【证据】**（Chrome headless 真机，`browser/out_measure.json`）
```json
"Q3_transition_control_same_node": {"transitions": ["opacity@0ms"], "computed_opacity": "1"},
"Q3_after_rebuild_sync": {"trans_is_same_node": false, "new_trans_node_transitions": []},
"Q3b_before":             {"opacity": "1", "transitions": []},
"Q3b_after_toggle":       {"node_is_same": false, "old_in_document": false,
                           "new_opacity_computed": "0.2", "new_node_transitions": []},
"Q3_delayed":             {"static_anims": ["auditPulse@717ms"],
                           "rebuilt_row_anims": ["auditPulse@0ms"]}
```
- 对照实验设计：`.trans-state` 的 `opacity` 由 state 决定（`faded ? 0.2 : 1`），点"fade"按钮后
  新节点计算样式**立刻是 0.2**（跳变完成，没有任何过渡帧）；而用 JS 在**同一个** `.trans` 节点上改 `style.opacity` 时，
  `getAnimations()` 返回 1 个 `opacity` 过渡。
- 动画重播：`.anim-static` 位于不参与重建的兄弟块里，700ms 后 `currentTime=717ms`；被重建的行 `currentTime=0ms`。
- **【推理】**（无法在该环境直接观测的部分）：`animationstart` 计数在本环境恒为 0/1（headless 虚拟时钟下事件派发不可靠），
  所以"肉眼看到动画闪回起点"这一现象我只用 `currentTime` 佐证，不宣称观察到了重播事件的次数。

**【源码位置】** `renderer.rb:66-75`（`dispose` + 重建 ⇒ `create_dom` 新元素）、`dom.rb:31-33`（`createElement`）、
`dom.rb:48`（内联样式在每次 mount 时整份重新赋值）。

**【建议改法】** 在没有 diff/patch 之前，明确在图鉴里写"动画只能是 enter 动画"；中期给 `apply_props` 加上
"节点复用时的样式增量更新"（keyed 复用是前提）；再往后可提供 `Citrine.animate(node, from:, to:)`
之类的一次性 WAAPI 封装（`element.animate()`），它对新节点同样有效，能绕开"必须保留旧节点"的限制。

---

## 4. 数字 / 非字符串返回值

**【结论】**
- **不可行（静默空元素）**：`label { 42 }` / `label { nil }` / `label { items.size }` / `label { 3.14 }` / `label { :sym }` / `label { ["a"] }`
  **全部渲染成空的 `<p></p>`**，DOM 与 SSR 一致，**没有任何报错或警告**。这是最容易踩、最难查的一类坑
  （`label { items.size }` 是极自然写法）。
- 附带坑：block 里**既建子节点又返回字符串**时，字符串被静默丢弃。

**【证据】**
- `out_a_cruby.txt` 问题 4：`set_text 实际收到的调用序列: ["ok 3"]`，
  `label(42) -> text=nil`、`label(nil) -> text=nil`、`label(n*2) -> text=nil`；
  `<div style="display:flex"><p></p><p></p>…<p>ok 3</p></div>`。
- DOM 侧同（`out_b.txt`）：`label{42} textContent: ""`，stderr 干净。
- 子节点 + 返回值：`out_f_signals.txt` → `set_text 收到的调用 = ["inner", "control"]`（`"尾巴文字"` 不在其中），
  SSR 输出 `<p class="both"><div…><p>inner</p></div></p>`。

**【源码位置】** `renderer.rb:71`：`set_text(node, result) if result.is_a?(String) && node.children.empty?`。

**【建议改法】** 两处小改：
```ruby
# renderer.rb:71
text = result.nil? ? nil : result.to_s      # 显式 nil 才算"无文本"，其余一律 to_s
set_text(node, text) unless text.nil? || !node.children.empty?
```
并在 dev 模式下对"block 返回了值但既非 String 也未建子节点"（例如 Integer/Array/Hash/Symbol）`warn` 一次，
提示"用 `#{...}` 插值或 `.to_s`"。若担心 `nil` 语义，至少对 **Numeric / Symbol / Array** 报错或告警。

---

## 5. 批量更新（Roadmap P0-4 的证据）

**【结论】** **不可行 / 缺口确认**：v1 没有任何批处理，同步级联重跑，**一次用户操作 = N 轮渲染**，
且中间态会真实写进 DOM（闪烁/中间值可见）。这是 P0-4 缺口的量化证据。

**【证据】**
- DOM 桩（`out_b.txt` 问题 5）：一个块同时订阅 a、b、c，块内建 5 个节点。
  ```
  一次用户操作（handler 内改 a,b,c 三个信号）：createElement 增量 = 15   (= 3 轮 × 5 节点)
  再连续两次 hit：createElement 增量 = 30
  监听器绑定累计次数: 8
  ```
- CRuby（`out_a_cruby.txt` 问题 5）：
  ```
  handler 内连续改 a,b,c 三个信号：create_dom=0(该场景只改文字) label_sum=3 computed=3
  handler 内连续改同一个信号 a 三次：label_a=3 computed=3
  handler 改两个被同一 computed 依赖的信号：computed=2 label_render=2
    set_text 收到的中间值序列=["F0|L0", "F1|L0", "F1|L1"]   ← 中间态真的进了 DOM
  改造 a、b 各一次 → createElement 增量 = 6 (3 个 label × 2 轮)   [probe_f]
  同一信号连写 3 次 → createElement 增量 = 9 (3 轮 × 3 节点)      [probe_f]
  ```
- 顺带结论：`Signal#set` 对**相同值**短路（`signal.rb:22`），所以 `5.times { s.set(1) }` → 0 轮重跑（这个还不错）。

**【源码位置】** `signal.rb:20-27`（`set` 内同步 `@subs.dup.each(&:run)`，无事务/微任务合并）、
`renderer.rb:66-75`（每次重跑即整块销毁重建）。

**【建议改法】** 给 `Signal#set` 加"批次窗口"：写操作先标记脏信号，`Effect` 只入队一次，
在本轮同步调用栈退出后（或 `queueMicrotask`）统一 flush；
API 上暴露 `Citrine.batch { ... }` 供 handler 显式包裹（默认自动批处理时需注意测试里的同步断言）。

---

## 6. 动态信号（非 state 宏）

**【结论】** **可行**，而且是 **per-row/per-key 细粒度更新的唯一可行姿势**；但体验与 state 宏差距明显，
且有两个静默陷阱（原地修改无效、每次渲染新建等于没建）。

**【证据】**
- 依赖收集正常工作（`out_f_signals.txt` 问题 6）：
  ```
  初始 runs = {a: 1, b: 1}
  set cells[:b] = 'B1' → runs = {a: 1, b: 2}   ← 只有 b 的 Effect 重跑
  ```
- 陷阱 1（原地修改）：`arr.set(arr.get.push(1))` → 内容变了但**无人被通知**
  （`signal.rb:22` 用 `==` 判断，同一个数组对象 == 自己 → 短路）。必须写成 `arr.set(arr.get + [1])`。
- 陷阱 2（每次渲染新建）：见问题 2 的 `Signal.new` 陷阱实测（值总是回到初值，且没有任何报错）。
- 与 state 宏的体验差距：
  ```ruby
  # state 宏：声明式、可写作、可自增
  state :count, default: 0
  def inc = self.count += 1

  # 动态信号：必须手写 memo + 手动 set，且不能 `+=`（`s.get += 1` 是语法错误）
  def cell(i) = @cells ||= {}; @cells[i] ||= Citrine::Signal.new(0)   # 还得注意 i 的生命周期/清理
  def inc(i) = cell(i).set(cell(i).get + 1)
  ```
- 另一个真实摩擦：顶层 `Signal` 在 Opal corelib 与 CRuby 标准库里**都存在**（Ruby 的 `::Signal`），
  所以在组件内写裸 `Signal.new` 会拿到 corelib 的空类，**报错信息完全指向别处**
  （我自己的探针就踩了：`NoMethodError: undefined method 'get' for #<Signal:0x42>`，
  排查花了十几分钟）。必须写 `Citrine::Signal.new`。

**【源码位置】** `signal.rb:8-37`（Signal 本身与组件无关，可自由实例化）、
`component.rb:47-51` + `component.rb:87-92`（state 宏把信号锁在 `signals` Hash 里，键必须是**声明过的名字**）。

**【建议改法】** 加一个 `dynamic_state` 宏（或 `Component#signal_for(key, default)`）：
```ruby
def dynamic_state(key, default = nil)
  (@dynamic ||= {})[key] ||= Signal.new(default)
end
```
并在文档/图鉴里把"per-row 细粒度"写成官方推荐姿势；
另外在 `citrine.rb` 里 `Signal = Citrine::Signal` 的常量提示（或 `component.rb` 里
`def Signal` 之类的辅助）可以避免 corelib 同名类导致的误诊。

---

## 7. 键盘与焦点

**【结论】**
- 框架内**只能收到 `text_input` 的 Enter 键**（`keydown` + `key == "Enter"`）。`Escape`/`blur`/`focus`/`Tab`/普通键一律收不到；
  想在输入框里做"失焦提交"或"Esc 取消"，**框架内不可行**。
- 绕过可行但要付三重代价：① 需要拿 `node.dom`（DSL 返回值）+ Opal 原生互操作/反引号 JS；
  ② 框架**不知道**你绑了这些监听器，`dispose` 不会移除它们（旧节点被摘除后监听器与闭包仍然活着 = 泄漏）；
  ③ 一旦这些监听器触发了所在块的重建，就又踩上 ★0.1 的崩溃。

**【证据】**（`out_b.txt` 问题 7）
```ruby
node = text_input(value: signal(:text), css_class: "spike-input")
el = node.dom
el.addEventListener("blur", ->(_e) { tr("manual_blur") })
el.addEventListener("keydown", ->(e) { tr("manual_keydown:#{`#{e}.key`}") })
```
```
手动绑定的 blur / Escape 触发结果: ["manual_blur", "manual_keydown:Escape"]   ← 能绑、能用
★ 输入触发重建 → 框架崩溃: NoMethodError: undefined method `each' for nil      ← 代价 ③
重跑后 input 是否换对象（旧元素被销毁）: true
旧 input 上 blur 监听器数量: 1
手动 fire 已被摘除的旧元素的 blur: ["manual_blur"]   ← 监听器 + 闭包仍存活（代价 ②）
```
（`renderer.rb:77-83` 的 `dispose` 只清 `node.owned_effects` 并 `detach`，**不碰事件监听器**。）

**【源码位置】** `dom.rb:77-84`（只有 Enter）、`dom.rb:69-84`（`setup_text_input` 是唯一处理键盘的地方）、
`renderer.rb:77-83`（cleanup 范围）。

**【建议改法】** 把 `on_enter` 泛化为 `on_key:`（带 `key:`/`keys:` 过滤，如 `on_key: { escape: :cancel, enter: :submit }`）
并新增 `on_blur:` / `on_focus:`——`dom.rb` 里已有 `addEventListener("input")` 的基础设施，实现量很小；
同时在 `dispose` 里记录并移除框架自己绑的监听器（`node.owned_listeners`），
让"框架绑的"与"用户自己绑的"至少前者能自动清理。

---

## 8. watch / unmount 语义与定时器

**【结论】** **不可行**：框架**没有任何挂载/卸载钩子**，`Dispose` 也不清理定时器、事件监听器、
也不通知用户代码。用 `window.setInterval` 驱动 tick 时，**谁都不负责 clearInterval**。
`Renderer#dispose` 是 private，组件侧无法感知自己被销毁。

**【证据】**（`out_b.txt` 问题 8）
```
点击 start 后注册的 interval 数: 1
clearInterval 被调用次数（框架内）: 0
组件实例方法: ["box","button","check_box","computation","computations","emit",
              "handle_event","initialize","label","props","signal","signals","text_input","view"]
是否有 on_mount/on_unmount/effect/watch: {on_mount:false, on_unmount:false, unmount:false,
                                           effect:false, watch:false, dispose:false}
调用 renderer.send(:dispose, root) 后：DOM 是否清空: 1      ← DOM 清干净了
销毁后 interval 回调再执行一次: ticks = 3（无人 clearInterval → 泄漏）
销毁后直接写信号: 无异常，无渲染（silent no-op）            ← 对外完全静默
```
- `dispose` 的实际行为（`renderer.rb:77-83`）：逐个 `Effect#dispose` + 递归 detach。
  信号本身、定时器、DOM 监听器、用户 code 的 `@` 变量都不会被处理。

**【源码位置】** `renderer.rb:77-83`（dispose 的全部作用）、`component.rb` 里没有 `on_mount`/`on_unmount`/`effect`/`watch`
（`computed` 是唯一内部用 `Effect` 的地方，`component.rb:136-146`）。

**【建议改法】** 按 Roadmap P0-2 实现，但建议**先只做最小可用版**：
`Component#on_mount(&)` / `#on_unmount(&)`（在 `mount_component` 与 `dispose` 里回调），
并把 `Renderer#dispose` 提升为公开的 `Citrine.unmount(root)`；
同时提供 `Component#interval(ms) { }` / `#listen(target, event) { }` 这类"会被自动清理的资源注册器"，
否则每个用户都会各自重写一遍（真实项目里已经这样了，见附录 A）。

---

## 9. 样式边界

**【结论】**
- 支持的键值形态（`Style.normalize`）：键接受 `snake_case` / `camelCase` / `String`；值里的 `Symbol` 会转成连字符字符串
  （`text_decoration: :line_through` → `"line-through"`）。**不支持的**：`nil` 值（照样输出 `font-size:`，是非法 CSS）、
  数组/嵌套 Hash（原样输出）、`"font-size"`（kebab 键**不会**被反向归一，`camel()` 产出 `"font-size"` 这个非法属性名）。
- **数字值是一个静默陷阱**：没有任何单位推断（除 `box` 的 `gap`）。
  - DOM：`el.style.width = "18"` → **CSSOM 直接丢弃该声明**（实测真机 inline 样式里只剩 `font-weight:600`）；
  - StringRenderer：输出 `width:18`（非法 CSS 文本）。
- **真实影响（实测）**：仓库自带 TodoApp 的 `CARD`（`examples/components.rb:44` 起）用了 `border_radius: 20`，
  `.rv-item` 用了 `border_radius: 12`、`.rv-check` 用了 `width: 18`，**真机上全部失效**。
- 伪类/媒体查询/关键帧必须写页面 CSS：**API 上没有任何提示**（只有 `css_class` 这一个逃生口，且是纯字符串）。

**【证据】**
- 形态表（`out_a_cruby.txt` 问题 9）：`{fontSize:"18px"}`→`{font_size:…}`✓；`{"font-size"=>"18px"}`→键保持 `"font-size"`，
  `camel()` 得 `"font-size"`（DOM 赋值无效）；`{width:18}`→值原样 18。
- SSR 输出：`style="width:18;height:18;border-radius:20;padding:4px;display:flex"`、`"font-size:15;line-height:1.5;font-wieght:600"`。
- 真机 CSSOM（`browser/out_measure.json`）：
  ```json
  "Q9_numeric_style": {
    "bad_inline": "font-weight: 600;",                        ← width/height/border-radius/font-size 全被丢弃
    "bad_computed": {"width":"28.4219px","height":"22px","borderRadius":"0px","fontSize":"16px","fontWeight":"600"},
    "ok_inline": "width: 180px; height: 18px; border-radius: 20px; font-size: 15px;",
    "ok_computed": {"width":"180px","height":"18px","borderRadius":"20px","fontSize":"15px"}}
  ```
- 真实 App（TodoApp，先加一条待办再量）：
  ```json
  "TodoApp": {"item_borderRadius": "0px",        ← border_radius: 12 被丢弃
              "check_width": "13px",             ← width: 18 被丢弃（浏览器默认 checkbox 宽）
              "card_borderRadius": "0px",        ← CARD 的 border_radius: 20 被丢弃
              "item_transition": "background, transform",   ← 字符串形态有效
              "card_inline": "…width: 480px; box-shadow: …; display: flex; …"}
  ```
  即：**官方 demo 的所有圆角与复选框尺寸在真实浏览器里全部不存在**。
- 补充（`out_f_signals.txt`）：`style: { font_size: nil }` → SSR `font-size:`；`style: { width: [1,2] }` → `width:[1, 2]`；
  `style: "color:red"`（非 Hash）→ `NoMethodError: undefined method 'each_with_object' for an instance of String`（这是唯一会报错的情况）。

**【源码位置】** `style.rb:13-19`（normalize 只做键的 underscore 与 Symbol→字符串）、
`style.rb:36-38`（`normalize_value` 无单位推断）、`renderer.rb:87-98`（只有 `gap` 做了 `#{gap}px`）、
`dom.rb:48`（`el[:style][Style.camel(key)] = value.to_s`，把 `18` 变成 `"18"` 交给 CSSOM）、
`string_renderer.rb:79-82`（kebab 后直接拼字符串）。

**【建议改法】** 在 `Style.normalize_value` 里加**按属性白名单的单位推断**（而不是全局给数字加 px）：
```ruby
UNITLESS = %i[flex flex_grow flex_shrink line_height z_index opacity order font_weight column_count].freeze
PIXEL    = /\A(width|height|top|left|right|bottom|margin|padding|gap|row_gap|column_gap|border.*width|font_size|border_radius|letter_spacing)/.freeze
def normalize_value(key, value)
  return value.to_s.tr("_", "-") if value.is_a?(Symbol)
  return "#{value}px" if value.is_a?(Numeric) && key.to_s.match?(PIXEL) && !UNITLESS.include?(key)
  return value.to_s if value.is_a?(Numeric)      # 无单位属性
  value
end
```
另外建议 `normalize` 对 `nil` 值直接剔除、对 `"font-size"` 这类 kebab 键做反向归一，
并在 dev 模式对"非白名单样式键"告警（`font_wieght` 这种拼写错误现在 SSR 会照打印、DOM 侧静默失效）。
最后：在文档里明确"伪类/媒体查询/关键帧用页面 CSS + `css_class`"，并可顺手支持 `box(html_id:, disabled:, aria: {}, data: {})`。

---

## 10. 错误可发现性（静默失败入口总表）

**【结论】** 可发现性整体很差，且"能报错的"与"静默的"边界非常不合理：
**构造器参数校验很严（未声明 prop / 类型不符都报错），DSL 参数则完全不校验**。下面是实测的静默失败入口清单。

| # | 写法 | 实际行为 | 级别 |
| --- | --- | --- | --- |
| 1 | `label { 42 }` / `{ nil }` / `{ items.size }` | 渲染空元素，无警告 | 【实测】 |
| 2 | 块内既建子节点又返回 String | 字符串被丢弃 | 【实测】 |
| 3 | 错拼事件名 `on_input:` / `on_enter:`（放错 widget） | 不绑、不报错 | 【实测】 |
| 4 | 任意额外属性 `id:` `disabled:` `title:` `data_role:` `aria_label:` | DOM 里完全没有：`{"id":"","disabled":false,"title":"","data_role":null,"aria_label":null}` | 【实测】(真机) |
| 5 | `style: { font_wieght: "600" }`（拼错键） | SSR 照样输出 `font-wieght:600`；DOM 静默失效 | 【实测】 |
| 6 | `style: { width: 18 }`（数字） | CSSOM 丢弃整条声明 | 【实测】(真机) |
| 7 | `style: { font_size: nil }` | SSR 输出 `font-size:`（非法）；DOM 丢弃 | 【实测】 |
| 8 | `text_input(value: "字面量")` | **DOM 里 value 为空**，SSR 里却输出 `value="字面量"` → 两端不一致 | 【实测】 |
| 9 | `check_box(checked: some_signal)` | `props[:checked] ? true : false` → **恒为 true**（Signal 对象真值） | 【实测】 |
| 10 | `box(direction: :roww)` | 任何非 `:column` 都当 row（实测输出 `style="display:flex;flex-direction:row"`，无警告） | 【实测】 |
| 11 | `Citrine.renderer` 未设置时调 DSL | `NoMethodError: undefined method 'children' for nil`（信息指向内部实现） | 【实测】 |
| 12 | 忘记 `self.`：`count = 99` | **完全静默无效**（Ruby 局部变量），`self.count += 1` 才有效 | 【实测】 |
| 13 | 未声明 state 的读/写 | 读报错（`ArgumentError: 未声明的 state: cont`）；但 `count = 99` 这种写静默 | 【实测】 |
| 14 | 错误的 handler（`on_click: "str"` / arity 不符） | 挂载时不报错，**点击时**才 `ArgumentError`；`on_click: :typo_method` → `NoMethodError` + 一大段 `@signals` 内部 dump | 【实测】 |
| 15 | view 中抛异常 | 页面留在**半渲染**状态（`剩余节点数 = 3`，`<div class="boom"><p>x=1</p>`），无 error boundary、无回滚 | 【实测】 |
| 16 | 同一页两次 `mount_at` | 见 ★0.2 | 【实测】(真机) |
| 17 | 祖先/后代订阅同一信号 | 见 ★0.1 | 【实测】(真机) |
| 18 | 非 Hash 的 `style:` | `NoMethodError: each_with_object for String`（少见的会报错项，但信息不指向调用点） | 【实测】 |
| 19 | `Signal.new` 在组件内（corelib 同名类） | 拿到 `::Signal`，后续 `NoMethodError: undefined method 'get'` | 【实测】 |
| 20 | `Signal#set` 原地修改（`s.set(s.get.push(1))`） | `==` 短路，不通知 | 【实测】 |

**【源码位置】** 校验严的地方：`component.rb:62-76`（未声明 prop / 类型）、`component.rb:87-92`、`component.rb:136-139`；
不校验的地方：`component.rb:96-116`（DSL 关键字参数原样透传）、`component.rb:148-153`（`emit` 不做白名单）、
`dom.rb:44-56`（只认 4 个 prop）、`string_renderer.rb:58-77`（只认 4 个属性）。

**【建议改法】** 一次性做三件事（都在 `Component#emit` 一个点上）：
1. **prop 白名单校验**（按 widget 类型），未知键在 dev 抛 `ArgumentError`（列出合法键），生产 `warn`；
2. 新增透传属性 API：`html_id:` / `disabled:` / `name:` / `aria: {}` / `data: {}`（映射到 DOM 与 SSR 两端），
   至少让"我明明写了却没生效"这一类彻底消失；
3. block 返回值非 String 时告警（见问题 4），并在 `mount` 里对内部不变量（`@parents.last.nil?` 等）抛出可读异常。

---

## 附录 A：与仓库内并发真实应用的交叉验证（非本人改动）

本会话期间，`examples/market/`（另一个 agent 在写的真实行情终端）出现在工作区（`git status` 显示未跟踪）。
它自发地把上面多条缺口写成了"视图层纪律"和浏览器外挂层，**独立印证了本报告的实测结论**：

| market 里的做法 / 注释 | 对应本报告 |
| --- | --- |
| `browser_glue.rb:4-10`「citrine v1 没有定时器、全局键盘事件、挂载/卸载钩子…这些都是 FRICTION.md 里记的框架缺口，不是推荐姿势」 | 问题 7 / 8 |
| `browser_glue.rb:47,52` 自建 `window.setInterval` + `clearInterval`；`market.rb:21-22`「框架无 on_unmount，只能自己挂 `beforeunload`」 | 问题 8 |
| `browser_glue.rb:101` 自建 `window.addEventListener("keydown")` 做快捷键 | 问题 7 |
| `views/common.rb:6-7` 纪律 1/2：「容器块的 block 不读任何信号」「会变的数字放在最内层小块里读 → 0 个元素重建」 | 问题 5 / 3（我的计数器给出了"3 个信号 → 3 轮 × 5 节点 = 15 次 createElement"） |
| `views/common.rb:9-10` 纪律 3：「颜色是 props，props 只在挂载时应用」＋「祖先与后代订阅同一信号会触发框架崩溃（FRICTION.md #2）」 | 问题 1/9（props 非响应式）+ ★0.1（我给出了最小复现、真机复现与源码定位） |
| `views/chart.rb:10`「渲染器之间不能混合（FRICTION.md #6）」 | ★0.2（我把根因定位到 `Citrine.renderer` 全局替换 + `renderer.rb:37` 的 `@parents.last`） |
| `engine.rb:167,172`、`account.rb:51-54` 全部手写 `Citrine::Signal.new` + Hash memo（`@quote_signals[code] \|\|= …`） | 问题 6（per-row/per-key 唯一的细粒度姿势） |
| market 全目录**没有一处数字样式值**（`grep -rnE '[a-z_]+: [0-9]+,?$'` 只命中 `state :speed, default: 1` 这类默认值，样式全部写成 `"12px"`） | 问题 9 的坑被作者用经验绕开了，但 TodoApp 没绕开（实测失效） |

## 附录 B：本次未验证 / 存疑的部分（诚实声明）

1. **`animationstart` 事件计数**在 headless 虚拟时钟下不可靠（恒 0/1），所以"动画重播"我只有 `currentTime 717ms vs 0ms` 与"元素换新"两条证据，
   没有直接观测到重播事件；真机上人眼可见的动画闪回属于【推理】。
2. **键盘事件的真实浏览器行为**（Enter/Escape/blur）我只在 DOM 桩里做过派发（`out_b.txt`），
   未在真实浏览器里用合成事件验证；不过 `dom.rb:77-84` 的源码只有 Enter 一条分支，结论的置信度很高。
3. **内存泄漏的规模**没有量化（没有做 heap snapshot）：我只能证明"旧节点仍持有监听器与闭包"（`旧 input 上 blur 监听器数量: 1`）。
4. 未覆盖：CanvasRenderer、`dev_server`、`packager`、SSR 的事件序列化（后两者不在本任务 10 条内）。
5. 我的探针在**同一页面挂了多个组件**：其中 `probe_d.rb` 里 `app5/app6` 用的是两次 `mount_at`（用来演示 ★0.2），
   因此 `measure.html` 的其它测量统一改用一个共享渲染器实例，避免被 ★0.2 污染。
