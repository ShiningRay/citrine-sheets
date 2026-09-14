# Citrine 摩擦记录 · 第二辑（电子表格方向）

> 记录时间：2026-09-14 ｜ 框架版本：Citrine **0.1.1** + main 上未发版的
> **P0-1 组件嵌套 / keyed 复用（PR #15）**——本辑的 F5/F6 因此已经落地，
> 落地点与迁移记录见 §9。
> 来源：本仓库（Citrine Sheets，迷你电子表格）实际开发过程中的踩坑。
> 第一辑见 [citrine-market-terminal/FRICTION.md](https://github.com/ShiningRay/citrine-market-terminal/blob/main/FRICTION.md)（行情终端，23 条）。
>
> **与第一辑的关系**：第一辑里 0.1.1 已修的 F1/F2/F16/F17/F19/F20 在本仓库得到**应用级验证**
> （见 G-1）；本辑记录的各条里，G-5 ~ G-8 是**新的 Opal 互操作陷阱**，
> G-2/G-3 是"块级重建 + 无批处理"在**依赖图型应用**上的连锁效应，
> G-10 与第一辑 F23 是同一个坑的**第二次踩中**，G-12/G-13 是这次
> "把绕法换回框架能力"的迁移中新踩到的两条。
> 每条都给「现象 → 证据 → 位置 → 建议改法」。

---

## 一、先记一笔：0.1.1 的修复在真实应用里成立

> **2026-09-14 后续（P0-1 落地后）**：本节描述的"六个平级挂载根共享一个普通 Ruby 对象"
> 当时是**没有组件嵌套（F5）时的推荐绕法**，现在已随 PR #15 换回单一挂载根的组件树——
> 六次 `mount_at` 与 HTML 里的六个空 div 都没了，见 §9。本节保留其历史结论：
> **0.1.1 的 F1/F2 修复本身仍然成立**（当时确实零异常），只是不再是推荐架构。

**G-1（正面验证）** 本应用有六个平级挂载根共享一个普通 Ruby 对象（`Application`），
并且检查器里存在"容器块与内层标签读同一信号"的写法——这两件事在 0.1.0 上分别会触发
第一辑的 F2（多根互相清空）与 F1（陈旧订阅快照崩溃）。0.1.1 上**零异常**：

- 六个根各自 `mount_at` 正常，跨根信号传播正确（`app/sheets.rb`）
- 祖先块 + 后代块订阅同一 `selection` / `value` 信号，无崩溃（`app/panels/inspector.rb`）

**当时的结论**：**"多根挂载 + 共享普通对象"是 v1 里做中等规模应用的可推荐架构**，
比第一辑那种"单类 + 混入模块"更清晰（状态外置、面板各自独立订阅）。
**现在的结论（F5/F6 落地后）**：可以直接写成组件树了——面板是 `Application` 的
子组件（`components` 宏 + 关键字渲染），布局骨架回到 Ruby，面板各自的视图态留在面板里；
`Application` 只留跨面板共享的东西（工作簿 / 选区 / 编辑缓冲 / 编辑报告），经 prop 下传。

---

## 二、依赖图型应用暴露的两个连锁问题（第一辑 F3/F4 的延伸）

### G-2. props 的**求值位置**决定订阅范围 → 隔离一个单元必须多包一层容器 ★

**【现象】** `box(css_class: cell_class(row, col)) do ... end` 里，`cell_class(...)` 的实参是在
**外层块的执行过程中**求值的；于是"谁调用 cell_class，谁的 Effect 就订阅了这一格的信号"。
把单元格直接建在行块里，行块就订阅了整行 26 格的信号——**改任意一格，整行 26 格全部重建**。

**【证据】**【实测】本仓库修复前后（同一编辑动作，Node 桩计数）：
- 修复前：新建 DOM **1903** 个（整行重建 × 多行）
- 修复后：新建 DOM **210** 个（其中 27 格闪烁占 54，其余是面板重绘）

**【位置】** `lib/citrine/renderer.rb` 的 `mount`（`apply_props` 只在挂载时执行一次）、
`lib/citrine/component.rb:96-116`（DSL 只接受**已求值**的 props）。

**【建议改法】** 二选一或都做：
1. 允许 props 传 **Proc**（`box(css_class: -> { ... }) do`），由渲染器在**该节点的 Effect 内**求值——
   这样订阅范围天然收敛到"这个节点"，不需要用户自己多包一层容器；
2. 或提供显式的"响应式属性"入口：`box(react_to: [signals]) { |v| ... }`。

无论哪种，**都建议在文档里把"props 在外层块求值 → 订阅范围会外扩一层"写成显式警告**：
这是块级重建模型里最反直觉、也最容易造成隐性性能悬崖的一处
（写起来完全看不出差别，只在性能上体现）。

### G-3. 无批量更新的连锁效应：一个订阅口径写错，重绘翻倍

**【现象】** 状态栏要显示选区的求和/均值。最初的写法是"逐个读取范围内每个单元格的值信号"
（依赖精确到格，看起来很优雅）。但一次编辑会写多个信号，**统计块被触发 N 次**。

**【证据】**【实测】一次编辑（改 B2，影响 33 格）：
- 逐个订阅版：统计块重跑 4 轮，多建 **84** 个节点
- 改为只订阅"重算信号"版：重跑 1 轮，节点降到 **21**
（中间态还进了 DOM，与第一辑 F3 的实测一致）

**【位置】** `lib/citrine/signal.rb:20-27`（`set` 同步级联，无事务/合并）。

**【建议改法】** 第一辑 F3 已给出 `Citrine.batch` / 脏标记 + microtask flush 的方案，
这里补充一条**应用侧经验**（可写进文档）：*在 v1 里，订阅口径要尽可能"粗"——
用"版本号/重算信号"这类粗粒度信号代替逐个值订阅*，否则重绘次数 = 信号写入次数。
框架修复前，这几乎是写出流畅应用的必备技巧。

---

## 三、Opal 互操作陷阱（CRuby 单测完全测不出；§7 给出分类与处置）

> 这四条都是本仓库在浏览器/桩上跑起来才暴露的，第一辑的 F12/F13（整数除法、负数取整）
> 属于同一类。**建议在 README「技术备忘」里汇总成一张"Opal 陷阱清单"**，
> 因为每一条的症状都不指向真正原因。

### G-4. `String#<<` 在 Opal 下不存在（**上游明文记录的设计选择**）

**【现象】** 词法分析器里写 `buffer << ch` 累积字符串，Opal 直接抛
`NotImplementedError: String#<< not supported. Mutable String methods are not supported in Opal.`
CRuby 下 48 项单测全绿。

**【证据】**【实测】`rake parity` 第一次运行即失败在此处；改为 `buffer = buffer + ch` 后两侧一致。

**【上游状态】** 这是 Opal **明文记录的设计选择**（不是待修的 bug）：
`docs/unsupported_features.md` §Mutable Strings 写着"所有字符串不可变，`#<<` / `#gsub!` 等不存在"，
理由是性能与运行时简化。**因此不值得提 PR、更不该 fork 去改**。

**【建议改法】** 把这条写进 Citrine 的"技术备忘"（我们踩了，别人也会踩）；
或提供 `Citrine::Buffer`（内部用数组 join）这类跨平台辅助。

### G-5. 反引号里插值 `Native` 包装对象 → 拿到的是包装器，不是底层 JS 对象

**【现象】** 想用反引号调 JS：
```ruby
el = @input.dom
`if (#{el} && #{el}.focus) { #{el}.focus(); }`
```
生成的是 `if (el && el.focus) { el.focus(); }`，但 `el` 是 Opal 的 `Native::Object` **包装器**，
`el.focus` 是 `undefined` → **静默不生效**（焦点调用完全没发生，且不报错）。

**【证据】**【实测】诊断输出 `has_focus=undefined`；改为 Ruby 侧方法调用 `el.focus` 后，
`document.activeElement` 立刻变为输入框（`Native::Object#method_missing` 会正确转发）。

**【建议改法】** 文档明示：**原生互操作优先用 Ruby 侧方法调用**（`obj.method`），
反引号只用于无法用方法调用表达的场景；并说明 `Native(...)` 包装与底层对象的区别。

### G-6. 从 JS 反调 Ruby 方法需要知道 Opal 的改名规则（**文档缺口，不是 Opal 的 bug**）

> **归因更正**：本条初稿写成"Opal 生成非法 JS"，是错的。非法 JS 出自我**手写**在反引号里的字符串
> `"#{app}.$focus_editor!()"`；而编译器对 `#{obj.focus_editor!}` 这样的**插值**会生成合法的
> `$focus_editor$excl()`。真正的问题是**文档缺口**：从 JS 反调 Ruby 时，没有任何地方说明改名规则。

**【现象】** 手写方法名时不知道要改名 → 生成的 JS 里出现 `$focus_editor!()` →
`SyntaxError: Unexpected token '!'`，**整个 bundle 加载失败**（页面白屏，且报错指向生成文件）。

**【证据】**【实测】桩一启动即 SyntaxError；把方法改名为无后缀的 `focus_editor` 后正常。
Opal 的改名规则：`!` → `$excl`、`?` → `$question`、`=` → `$eq`（见生成产物里的 `$focus_input$excl$9`）。

**【建议改法】** 文档补一张改名对照表，并推荐 `Opal.send(obj, 'focus_editor!')` 这类不依赖改名的调用方式。

### G-7. Ruby 局部变量/参数会遮蔽反引号里的 JS 全局

**【现象】**
```ruby
def initialize(app, window = nil)
  @host = window || Native(`window`)   # ← `window` 编译成 JS 标识符引用，
end                                     #    被同名 Ruby 参数遮蔽 → 传进来的是 nil
```
生成 `self.$Native(window)`，而函数作用域里的 `window` 是那个**参数**。
症状是"没反应"：后续 `addEventListener` 报 `method_missing`。

**【证据】**【实测】桩报 `name: 'addEventListener'`；把参数改名 `host` 后立即正常。

**【建议改法】** 文档明示：**不要用 JS 同名标识符（window / document / event / name…）
给 Ruby 变量命名**。可考虑 lint 提示。

---

## 四、其它（沿用第一辑编号的再次确认）

### G-8. `box` 默认 `flex-direction: row` —— 第二次踩中（对应第一辑 F23）

**【现象】** 网格滚动容器与检查器内容块漏写 `direction: :column`，真机上**网格塌成 35px 高**
（内容按行横排），而 **77 项 Node 桩断言全绿**——桩里没有布局引擎。
第一辑的行情终端踩的是"面板内部横排、图表塌成 2px"，成因完全相同。

**【证据】**【实测】真机 `getBoundingClientRect`：修复前 `.grid-scroll` 553×35；
修复后 563×460（内容 1380px，可滚动）。修复前 `document.querySelectorAll('.cell')` 仍返回 1560 个。

**【建议改法】** 重申第一辑 F23 的建议：`box` 默认 column，或未传 `direction` 时 dev 告警。
**两次踩中同一处，说明这不是"注意点"，而是默认值错了。**
另外强烈建议：**验收流程里加一次"真实浏览器量尺寸"**（headless Chrome + 3 行 JS 即可），
否则这一整类 bug 在小程序里是隐形的。

### G-9. 键盘事件只有 Enter（对应第一辑 F10）—— 本应用的编辑体验全靠外挂

**【现象】** 电子表格是**键盘优先**的应用：方向键导航、直接打字即编辑、Esc 取消、
Tab 提交并右移、⌘Z/⌘⇧Z、⌘B、⌘↑↓←→ 跳到边缘 —— 框架内**一个都做不到**，
只有 `text_input` 的 Enter 可用。本仓库用 `window.addEventListener("keydown")` 全部自建
（`app/glue.rb`）。

**【证据】**【实测】`app/glue.rb` 约 60 行键盘分派；框架侧只有
`lib/citrine/dom.rb` 的 `setup_text_input` 中一条 `ev[:key] == "Enter"` 分支。
**（2026-09-14 已落地：`window_key` + 元素级 `on_key`，本仓库的外挂层已删除，见 §8.2。）**

**【附带发现】** 合成事件时容易踩：Enter 的 keydown 必须**派发在 input 元素上**
（框架的监听器绑在元素上，发在 window 上不会触发 `on_enter`），
而真实浏览器里用户按键自然满足这一点。

**【建议改法】** 同第一辑 F10：`on_key:` / `on_blur:` / `on_focus:`；
另外建议给 `Component` 一个官方入口注册"全局键盘"（本仓库只能自己 `window.addEventListener`）。

### G-10. 无生命周期 / ref（对应第一辑 F7）

**【现象】** 本应用需要：定时器（清理闪烁标注）、原生 `focus()`/`blur()`（把焦点送进编辑框）、
`beforeunload` 清理。框架都不提供，只能由 `Application` 持有组件引用 + 外挂层自己接。

**【证据】**【实测】`app/glue.rb`（定时器 + 键盘 + 焦点）、`app/application.rb#attach_editor`。
**（2026-09-14 已落地：`on_mount`/`on_unmount` + `ref:`；`attach_editor` 这条"根组件反向持有
子组件引用"的链已删除——编辑态焦点改由公式栏自己订阅 `edit_mode`，见 §9.3。）**

**【建议改法】** 同第一辑 F7（`on_mount`/`on_unmount` + 资源注册器）。

### G-11. 跨平台数值工具被第二次重写（对应第一辑 F12/F13）

**【现象】** 本仓库又写了一遍 `app/num.rb`（`idiv` 用 `Integer#div`、`round_to` 先取绝对值），
理由与第一辑完全相同：Opal 的 `7 / 2 == 3.5`、`(-1.5).round == -1`。
两个 demo 各自维护一份同构代码，说明**这是框架该提供的东西**。

**【证据】**【实测】`rake parity` 两侧输出必须逐字节一致（本仓库 95 行）；
公式引擎里除法/取整无处不在（`=D2/B2`、`ROUND`、`INT`、百分比格式）。

**【上游状态】** 同样是**明文记录的设计选择**：`docs/unsupported_features.md` §Integer / Float difference
明确写"Opal 中整数与浮点同属 `Number`（JS number），所以 `1 / 4` 是 `0.25` 而非 `0`"；
相关 issue #748、#505 均以 completed 关闭。**改它等于推翻 Opal 的数值模型，不会被接受。**

**【建议改法】** 框架提供 `Citrine::Num`（或 `Citrine::Portable`）：
`idiv` / `round_to` / `integral?` / `finite?`，并在 README 置顶警告这些差异。

**【2026-09-14 已落地】** 框架已提供 `Citrine::Num`（`idiv` / `round_to` / `round` /
`integral?` / `finite?` / `percent`）+ `rake parity`（CRuby/Opal 逐字节比对，已接入 CI）。
本仓库已迁移：`app/num.rb` 从 40 行实现变成 13 行常量别名，其余调用点不动；
迁移后 `rake test` 48 项 203 断言全绿、`rake parity` **95 行逐字节一致**。

迁移过程本身抓到两个问题（都已修）：

1. **返回类型**：框架初版的 `round_to(x, 0)` 返回 Float，显示层会把 `2.0` 渲染成 `"2.0"`
   而旧实现（`to_f.round`）给 `"2"`——`rake parity` 立刻报出差异。框架改为与 MRI 对齐
   （`digits <= 0` → Integer，`digits > 0` → Float），并补了类型断言与样本行。
2. **上游 Opal 又一个真 bug**：`10 ** 0` 返回 `Rational(1/1)`（CRuby 是 `1`）——
   `opal/corelib/number.rb` 的 `Integer#**` 用 `other > 0` 判断"整数快路径"，
   把指数 0 归进了负指数（Rational）分支。原先靠 `10 ** -digits` 统一处理精度时，
   `round_to(x, 0)` 会算出 `-3/1` 这种形态。框架内部已绕开；上游修复另提 PR。

顺带记录一条**平台固有差异**（非 bug，上游 ruby/spec 至今 filter 着）：
Opal 下 `2.0.to_s` 是 `"2"`、CRuby 是 `"2.0"`——显示层要定长小数请用 `Kernel#format`。

### G-12. 跨平台参数校验缺口：Opal 不校验多余实参 → 声明被**静默截断** ★

**【现象】** 生命周期宏写成了"一次声明多个处理器"：
```ruby
on_mount :setup_view_state, :start_ticker   # 想注册两个
```
`Component.on_mount(handler = nil, &block)` 只收一个，于是**第二个被丢掉**：
视图态建立了，定时器**从来没启动**。症状是"闪烁标注亮了但永远不清"——
看起来像定时器或信号问题，实际是宏的实参被静默吞掉。

**【证据】**【实测】同一份代码两侧行为不同：
- CRuby：`ArgumentError: wrong number of arguments (given 2, expected 0..1)`（构造类时即失败，问题当场暴露）
- Opal：**不报错**，`T.mount_hooks.size == 1`（多余实参直接丢弃）

桩验收里表现为 1 项失败（`心跳后闪烁清空 期望 "0" 实际 "27"`）。

**【位置】** `lib/citrine/component.rb` 的 `on_mount` / `on_unmount`（`mount_hooks << (block || handler)`）；
根因是 Opal 对多余位置实参不抛 `ArgumentError`（CRuby 会）。

**【已修】✅ citrine PR #19**：采纳了"建议改法 1"——`on_mount` / `on_unmount` 改为可变参数
（`*handlers, &block`），一次声明多个成为正常写法，并新增统一的实参校验（没有任何处理器、
或处理器既非 Symbol 也非 Proc 时**在声明期 fail fast**，把"静默"挡在前面）。
本仓库已把两处合并写法拆回两个处理器（`on_mount :setup_view_state, :start_ticker`），
CRuby 单测 + Opal 桩两侧现在一致。框架 README 的「跨平台语义陷阱」新增第 10 条记录
这条 Opal 特性本身（"给固定 arity 的方法多传实参不报错、只是丢弃"，别指望多传会报错）。

顺带：**执行顺序 = 声明顺序**已写进框架文档（本仓库依赖"先建视图态订阅、再起 ticker"）。

### G-13. 嵌套块里的**外层局部变量**是陈旧快照（块级重建模型的固有语义）

**【现象】** 埋点面板把 `report = Sheets::Telemetry.report` 放在外层块，内层块只读
`app.mount_ms` 这个信号。挂载耗时回填后，内层块确实重跑了、显示出了真实的 `600 ms`，
**但同一行里的其它指标还是挂载时刻的旧值**——因为它们是外层块的局部变量，
只有外层块重跑才会重新求值。

**【证据】**【实测】真机上启动后面板显示 `608 ms / 5196 / 3543`（后两个是挂载总数），
把 `app.mount_ms` 挪到外层块读之后变成 `608 ms / 1 / 0`（回填这一次重跑的真实开销）。

**【位置】** `lib/citrine/renderer.rb#run_block`（内层块由外层块创建，
内层块重跑不会重新执行外层块的局部变量初始化）。

**【建议改法】** 文档里给一条明确纪律（这是 block 模型相对 hooks 的**唯一**新增心智负担）：
**"要让变化驱动某个块重跑，就必须在那个块里读信号；跨块共享的值要么是信号（`.get()`），
要么每次在外层重跑时重新计算。"** 另一条等价说法：内层块只能信任自己读出来的值。
本仓库的视图层纪律（§5）已经把这条写成了可执行的规则。

---

## 五、本仓库采用的架构姿势（可直接抄）

> **2026-09-14 更新（P0-1 组件嵌套 + keyed 复用落地后）**：下面第 1 条描述的
> "多根挂载 + 共享普通对象"已经不需要了——它是 F5 缺位时的绕法，现在换成**单一挂载根 +
> 组件树**；第 2 条的三层结构也已简化为两层（G-2 响应式属性）；键盘、定时器、焦点三处
> 外挂层在 0.1.1 就迁入框架入口（G-9 / G-10）。完整迁移记录见 §9。

1. **单一挂载根 + 组件树**：`Application` 是根组件（也是共享模型），六个面板是它的
   子组件（`components` 宏 + 关键字渲染）；布局骨架写在 `view` 里，不再散落在 HTML 与入口脚本。
   共享的东西（工作簿 / 选区 / 编辑缓冲 / 本轮变化格）经 prop `app:` 下传，
   动作经回调 Proc 回传；**面板自己的视图态留在面板里**（网格的选中/闪烁/行列高亮）。
2. **信号按更新频率分层**：每格三个信号——值（每次重算变）、外观（格式/错误态）、
   视图（选中/闪烁）——前两个分别由单元格的文本叶子与响应式属性订阅，
   视图信号由网格面板自己持有并发增量（改一格 = 1 次叶子重跑，0 个新建节点）。
   **收益（实测）**：改一个数新建 DOM **1** 个、重跑 91 次 Effect；点选一格的 DOM 新建数为 **0**。
3. **结构身份用 `key:` 标出来**：网格的行/列头/单元格（`"B3"` 这种地址）、检查器的依赖标签。
   结构块重跑时按 key 复用，增删重排不换节点、不丢事件与焦点（F6 已落地）。
4. **"重算信号"作为粗粒度订阅口径**（见 G-3）。
5. **公式依赖图自建**，不直接用信号（原因写在 `app/workbook.rb` 顶部：
   循环引用要变成可显示的错误值、需要静态依赖、需要一次编辑一次发布）。

## 六、优先级建议（叠加第一辑后的顺序）

| 优先级 | 项 | 理由 |
|---|---|---|
| **P0** | 第一辑 F1/F2 | 已在 0.1.1 修复 ✅（本仓库验证通过） |
| **P0** | **G-2 props 求值位置**（或文档显式警告） | 一个字的差别带来 5~10 倍的渲染量，且完全不可见 → **已落地响应式属性** ✅ |
| **P0** | **G-8 `box` 默认方向** | 两次踩中、真机塌陷、桩测不可见；改默认值或 dev 告警 → **已落地 `stack`/`row` + dev 提醒** ✅ |
| **P1** | 第一辑 F3 批量更新 | G-3 证明它会连锁放大（订阅口径 → 重绘次数） |
| **P1** | **G-4 ~ G-7 四条 Opal 陷阱 + G-11 数值工具** | 每条都让排查成本远超修复成本，**文档就能立刻改善**（G-11 已由框架 `Citrine::Num` 落地，本仓库已迁移） |
| **P1** | 第一辑 F10 键盘 / F7 生命周期 / F9 埋点 | 键盘优先类应用的基本盘 → **F10/F7 已落地**（G-9/G-10）；F9 仍缺官方可观测性钩子 |
| **P1** | ~~**G-12 跨平台参数校验缺口**~~ ✅ 已修（citrine PR #19：生命周期宏改可变参数 + 声明期校验） | 静默截断，症状指向别处；修法极小（可变参数或显式 raise） |
| **P2** | **第一辑 F5/F6（组件嵌套 / keyed 复用）** | **已落地**（citrine PR #15）✅：本仓库的"多根 + 共享对象"绕法已删除，改成组件树 + keyed 复用，见 §9 |
| **P2** | **G-13 嵌套块的陈旧局部变量** | 块模型的固有语义，文档一条纪律即可消除 |

**一句话总结（第二辑）**：0.1.1 把"会崩"的问题解决了；这一辑暴露的三类新问题是
**① 响应式边界不可见**（props 求值位置、订阅口径 → G-2/G-3）、
**② 默认值/文档缺位**（box 方向、Opal 陷阱 → G-8/G-4~G-7）、
**③ 键盘与生命周期缺席**（G-9/G-10）。
其中 **①② 的修复成本都极低**（改默认值 / 补文档 / 允许 props 传 Proc），
却直接决定"能不能顺畅写出中等规模应用"。
**（2026-09-14 更新：① 已落地响应式属性、② 已落地布局语法糖、③ 已落地生命周期与键盘、
F5/F6 已落地组件嵌套与 keyed 复用——本仓库据此把三处绕法全部删掉了，见 §9。）**

---

## 七、专题：要不要 fork 一份 Opal 自己改？

> 2026-09-14 基于**实测**（本仓库 + 第一辑探针）与**上游仓库状态调研**（`gh api` 实时查询）。
> 结论：**不建议 fork**。理由与替代路径如下。

### 7.1 先把"Opal 的问题"分类——三类东西的处理方式完全不同

| 我们撞到的差异 | 性质 | 上游状态 | fork 能解决吗 | 处置 |
|---|---|---|---|---|
| `1 / 4 == 0.25`（整数除法返浮点） | **设计选择** | `docs/unsupported_features.md` §Integer / Float difference 明文记录；issue #748 / #505 已 closed | 能改，但会与 corelib 的 `Number`(= JS number) 模型全面冲突，且让 Citrine 行为与其它 Opal 用户不一致 | ❌ 不 fork，Citrine 侧 `Num.idiv` |
| `String#<<` / `#gsub!` 不存在 | **设计选择** | 同上 §Mutable Strings（"所有字符串不可变"） | 不能（corelib 全建立于不可变 JS 字符串） | ❌ 不 fork，文档 + 用 `+` |
| `Float#round` 负数半值方向（`-1.5.round` → `-1`，Ruby 是 `-2`） | **真 bug**：用 `Math.round`（朝 +∞）而**同一个方法里的整数分支**已经用"绝对值 + floor"（远离零），自相矛盾 | 提 PR 前未找到对应 issue（#572 是"`round(2)` 返回整数"那个老问题，已修）→ **已提 [opal/opal#2808](https://github.com/opal/opal/pull/2808)**（2026-09-14） | 能，**4 行** | ✅ **已提 PR**（附 mspec 用例；master 上 fail、补丁后 pass 均已实测） |
| 反引号里插值 `Native` 包装对象 / 方法改名规则 / 变量遮蔽 JS 全局 | 互操作语义 + **文档缺口** | 非 bug | 不能 | ✅ 提文档 PR（见 G-6 的归因更正） |

### 7.2 为什么 fork 的成本远高于收益

1. **上游很活跃**：`gh api repos/opal/opal` 实测——最近提交 **2026-09-11**（距记录日 3 天），
   PR 持续合入，4,927 stars / 150 open issues。fork 意味着长期 rebase 一个**活跃**仓库，
   正是 GOALS.md 风险清单里"上游漂移"被放大十倍。
2. **能靠 fork 修好的只有一条**（`Float#round`，4 行）；另两条是设计选择，
   fork 改了反而让 Citrine 的行为与整个 Opal 生态不一致——而 Citrine 的价值恰恰是"Ruby 写、生态借力"。
3. **采用税**：Citrine 还没发布 gem，若依赖 fork，所有使用者都要写
   `gem "opal", github: "..."`。第一辑的先行者教训里，"生态摩擦"正是 Hyperstack / Isomorfeus 的死因之一。
4. **真正的防线已经在做**：`rake parity`（两个 demo 都有）能在 CI 抓住
   "CRuby 单测全绿、浏览器里错"这类跨平台差异。**fork 只保护我们自己的代码，
   parity 检查 + 文档能保护所有使用者的代码。**

### 7.3 推荐的四层策略（成本从低到高）

| 层 | 做法 | 成本 | 何时做 |
|---|---|---|---|
| **L0** | Citrine 侧兜底：`Citrine::Num`、README 的"Opal 陷阱清单" | 低 | **现在** |
| **L1** | 给上游提 PR：① `Float#round` 修复（附 mspec）——**已提 [opal/opal#2808](https://github.com/opal/opal/pull/2808)**；② 把真实应用的陷阱补进 `docs/unsupported_features.md` | 中低 | 想提就提，**提了不亏**：合入即零维护 |
| **L2** | 个别修复未及时合入而我们又急需 → `gem "opal", github: "opal/opal"` **钉某个 commit**（比 fork 便宜一个数量级），或在 Citrine 内做**带版本守卫**的运行时补丁（上游修好后自动失效） | 中 | 真被阻塞时 |
| **L3** | 真 fork：fork + 极小 patch 系列 + 每晚 rebase 上游并跑 Citrine 全量测试的 CI + 发 `citrine-opal` gem | 高 | **仅在触发器命中时** |

**建议把 L3 的触发条件写死进 GOALS.md**（避免"情绪化 fork"），例如：

> 只有当"某个 P0 功能被 Opal **编译器层面**的 bug 阻塞（corelib 补丁救不了），
> 且上游 issue 4 周内无回应"时，才启动 fork 评估。

### 7.4 `Float#round` 的具体候选修复（可直接提 PR）

Opal 1.8.3 `opal/corelib/number.rb` 的 `Float#round` 分支用 `Math.round`（半值朝 +∞），
而同一方法的 `Integer#round(负 digits)` 分支用的是 `Math.floor(Math.abs(self) + f/2)` 再回贴符号（远离零）。
统一成后者的写法即可：

```ruby
# ndigits == 0 时
`var x = Math.floor(Math.abs(self) + 0.5); return self < 0 ? -x : x;`
# ndigits > 0 时
`var f = Math.pow(10, ndigits), x = Math.floor(Math.abs(self) * f + 0.5) / f; return self < 0 ? -x : x;`
```

**实测校验**（本机 node 与 CRuby 17 组对照，含 `-1.35.round(1)`、`±2.675.round(2)` 这类边界）：
提案实现 **17/17 与 Ruby 一致**，当前实现错 5 组。

**上游验证**（[opal/opal#2808](https://github.com/opal/opal/pull/2808)，2026-09-14）：新增
`spec/opal/core/number/round_spec.rb`，在 master 上 `4 examples, 2 failures`（`-0.5` 得 `-0.0`、
`-1.25.round(1)` 得 `-1.2`），补丁后 `4 examples, 0 failures`；上游既有
`spec/ruby/core/float/round_spec.rb`（11 例）、`integer/round_spec.rb`（10 例）无回归，
`rake mspec_opal_nodejs` 全量 697 例全绿。

**顺带发现**：ruby/spec 的 `Float#round` 对负数只测 `-1.4` / `-2.8`，**从不测恰好半值**——
这正是该 bug 能长期潜伏的原因，也说明"上游 spec 全绿"不等于"语义对齐 MRI"。

```
-1.5.round    Ruby -2    Opal -1    → 提案 -2
-2.5.round    Ruby -3    Opal -2    → 提案 -3
-0.5.round    Ruby -1    Opal  0    → 提案 -1
-1.25.round(1) Ruby -1.3 Opal -1.2  → 提案 -1.3
-2.675.round(2) Ruby -2.68 Opal -2.67 → 提案 -2.68
```

---

## 八、框架能力落地后的迁移记录（2026-09-14）

框架侧 G-2 / G-8 / G-9 / G-10 / G-11 陆续合并后，本仓库做了一次"把外挂层交还给框架"的迁移。
迁移不是把代码搬走就完事——**三个新能力各自简化了一处本仓库的绕法**，并删掉了 150 行的 `glue.rb`
（现在只剩 `test_api.rb`，一个给无头测试用的钩子）。

### 8.1 G-2：单元格三层 → 两层（且数据编辑零新建节点）

`css_class:` / `style:` 直接传 Proc 后，外观订阅落在**该格自己的属性 Effect** 上：

```ruby
box(
  css_class: -> { "cell #{cell_flags(row, col)}" },
  style:     -> { cell_style(row, col) },
  on_click:  -> { app.select_cell(row, col) }
) { label(css_class: "cell-text") { cell_text(row, col) } }
```

- **桩验收新增断言**：`数据编辑不新建任何单元格节点`（闪烁 27 格从前要新建 54 个中层节点，
  现在只重设 class/style）——旧的 `节点来源分解包含 cell-chrome` 断言随之删除
- **真机实测**：点击/方向键/打字即编辑/取消四步之后，1560 个 `.cell` 元素**仍是同一批对象**
  （`cells.every(c => c === 现取)`），单元格尺寸 84×22、滚动容器 563×460 不变

### 8.2 G-9：键盘从外挂层回到组件声明

- 全局键（方向键/Shift 扩展/⌘Z/⌘B/打字即编辑）→ `GridPanel` 的 `window_key :global_key`，
  逻辑仍归 `Application#handle_key`，但事件已经是框架归一化的 `Citrine::KeyEvent`
  （`ev.command?` / `ev.shift?` / `ev.prevent_default`），不再手工读原生字段
- 输入框内的 Esc / Tab → `FormulaBar` 的 `on_key: { "Escape" => …, "Tab" => … }`；
  外挂层里那段"判断 event.target 是不是 INPUT"的代码因此消失
- 卸载时 window 监听由框架解绑，`beforeunload` 清理随之删除

### 8.3 G-10：定时器与焦点

- 闪烁清理的 `setInterval` → `GridPanel` 的 `on_mount` / `on_unmount`（起停跟着组件走）
- 编辑框焦点 → `ref: :input` + `refs[:input]`，不再需要 "App 持组件引用 → 组件持 node → node.dom"
  这条链；也彻底告别了早期用反引号调 `focus()` 的写法（G-5 那个静默失效坑）
- 真机实测：提交编辑后 26 格进入闪烁态，一个 tick（110ms）后自动清零——定时器确实由生命周期驱动

### 8.4 迁移中踩到的**语言坑**（不是框架问题，但排查成本高，值得记一笔）

把 `handle_meta` 从外挂层搬进 `Application` 时，`when "z" then swallow(ev) { shift ? redo : undo }`
里的**裸 `redo` 是 Ruby 关键字**（重启当前块）而不是方法调用——编译产物变成一个自我重启的块，
运行到 ⌘Z 时 `Maximum call stack size exceeded`。加显式接收者（`self.redo`）即可。
桩验收当场报错定位，没有流到真机。

---

## 九、F5/F6 落地后的第二次迁移（2026-09-14，组件嵌套 + keyed 复用）

> 落地点：**citrine PR #15**（`feat: 组件嵌套 + keyed 复用（P0-1 / F5+F6）`，已进 main；
> 该版本尚未发 gem，能力说明见 `citrine-main` 的 GOALS.md 第十一节 P0-1 与
> `examples/keyed_list.rb`）。
> 本仓库是这两个缺口的**原始症状来源**（"六个平级挂载根"就是 F5 的绕法），
> 所以落地后第一件事是把绕法换回框架能力，并确认**行为不退化**。

### 9.1 面板从"混入 + 多挂载根"变成真正的子组件

- `Panels::Panel` 现在只声明 `prop :app`（共享模型经 prop 下传），
  `Application` 变成**根组件**：`class Application < Citrine::Component` +
  `components Panels::Toolbar, …` + 一个 `view` 把布局骨架写出来
  （`stack .shell > toolbar/formula/.shell-main(grid + inspector/debug)/status`）
- `sheets.html` 从"六个空 div 的骨架"缩成 `<div id="app"></div>`；
  `app/sheets.rb` 从六次 `mount_at` + 手工构造编辑器实例变成一次 `mount_at("app", app)`
- 面板之间过去只能靠"共享普通对象 + 根组件反向持有子组件引用"通信；
  现在共享的走 prop、动作走回调 Proc、**各自的状态留在各自面板里**

### 9.2 视图态下沉：选中/闪烁/行列高亮归网格面板

- 从前 `Application` 持有 1560+ 个视图信号并**主动 push** 增量
  （`publish_selection_delta` / `flash_cells` / `tick_visuals`）；
  现在 `Application` 只发布**数据层事实**（选区信号 + `flash` 信号里的"本轮哪些格变了"），
  由 `GridPanel` 订阅并翻译成逐格视图信号（`setup_view_state` 里两个 `Effect`，
  随 `on_mount`/`on_unmount` 起停）
- 埋点里的"信号对象数"仍要跨组件汇总：面板在分配视图信号时把总数报给 `Telemetry`，
  根组件读它（`Application#signal_count`）；"闪烁格数"这类**视图态**则从 DOM 现取
  （`sheetsTestApi.state()` 追加 `.cell.is-flash` 计数）——测试断言反而更接近用户所见
- 从前"公式栏输入框必须挂在永不重建的块里"这条纪律**删除**了：焦点现在由公式栏
  自己订阅 `edit_mode` 决定（进编辑态 focus、退出 blur），不再需要
  `Application#attach_editor` 这条"根组件持子组件引用"的链

### 9.3 keyed 复用：结构身份按 key 标出来

- 网格的行（`"row-3"`）、列头（`"col-head-2"`）、单元格（**地址 `"B3"`**）、
  检查器的依赖标签（地址）都带上了 `key:`
- 行列数变成**结构信号**（`Workbook#resize` 是它的入口），网格的结构块读 `workbook.rows/cols`：
  结构一变就重跑结构块，key 命中的节点原地复用（DOM / Effect / 事件全留），
  只有真正新增的才新建
- 行/列头的选中高亮从"块里读信号 → 重建节点"改成**响应式属性**
  （`css_class: -> { … }`）：移动选区从"重建 2 个表头"变成"重设 2 个 class"

### 9.4 迁移后的实测（同一份桩 + 真机 headless Chrome 复核）

| 场景 | 迁移前 | 迁移后 | 说明 |
|---|---|---|---|
| 挂载 1560 格 | 3596 个新建节点（桩） | 3595（桩）/ 3593（真机） | 结构一致，只有骨架少了一个 wrapper |
| 改一个数（B2） | 210 个新建节点 | **1**（真机）/ 6（桩） | 面板内部按位置/key 复用，少数新节点来自新出现的依赖标签 |
| 点选一格 | 58 个新建节点 | **0**（真机） | 高亮只重设 class（响应式属性） |
| 移动 5 格 | — | 10（桩） | 同上 |
| 结构变更（60 → 62 行） | 不可能（没有这条路径） | 原有 1560 个单元格**全是同一批 DOM 对象** | 真机 + 桩都验证；缩回去时只卸载新增的行 |

同时补的回归断言（桩）：结构变更后行/列头/单元格是同一批 DOM 对象、公式栏输入框存活、
依赖标签按地址复用（新地址必须新节点）、DOM 层的选中类名与状态栏数字跟随更新。
真机复核：`.grid-scroll` 358×460、单元格 84×22、无横向溢出、控制台零报错；
打字进编辑态焦点自动落到输入框、提交后 26 格闪烁并在一拍内清零、
结构变更后仍可正常编辑。

### 9.5 顺带修的一处**测试基础设施**缺陷（与 PR #15 同款）

桩的假 DOM 里 `appendChild` 没有实现真实 DOM 的**移动语义**
（已在同父下的节点不会移到末尾、跨父节点不先摘除）。PR #15 的提交信息里记过这个坑
（当时表现为"删行后 DOM 顺序看着是旧的"）；本仓库这次迁移会走复用路径，
所以先把桩改成真实语义再动手——否则新语义在桩里会产出重复行/错序，测试会假失败。
