# Citrine 摩擦记录 · 第二辑（电子表格方向）

> 记录时间：2026-09-14 ｜ 框架版本：Citrine **0.1.1**
> 来源：本仓库（Citrine Sheets，迷你电子表格）实际开发过程中的踩坑。
> 第一辑见 [citrine-market-terminal/FRICTION.md](https://github.com/ShiningRay/citrine-market-terminal/blob/main/FRICTION.md)（行情终端，23 条）。
>
> **与第一辑的关系**：第一辑里 0.1.1 已修的 F1/F2/F16/F17/F19/F20 在本仓库得到**应用级验证**
> （见 G-1）；本辑记录的 15 条里，G-5 ~ G-8 是**新的 Opal 互操作陷阱**，
> G-2/G-3 是"块级重建 + 无批处理"在**依赖图型应用**上的连锁效应，
> G-10 与第一辑 F23 是同一个坑的**第二次踩中**。
> 每条都给「现象 → 证据 → 位置 → 建议改法」。

---

## 一、先记一笔：0.1.1 的修复在真实应用里成立

**G-1（正面验证）** 本应用有六个平级挂载根共享一个普通 Ruby 对象（`Application`），
并且检查器里存在"容器块与内层标签读同一信号"的写法——这两件事在 0.1.0 上分别会触发
第一辑的 F2（多根互相清空）与 F1（陈旧订阅快照崩溃）。0.1.1 上**零异常**：

- 六个根各自 `mount_at` 正常，跨根信号传播正确（`app/sheets.rb`）
- 祖先块 + 后代块订阅同一 `selection` / `value` 信号，无崩溃（`app/panels/inspector.rb`）

**结论**：**"多根挂载 + 共享普通对象"是 v1 里做中等规模应用的可推荐架构**，
比第一辑那种"单类 + 混入模块"更清晰（状态外置、面板各自独立订阅）。
建议直接写进框架文档的"推荐用法"。

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

**【附带发现】** 合成事件时容易踩：Enter 的 keydown 必须**派发在 input 元素上**
（框架的监听器绑在元素上，发在 window 上不会触发 `on_enter`），
而真实浏览器里用户按键自然满足这一点。

**【建议改法】** 同第一辑 F10：`on_key:` / `on_blur:` / `on_focus:`；
另外建议给 `Component` 一个官方入口注册"全局键盘"（本仓库只能自己 `window.addEventListener`）。

### G-10. 无生命周期 / ref（对应第一辑 F7）

**【现象】** 本应用需要：定时器（清理闪烁标注）、原生 `focus()`/`blur()`（把焦点送进编辑框）、
`beforeunload` 清理。框架都不提供，只能由 `Application` 持有组件引用 + 外挂层自己接。

**【证据】**【实测】`app/glue.rb`（定时器 + 键盘 + 焦点）、`app/application.rb#attach_editor`。

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

---

## 五、本仓库采用的架构姿势（可直接抄）

1. **多根挂载 + 共享普通对象**：6 个挂载根共享一个 `Application`（状态、选区、撤销都在它上面），
   组件只做"读信号 + 转发动作"。这解决了 v1 无组件嵌套（第一辑 F5）时的结构问题，
   也让每个面板能独立订阅、独立重绘。
2. **信号按更新频率分层**：每格三个信号——值（每次重算变）、外观（格式/错误态）、
   视图（选中/闪烁）——分别由三层 DOM 订阅。
   **收益（实测）**：改一个数只触发 1 次叶子重跑，**0 个新建节点**；
   1560 格的表全量重算也只新建 56 个节点（真机埋点数字）。
3. **"重算信号"作为粗粒度订阅口径**（见 G-3）。
4. **公式依赖图自建**，不直接用信号（原因写在 `app/workbook.rb` 顶部：
   循环引用要变成可显示的错误值、需要静态依赖、需要一次编辑一次发布）。

## 六、优先级建议（叠加第一辑后的顺序）

| 优先级 | 项 | 理由 |
|---|---|---|
| **P0** | 第一辑 F1/F2 | 已在 0.1.1 修复 ✅（本仓库验证通过） |
| **P0** | **G-2 props 求值位置**（或文档显式警告） | 一个字的差别带来 5~10 倍的渲染量，且完全不可见 |
| **P0** | **G-8 `box` 默认方向** | 两次踩中、真机塌陷、桩测不可见；改默认值或 dev 告警 |
| **P1** | 第一辑 F3 批量更新 | G-3 证明它会连锁放大（订阅口径 → 重绘次数） |
| **P1** | **G-4 ~ G-7 四条 Opal 陷阱 + G-11 数值工具** | 每条都让排查成本远超修复成本，**文档就能立刻改善** |
| **P1** | 第一辑 F10 键盘 / F7 生命周期 / F9 埋点 | 键盘优先类应用的基本盘（本仓库全靠外挂） |
| **P2** | 第一辑 F5/F6（组件嵌套 / keyed 复用） | 本仓库用"多根 + 共享对象"绕过了，但列表类应用仍会痛 |

**一句话总结（第二辑）**：0.1.1 把"会崩"的问题解决了；这一辑暴露的三类新问题是
**① 响应式边界不可见**（props 求值位置、订阅口径 → G-2/G-3）、
**② 默认值/文档缺位**（box 方向、Opal 陷阱 → G-8/G-4~G-7）、
**③ 键盘与生命周期缺席**（G-9/G-10）。
其中 **①② 的修复成本都极低**（改默认值 / 补文档 / 允许 props 传 Proc），
却直接决定"能不能顺畅写出中等规模应用"。

---

## 七、专题：要不要 fork 一份 Opal 自己改？

> 2026-09-14 基于**实测**（本仓库 + 第一辑探针）与**上游仓库状态调研**（`gh api` 实时查询）。
> 结论：**不建议 fork**。理由与替代路径如下。

### 7.1 先把"Opal 的问题"分类——三类东西的处理方式完全不同

| 我们撞到的差异 | 性质 | 上游状态 | fork 能解决吗 | 处置 |
|---|---|---|---|---|
| `1 / 4 == 0.25`（整数除法返浮点） | **设计选择** | `docs/unsupported_features.md` §Integer / Float difference 明文记录；issue #748 / #505 已 closed | 能改，但会与 corelib 的 `Number`(= JS number) 模型全面冲突，且让 Citrine 行为与其它 Opal 用户不一致 | ❌ 不 fork，Citrine 侧 `Num.idiv` |
| `String#<<` / `#gsub!` 不存在 | **设计选择** | 同上 §Mutable Strings（"所有字符串不可变"） | 不能（corelib 全建立于不可变 JS 字符串） | ❌ 不 fork，文档 + 用 `+` |
| `Float#round` 负数半值方向（`-1.5.round` → `-1`，Ruby 是 `-2`） | **真 bug**：用 `Math.round`（朝 +∞）而**同一个方法里的整数分支**已经用"绝对值 + floor"（远离零），自相矛盾 | 未找到对应 issue（#572 是"`round(2)` 返回整数"那个老问题，已修） | 能，**4 行** | ✅ **提 PR**（附 mspec 用例） |
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
| **L1** | 给上游提 PR：① `Float#round` 修复（附 mspec）；② 把真实应用的陷阱补进 `docs/unsupported_features.md` | 中低 | 想提就提，**提了不亏**：合入即零维护 |
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

**实测校验**（本机 node 与 CRuby 11 组对照，含 `-1.35.round(1)`、`±2.675.round(2)` 这类边界）：
提案实现 **11/11 与 Ruby 一致**，当前实现错 5 组。

```
-1.5.round    Ruby -2    Opal -1    → 提案 -2
-2.5.round    Ruby -3    Opal -2    → 提案 -3
-0.5.round    Ruby -1    Opal  0    → 提案 -1
-1.25.round(1) Ruby -1.3 Opal -1.2  → 提案 -1.3
-2.675.round(2) Ruby -2.68 Opal -2.67 → 提案 -2.68
```
