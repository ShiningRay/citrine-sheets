// sheets_stub_check.js — Node DOM 桩验收：Citrine Sheets（不起浏览器）
//
//   rake stubs
//
// 覆盖：单根组件树挂载、种子数据与公式计算、点选与键盘导航、
//       直接打字即编辑、公式栏提交与依赖链重算、选区聚合、格式、清空、
//       撤销重做、循环引用、依赖跳转、闪烁标注、渲染开销量化、
//       组件嵌套 + keyed 复用的语义（结构变更后节点身份、输入框存活、按 key 复用）
const { boot } = require("./harness");

let failures = 0;
function eq(name, actual, expected) {
  const ok = String(actual) === String(expected);
  console.log(`${ok ? "✓" : "✗"} ${name}${ok ? "" : `  期望 ${JSON.stringify(expected)} 实际 ${JSON.stringify(actual)}`}`);
  if (!ok) failures += 1;
}
function ok(name, condition, detail) {
  console.log(`${condition ? "✓" : "✗"} ${name}${condition ? "" : `  实际 ${JSON.stringify(detail)}`}`);
  if (!condition) failures += 1;
}

const h = boot();
const state = () => h.state();

console.log("=== 首次挂载：单一挂载根 #app 里的组件树 ===");
let s = state();
eq("选中格", s.sel, "A1");
eq("填充格数", s.filled, "129");
eq("公式格数", s.formulas, "61");
eq("错误格数", s.errors, "6");
eq("循环引用格数", s.cyclic, "2");
eq("网格行数", h.byClass("grid-row").length, 60);
eq("单元格数", h.byClass("cell").length, 1560);
ok(`挂载新建 DOM 节点 ${h.nodesCreated()} 个（< 8000）`, h.nodesCreated() < 8000, h.nodesCreated());
eq("表头渲染", h.cellText(0, 0), "月份");
eq("公式算出的毛利", h.cellText(1, 3), "42,000");
eq("毛利率按格格式显示 4 位小数", h.cellText(1, 4), "0.3500");
eq("合计行 SUM", h.cellText(13, 1), "1,883,500");
eq("情景分析结论", h.cellText(24, 1), "提价显著改善");

console.log("\n=== 点选与键盘导航 ===");
h.clickCell(1, 1); // B2
s = state();
eq("点击选中 B2", s.sel, "B2");
eq("原始输入随选区更新", s.raw, "120000");
eq("检查器显示计算值", s.val, "120,000");
eq("类型判定", s.kind, "数字");
eq("公式栏输入框同步内容", s.input, "120000");

h.fireKey("ArrowDown");
eq("↓ 移到 B3", state().sel, "B3");
h.fireKey("ArrowRight");
eq("→ 移到 C3", state().sel, "C3");
h.fireKey("ArrowUp", { shiftKey: true });
s = state();
eq("Shift+↑ 扩展选区", s.range, "C2:C3");
eq("活动格在选区端点", s.sel, "C2");
eq("扩展选区数值个数", s.stats.split("/")[0], "2");
eq("扩展选区求和", s.stats.split("/")[1], "162100");
h.fireKey("ArrowLeft");
eq("无 Shift 恢复单格选区", state().range, "B2");

console.log("\n=== 直接打字即编辑（键盘优先的关键路径）===");
h.fireKey("5");
s = state();
eq("进入编辑态", s.edit, "true");
eq("输入框内容为按键字符", s.input, "5");
ok("焦点自动落到编辑框", h.activeElement() === h.inputEl(),
   h.activeElement() ? h.activeElement().className : "null");

console.log("\n=== 提交编辑：公式与依赖链重算 ===");
h.typeInInput("150000");
h.pressEnterInInput();
s = state();
eq("提交后退出编辑态", s.edit, "false");
eq("B2 单元格文本", h.cellText(1, 1), "150,000"); // 注意选区已下移到 B3，不能看 s.val
eq("选区下移一格（Enter 语义）", s.sel, "B3");
ok(`重算格数 ${s.recalc.split("/")[0]}（B2 影响 D2/E2/F2/合计/统计…）`, Number(s.recalc.split("/")[0]) >= 5, s.recalc);
ok(`闪烁标注 ${s.flash} 格 > 0`, Number(s.flash) > 0, s.flash);
eq("毛利格联动", h.cellText(1, 3), "72,000");
eq("累计毛利格联动", h.cellText(1, 5), "72,000");
eq("合计行联动", h.cellText(13, 1), "1,913,500");
h.runTicks(1);
eq("心跳后闪烁清空", state().flash, "0");

