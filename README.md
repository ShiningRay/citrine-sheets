# Citrine Sheets（迷你电子表格）

用 [Citrine](https://github.com/ShiningRay/citrine)（信号式 Ruby UI 框架，经 Opal 编译到浏览器）
写的**键盘优先**迷你电子表格：公式引擎、依赖图增量重算、循环引用检测、撤销重做、
选区聚合统计、每格独立格式。

> 这是本项目的**第二个方向不同的 demo**：第一个
> [citrine-market-terminal](https://github.com/ShiningRay/citrine-market-terminal) 是
> 鼠标驱动 + 模拟数据流 + 数值展示；本仓库反过来——**键盘驱动 + 用户输入 + 递归依赖图**。
>
> 架构上它同时是**框架缺口的原始症状来源**与**落地后的验收场**：六个平级挂载根
> 曾经是"没有组件嵌套（第一辑 F5）"时的绕法，**随 citrine PR #15（组件嵌套 + keyed 复用）
> 落地后已改成单一挂载根 + 组件树**，绕法与其注释一并删除（迁移记录见
> [FRICTION-2.md](FRICTION-2.md) §9，行为对比与实测数字也在那里）。
>
> 开发中撞出的框架摩擦记在 **[FRICTION-2.md](FRICTION-2.md)**（13 条 + 一节 Opal 专题，
> 含源码定位与改法建议）。

```
┌─ 工具条：选区/维度 · 撤销重做 · 加粗与底色 · 小数位 · 清空 · 重算 ───────────────┐
├─ 公式栏：[地址] fx [ 编辑框（直接打字即进入编辑） ] 确认/取消 ───────────────────┤
├──────────────────────────── 网格 26 列 × 60 行 ──────────┬─ 单元格检查器 ──────┤
│   A      B        C        D        E         F          │  原始输入/计算值/类型 │
│ 1 月份   收入     成本     毛利     毛利率    累计毛利    │  ← 引用了哪些格（可点）│
│ 2 1月    120,000  78,000   42,000   0.3500    42,000     │  → 被哪些格引用（可点）│
│ …                                                        │  上次重算：格数/耗时  │
│ 14 合计  1,883,500 …                                     ├─ 信号与渲染埋点 ─────┤
│ 16 统计  AVERAGE/MIN/MAX/COUNT                           │  挂载耗时 / Effect 数 │
│ 20 情景分析（改 C20 涨价系数 → 整块重算）                │  新建 DOM / 信号对象  │
│ 27 错误演示（#DIV/0! #CIRC! #REF! #VALUE! #NAME?）        │  编辑轮次            │
└──────────────────────────────────────────────────────────┴──────────────────────┘
├─ 状态栏：选区 求和/平均/最小/最大/错误 · 全表 填充/公式/错误/循环 · 撤销栈 ───────┤
```

示例数据是一份 12 个月的损益表（收入/成本/毛利/毛利率/累计毛利 + 合计 + 统计 + 情景分析
+ 五种错误演示），载入即可玩。

![界面截图](docs/screenshot.png)

## 运行

```bash
# 依赖：Ruby ≥ 3.0、Opal 1.8（gem install opal）、Node（仅验收用）
# 需要 citrine 仓库与本仓库同级，或用 CITRINE_ROOT 指定

bin/dev                 # → http://localhost:4404/sheets.html
                        #    改 app/**/*.rb 或 citrine/lib/**/*.rb 都会自动刷新

rake check              # 单测 + 桩验收 + 跨平台一致性（提交前跑）
```

**原生窗口（CRuby + libui，不经 Opal）**：

```bash
# 额外依赖：citrine-native 与本仓库同级（CITRINE_NATIVE_ROOT 可覆盖）、gem libui
bin/native              # 直接起原生窗口，逻辑复用 app/，视图换成 native/views/**

rake native:test        # 原生端口测试（Memory 桩后端，无窗口）
```

| 命令 | 作用 |
|---|---|
| `bin/dev` | 开发服务器（包装 citrine 的 dev server，端口 4404，支持 `-p` 覆盖） |
| `rake test` | CRuby 内核单测（48 项 / 203 断言：解析、求值、函数、依赖图、撤销） |
| `rake build` | 编译 `app/sheets.rb` → `app/sheets.js` |
| `rake stubs` | Node DOM 桩验收（116 项键盘、编辑链路与复用语义断言，不需要浏览器） |
| `rake parity` | CRuby 与 Opal 两侧内核输出**逐字节**比对（95 行） |
| `rake native:test` | 原生端口测试（绘制序列 + 事件路径，Memory 桩后端，无窗口） |
| `bin/native` | 原生窗口（CRuby + libui；见下节） |
| `rake check` | 以上全部（不含原生） |

## 操作

| 操作 | 方式 |
|---|---|
| 移动 | 方向键 · 点选 · `⌘↑↓←→` 跳到数据边缘 |
| 扩展选区 | `Shift+方向键`（状态栏实时显示求和/平均/最值） |
| 编辑 | **直接打字即编辑** · `Enter` 编辑现有内容 · `Backspace` 清空后编辑 |
| 提交 / 取消 | `Enter` 提交并下移 · `Tab` 提交并右移 · `Esc` 取消 |
| 撤销 / 重做 | `⌘Z` / `⌘⇧Z`（含公式与依赖图的完整回滚） |
| 加粗 | `⌘B`（选中区域批量应用） |
| 清空 | `Delete` 清空选区内容与格式 |
| 格式 | 工具条：加粗、底色、小数位（自动/0/2/4 位） |

**试试看**：改 `B2` 的收入数字 → 看右侧「重算格数」与网格里的黄色闪烁（受影响的格子会被标注）；
选中 `E2` 看它引用了 `D2`/`B2`（点标签直接跳转）；改 `C20` 涨价系数 → 情景分析整块重算；
选中 `B29` 看循环引用 `#CIRC!`，改成常量即可打破、`⌘Z` 可撤销回来。

## 目录

```
├── app/
│   ├── sheets.rb            # 浏览器入口：挂载唯一的根组件（#app）
│   ├── sheets.html          # 页面外壳（挂载点 + 外链 styles.css；令牌在 tokens.rb）
│   ├── tokens.rb            # 设计令牌唯一来源（浏览器 CSS / 视图 / 原生 theme 三处共用）
│   ├── styles.css           # 浏览器样式表（规则经 var(--x) 引用令牌，无字面量色值）
│   ├── application.rb       # ★ 根组件：共享模型（选区/编辑/格式/撤销）+ 组件树骨架
│   ├── workbook.rb          # ★ 工作簿：单元格、依赖图、拓扑重算、循环检测、信号发布
│   ├── formula.rb           # 公式语言：词法 + 递归下降解析 + 静态依赖提取
│   ├── evaluator.rb         # 求值器（IF/AND/OR/IFERROR 短路求值，错误值传播）
│   ├── functions.rb         # 函数库（SUM/AVERAGE/MIN/MAX/COUNT/ROUND/IF…共 18 个）
│   ├── value.rb             # 值语义：错误值、强制转换、比较
│   ├── format.rb            # 显示格式化（千分位、小数位、列标签 A..Z）
│   ├── num.rb               # 跨平台数值工具（Opal 整数除法/取整差异 → FRICTION-2 G-11）
│   ├── seed.rb              # 示例数据（损益表 + 统计 + 情景分析 + 错误演示）
│   ├── telemetry.rb         # 埋点：Effect 重跑 / 新建 DOM 计数（v1 无官方钩子 → 第一辑 F9）
│   ├── test_api.rb          # 桩验收驱动接口（原 glue.rb 的外挂逻辑已迁入框架能力）
│   ├── parity.rb            # 跨平台一致性输出脚本（由 rake parity 驱动）
│   └── panels/              # 根组件的六个子组件（各自独立订阅，互不牵连）
│       ├── common.rb        #   面板基类 + 视图层纪律（改视图前先读）
│       ├── toolbar.rb       #   撤销重做 / 格式 / 清空 / 重算
│       ├── formula_bar.rb   #   地址 + 编辑框（★ 自己订阅编辑态管焦点）
│       ├── grid.rb          #   列头 + 行头 + 1560 个单元格（两层 + keyed 复用）
│       ├── inspector.rb     #   单元格详情 + 依赖跳转（按地址 key 复用标签）
│       ├── status_bar.rb    #   选区聚合统计 + 全表统计
│       └── debug_bar.rb     #   信号与渲染埋点
├── test/
│   ├── workbook_test.rb     # CRuby 内核单测（含解析/求值/依赖图/循环/撤销）
│   ├── sheets_stub_check.js # Node DOM 桩验收（键盘优先 + 复用语义的全链路）
│   └── harness.js           # 桩宿主（模拟 DOM + window 键盘 + 定时器 + 事件冒泡）
├── FRICTION-2.md            # ★ 本仓库撞出的改进清单（13 条 + §7「要不要 fork Opal」调研）
└── docs/                    # 第一辑的框架审计报告与探针（背景参考）
```

## 三层验证

| 层 | 手段 | 覆盖 |
|---|---|---|
| 内核 | `rake test`（CRuby + minitest，48 项） | 解析优先级/结合性/引用/区间/错误、求值与错误传播、18 个函数、依赖图与增量重算范围、循环检测与恢复、撤销重做、格式与显示 |
| 装配 | `rake stubs`（Node DOM 桩，116 项） | 单根组件树挂载、点选与键盘导航、选区扩展与聚合、直接打字即编辑、提交与依赖链联动、格式、清空、撤销重做、循环引用、依赖跳转、闪烁、**复用语义（结构变更后节点身份 / 输入框存活 / 依赖标签按 key 复用）**、渲染开销量化 |
| 一致性 | `rake parity` | 同一份内核在 CRuby 与 Opal 下输出逐字节一致（95 行）——表格引擎到处是除法与取整，这是跨平台语义差异的重灾区 |

**原生端口**（第四种跑法，见下节）：`rake native:test` 用 Memory 桩后端断言"画了什么"
与事件路径（无窗口）；`bin/native` 起真 libui 窗口，逻辑与浏览器侧完全共用 `app/application.rb`。

浏览器侧实测（headless Chrome，`bin/dev` 起服务）：六个面板与 1560 格正常渲染
（`.grid-scroll` 358×460、内容 2230px 可横向滚动、页面无横向溢出）、控制台零报错；
方向键/Shift 扩展/直接打字编辑/Esc 取消/⌘Z 全部生效；
改 `B2` 触发 **33 格重算、26 格显示变化**，改 `C20` 让情景分析整块联动；
结构变更（行列数 60 → 62 → 60）后 1560 个单元格**仍是同一批 DOM 对象**，公式栏输入框照用。

**渲染开销量化**（均为迁移到组件树之后重新测量；面板底部实时显示）：

| 场景 | 新建 DOM 节点 | 来源 | 说明 |
|---|---|---|---|
| 挂载 1560 格 | **3593** / ≈600 ms | 真机 | 每格两层结构（静态槽 + 响应式属性 / 文本） |
| 改 `B2`（33 格重算、26 格闪烁） | **1** | 真机（91 次 Effect 重跑） | 面板内部按位置/key 复用节点，只新建真正新增的（如新出现的依赖标签） |
| 点选一格 | **0** | 真机 | 高亮只重设 class/style（响应式属性）；旧版这里是 58 |
| 移动 5 格 | **10** | Node 桩 | 同上 |
| 结构变更（多两行） | 只有新增行/格 | 真机 + 桩 | 原有 1560 格全是同一批 DOM 对象；缩回去时只卸载新增的行 |
| 单元格数值更新本身 | **0** | 两侧一致 | 叶子块只调 `textContent`，不新建节点 |

> 对照：把单元格直接建在行块里（让行块订阅整行信号）时，同一次编辑要新建 **1903** 个节点
> ——差别只在于 props 写在哪一层求值，见 FRICTION-2 的 G-2。
> 迁移前的数字（210 / 58）与迁移后的对比见 FRICTION-2 §9.4。

## 原生端口（citrine-native）

同一份逻辑挂到 [citrine-native](https://github.com/ShiningRay/citrine-native) 的原生窗口
（CRuby + libui，不经 Opal/浏览器）。**逻辑零复制**：`Sheets::Native::NativeApp < Sheets::Application`
只覆盖 `view` 与键盘入口，选区/编辑/撤销/格式/重算全部复用 `app/application.rb`。

```
├── bin/native               # 启动器（三个仓库的加载路径 + 早失败提示）
├── native/
│   ├── app.rb               # ★ NativeApp（只覆盖 view + global_key/edit_key）+ 窗口默认值
│   ├── theme.rb             # 配色常量（全部从 app/tokens.rb 派生）
│   ├── views/grid.rb        # ★ 网格 = 一个自绘面板（area）：一次 on_draw 画完 1560 格
│   ├── views/panels.rb      # 工具条/公式栏/检查器/状态栏/埋点（原生 label + button + text_input）
│   ├── README.md            # 原生侧的**操作表 + 平台限制**（中文怎么输入、焦点、布局坑）
│   └── test/                # CRuby 测试：绘制序列 + 事件路径（Memory 桩后端，无窗口）
```

差异只在**平台能力**，都有对应位置与注释（逐条限制与实测数字见 [native/README.md](native/README.md)）：

| 浏览器侧 | 原生侧 |
|---|---|
| 1560 个单元格节点 + 逐格信号 | 一个 `element(:area, scroll: true)` 自绘面板：列头/行号/网格线/值/选中/闪烁一次画完（空白格不出 `text` 调用，整块约 200 个图元） |
| `window_key` 全局键盘（`<input>` 挡住的部分由 Application 判断 `target.tagName`） | 同一个 `window_key :global_key`，但由聚焦的 area 转发；DOM 的 `tagName == "INPUT"` 判据换成"原生 entry 的按键本来就到不了 window 层"；焦点在窗口显示+激活之后取（晚到自动撤提示，见 SHEETS-1c 的 D1） |
| Enter/Tab/Esc 由 `<input>` 自己接管（`FormulaBar` 的 `on_enter`/`on_key`） | `NativeApp#edit_key`：编辑态下 Enter 提交、Tab 提交并横移、Esc 取消、Backspace 删字符、可打印字符追加（libui 的 entry 拿不到按键）；方向键在编辑态与浏览器一致地"什么都不做" |
| 公式栏输入框 watch `edit_mode` 自己 focus/blur | 原生侧没有"程序化 focus entry"的 API（libui 无 `uiControlSetFocus`），故打字流由 area 接管，鼠标点输入框可继续改（**中文只能走这条路**：非 ASCII 键入到不了网格） |
| `.cell { overflow: hidden }` + `text-overflow: ellipsis` | 单元格文本 `clip` 到格的内容框，左对齐超宽时截断加「…」（右对齐的数字裁行首、不加省略号，与浏览器一致） |
| `GridPanel` 的 `setInterval` 清闪烁 | `Citrine::Native.every(150) { clear_flash }`（框架定时器 API） |
| CSS 类名/kebab 样式 | `native/theme.rb` 的常量 + `Painter` 的颜色/字重参数（背景/边框类样式在原生侧不做） |

**布局坑（SHEETS-1c 的 D2）**：根元素必须**自己**声明 `style: { flex_grow: 1 }`——框架把根元素
追加进窗口根容器时的 stretchy 取自根元素自己的样式，不声明就只有内容自然高度（窗口下半空白、
里面所有 flex_grow 都分不到空间；实测网格可见区从 578×214 变 579×667）。




- 不支持合并单元格、行列宽高调整、拖拽填充、多工作表
- 行列数可以变（`Workbook#resize` → 结构信号 → 网格按 key 复用），
  但**还没有"插入/删除行列"的 UI**：这条路径目前由桩验收驱动（`sheetsTestApi.resizeGrid`），
  用来锁住 keyed 复用的语义；也没有相对引用改写（插入行会让公式指向原地址）
- 公式语言是子集：无数组公式、无跨表引用、无 `%` 后缀运算符、无文本比较的大小写折叠
- 循环引用会把**环内及环下游**的格子都标为 `#CIRC!`（不做 SCC 精确区分环内外）
- 撤销以"整表快照"实现（数据量级下足够快，不是增量日志）

## 许可

MIT（与 citrine 一致）