console.log("\n=== 只重建受影响的单元（渲染开销量化）===");
h.resetNodeCounter();
h.clickCell(3, 1); // B4
h.fireKey("2");
h.typeInInput("99000");
h.pressEnterInInput();
const editNodes = h.nodesCreated();
// 组成：少数真正需要新建的节点（新出现的依赖标签等）。
// 单元格与已有面板内容都不在此列：G-2 之后闪烁只重设属性，面板内部则按位置/key 复用节点。
ok(`改一个数新建 DOM 节点 ${editNodes} 个（< 300）`, editNodes < 300, editNodes);
ok(`数据编辑不新建任何单元格节点：${s.nodes}`, !/cell/.test(String(s.nodes)), s.nodes);
eq("B4 已写入", h.cellText(3, 1), "99,000");
const inspText = h.byClass("kv-v").map((n) => String(n.textContent)).join(" · ");
ok(`检查器 DOM 跟随更新（${inspText}）`, inspText.includes("已写入 B4"), inspText);
eq("网格工具条动作行跟随更新", h.byClass("grid-action")[0].textContent.includes("已写入 B4"), true);
ok("状态栏摘要渲染在 DOM 里", String(h.byClass("st-summary")[0].textContent).includes("填充"), h.byClass("st-summary")[0].textContent);

console.log("\n=== 检查器：依赖与反向依赖可点击跳转 ===");
h.clickCell(1, 4); // E2 = D2/B2
const chips = h.byClass("chip-cell").map((c) => String(c.textContent));
ok(`E2 的引用标签 ${chips.join(",")} 含 D2 与 B2`, chips.includes("D2") && chips.includes("B2"));
ok(`E2 的被引用标签含 B18（=MIN(E2:E13)）`, chips.includes("B18"), chips.join(","));
h.byClass("chip-cell").find((c) => String(c.textContent) === "D2").fire("click");
eq("点击依赖标签跳到 D2", state().sel, "D2");

console.log("\n=== 循环引用：可见、可修、可撤销 ===");
h.clickCell(28, 1); // B29 = B30
s = state();
eq("循环格显示错误值", s.val, "#CIRC!");
eq("循环计数", s.cyclic, "2");
eq("类型判定为公式错误值", s.kind, "公式 → 错误值");
h.fireKey("7"); // 直接打字进入编辑态
h.pressEnterInInput();
s = state();
eq("写入常量后环被打破", s.val, "7");
eq("循环计数归零", s.cyclic, "0");
h.fireKey("z", { metaKey: true });
s = state();
eq("⌘Z 撤销后循环恢复", s.cyclic, "2");
eq("撤销后值也恢复", s.val, "#CIRC!");

console.log("\n=== 错误值语义 ===");
h.clickCell(27, 1);
eq("除零 → #DIV/0!", state().val, "#DIV/0!");
h.clickCell(30, 1);
eq("越界引用 → #REF!", state().val, "#REF!");
h.clickCell(31, 1);
eq("类型错误 → #VALUE!", state().val, "#VALUE!");
h.clickCell(32, 1);
eq("未知函数 → #NAME?", state().val, "#NAME?");

console.log("\n=== 选区聚合统计 ===");
h.clickCell(1, 1);
h.fireKey("ArrowDown", { shiftKey: true });
h.fireKey("ArrowDown", { shiftKey: true });
s = state();
eq("选中三格", s.range, "B2:B4");
eq("数值个数", s.stats.split("/")[0], "3");
eq("求和", s.stats.split("/")[1], "381500"); // 150000 + 132500 + 99000

console.log("\n=== 格式与小数位 ===");
h.clickCell(1, 1);
h.clickChip("2 位");
eq("设置 2 位小数", state().val, "150,000.00");
h.clickChip("0 位");
eq("设置 0 位小数", state().val, "150,000");
h.clickChip("B 加粗");
const chrome = h.cellEl(1, 1); // G-2 后外观类名就在单元格节点上（不再有中层）
ok("加粗类名生效", h.matchClass(chrome, "is-bold"), chrome ? chrome.className : "无单元格节点");

console.log("\n=== 清空与撤销重做 ===");
h.clickChip("清空选区");
s = state();
eq("清空后原始输入为空", s.raw, "");
eq("清空后值显示为空", s.val, "");
h.fireKey("z", { metaKey: true });
eq("撤销恢复数值", state().val, "150,000"); // 撤销前的格式是 0 位小数
h.fireKey("z", { metaKey: true, shiftKey: true });
eq("重做再次清空", state().raw, "");

console.log("\n=== 情景分析：改一个参数，整块重算 ===");
h.clickCell(19, 2); // C20 涨价系数
h.fireKey("1");
h.typeInInput("1.25");
h.pressEnterInInput();
s = state();
eq("参数写入单元格", h.cellText(19, 2), "1.25"); // 选区已下移，看单元格而不是活动格
const revenue = h.cellText(20, 1);
ok(`调价后收入随参数变化（${revenue}）`, revenue !== "2,034,180.00", revenue);
ok(`结论格输出文本：${h.cellText(24, 1)}`, String(h.cellText(24, 1)).length > 0);

console.log("\n=== 公式栏输入框的 DOM 身份（v1 里保住焦点的前提）===");
const inputRef = h.inputEl();
for (let i = 0; i < 6; i += 1) h.fireKey("ArrowDown");
eq("连续移动 6 格后输入框仍是同一节点", h.inputEl() === inputRef, true);
ok("输入框仍挂在文档里（未被重建摘除）", h.inputEl().parentElement !== null, true);

console.log("\n=== 选中高亮的更新粒度（视图态归网格面板）===");
h.clickCell(1, 1); // B2
ok("B2 单元格带 is-sel", h.matchClass(h.cellEl(1, 1), "is-sel"), h.cellEl(1, 1).className);
ok("上一格 A1 的 is-sel 已被清掉", !h.matchClass(h.cellEl(0, 0), "is-sel"), h.cellEl(0, 0).className);
eq("列头 A 高亮已清掉", h.matchClass(h.byClass("head-inner")[0], "is-on"), false);
ok("列头 B 高亮", h.matchClass(h.byClass("head-inner")[1], "is-on"), h.byClass("head-inner")[1].className);
h.fireKey("ArrowDown", { shiftKey: true });
h.fireKey("ArrowDown", { shiftKey: true });
eq("网格工具条的选区标签随信号更新（DOM 层）", h.byClass("grid-range")[0].textContent, "B2:B4");
eq("状态栏单元格数随信号更新（DOM 层）", h.byClass("st-v")[0].textContent, "3");
h.clickCell(1, 1);
h.resetNodeCounter();
const cellRef = h.cellEl(1, 1);
for (let i = 0; i < 5; i += 1) h.fireKey("ArrowDown");
ok(`移动 5 格新建 DOM 节点 ${h.nodesCreated()} 个（< 40：单元格只重设 class）`,
   h.nodesCreated() < 40, h.nodesCreated());
ok("移动后原单元格节点未被重建", h.cellEl(1, 1) === cellRef, "节点已换");

console.log("\n=== keyed 复用：结构变更只新建真正新增的节点（F6）===");
const rowsBefore = h.byClass("grid-row").slice();
const cellsBefore = h.byClass("cell").slice();
const headsBefore = h.byClass("grid-col-head").slice();
const inputBefore = h.inputEl();
const addressBefore = state().sel;
const textBefore = h.cellText(1, 1);
h.resizeGrid(62, 26); // 结构变更：多两行
const rowsAfter = h.byClass("grid-row");
const cellsAfter = h.byClass("cell");
eq("行数 60 → 62", rowsAfter.length, 62);
eq("单元格数 1560 → 1612", cellsAfter.length, 1612);
ok("原有 60 行仍是同一批 DOM 对象", rowsBefore.every((n, i) => rowsAfter[i] === n),
   rowsBefore.filter((n, i) => rowsAfter[i] !== n).length + " 行被重建");
ok("原有 1560 个单元格仍是同一批 DOM 对象", cellsBefore.every((n, i) => cellsAfter[i] === n),
   cellsBefore.filter((n, i) => cellsAfter[i] !== n).length + " 格被重建");
ok("列头仍是同一批 DOM 对象", headsBefore.every((n, i) => h.byClass("grid-col-head")[i] === n), "列头被重建");
ok("公式栏输入框不受结构变更影响（仍是同一节点）", h.inputEl() === inputBefore, "输入框被换掉了");
eq("结构变更后选区不变", state().sel, addressBefore);
eq("结构变更后单元格内容不变", h.cellText(1, 1), textBefore);
h.resizeGrid(60, 26); // 缩回去：新增的行应被卸载
eq("缩回 60 行后多出来的行被摘掉", h.byClass("grid-row").length, 60);
eq("单元格数回到 1560", h.byClass("cell").length, 1560);
ok("原有单元格节点仍然保留", cellsBefore.every((n, i) => h.byClass("cell")[i] === n), "单元格被重建");
h.clickCell(1, 1);
eq("结构变更后仍可正常选中", state().sel, "B2");
eq("结构变更后仍可编辑（提交写入生效）", (() => {
  h.fireKey("7");
  h.pressEnterInInput();
  return h.cellText(1, 1);
})(), "7");

console.log("\n=== keyed 复用：依赖标签按地址保留节点（F6）===");
h.clickCell(1, 1); // B2：被 SUM/AVERAGE 等区间引用
const chipsB2 = h.byClass("chip-cell").slice();
const byAddress = {};
chipsB2.forEach((c) => { byAddress[String(c.textContent)] = c; });
h.clickCell(2, 1); // B3：依赖集合部分重叠 → 重叠的地址应复用同一节点
const chipsB3 = h.byClass("chip-cell");
const stillThere = Object.keys(byAddress).filter((addr) => chipsB3.some((c) => String(c.textContent) === addr));
ok(`选区变化后重叠的依赖标签有 ${stillThere.length} 个`, stillThere.length > 0, "没有重叠标签，断言无效");
stillThere.forEach((addr) => {
  const after = chipsB3.find((c) => String(c.textContent) === addr);
  ok(`依赖标签 ${addr} 仍是同一 DOM 对象`, after === byAddress[addr], "节点被换了");
});
const fresh = chipsB3.find((c) => !byAddress[String(c.textContent)]);
ok("新出现的依赖标签是新节点（key 决定身份，不是位置）",
   fresh && !chipsB2.includes(fresh), fresh ? String(fresh.textContent) : "无新标签");

console.log("\n=== 编辑态下的键盘语义 ===");
h.clickCell(1, 1);
const rawBefore = state().raw; // 该格此刻的内容（前面被清空过，故用相对断言）
h.fireKey("9");
eq("进入编辑态", state().edit, "true");
eq("编辑态下输入框为按键字符", state().input, "9");
h.keyInInput("Escape", {});
eq("Esc 取消编辑", state().edit, "false");
eq("取消后恢复原输入", state().raw, rawBefore);
h.fireKey("ArrowDown");
eq("非编辑态方向键继续导航", state().sel, "B3");

console.log("\n=== 埋点面板 ===");
const dbg = h.all(h.roots["app"]).map((n) => n.textContent).join(" ");
ok("显示挂载耗时", /挂载耗时/.test(dbg));
ok("显示累计 Effect 重跑", /累计 Effect 重跑/.test(dbg));
ok("显示信号对象数", /信号对象/.test(dbg));

console.log("\n=== 卸载：生命周期收尾（面板自己的订阅与定时器随组件一起回收）===");
eq("卸载前有 grid 的 ticker", h.intervalCount() > 0, true);
h.unmountAll();
eq("挂载点已清空", h.byClass("cell").length, 0);
eq("网格行已清空", h.byClass("grid-row").length, 0);
ok("公式栏输入框已移除", !h.inputEl(), h.inputEl());
eq("面板自己的定时器已停", h.intervalCount(), 0);
eq("window 级键盘监听已解绑", h.windowKeyHandlerCount(), 0);
const selBeforeUnmount = state().sel;
h.fireKey("ArrowDown");
eq("卸载后按键不再改变状态", state().sel, selBeforeUnmount);

const final = state();
console.log(`\n最终：选中 ${final.sel} · 填充 ${final.filled} 格 · 公式 ${final.formulas} 个 · 错误 ${final.errors} 格`);
console.log(failures === 0 ? "\n全部通过 ✅" : `\n${failures} 项失败 ❌`);
process.exit(failures === 0 ? 0 : 1);
