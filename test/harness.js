// harness.js — Node DOM 桩宿主：给 Citrine Sheets 提供一个可无头驱动的假浏览器
//
// 用法：
//   const H = require("./harness");
//   const h = H.boot();                 // 加载 app/sheets.js 并返回驱动接口
//   h.clickCell(1, 1); h.fireKey("5"); …
//
// 提供的能力与真实浏览器一一对应：
//   document.getElementById / createElement / querySelector(All) / activeElement
//   window.addEventListener("keydown") —— 键盘事件的唯一入口
//   window.setInterval / clearInterval —— 闪烁清理的心跳
const fs = require("fs");
const path = require("path");

const APP = path.join(__dirname, "..", "app");

function boot() {
  if (!fs.existsSync(path.join(APP, "sheets.js"))) {
    console.error("缺少 app/sheets.js：先执行 rake build");
    process.exit(2);
  }

  let created = 0;
  function makeEl(tag) {
    created += 1;
    const el = {
      tagName: tag, textContent: "", className: "", value: "", style: {},
      children: [], parentElement: null, _listeners: {}, _attrs: {},
      // 真实 DOM 的 appendChild 是"移动"：已在别处的节点先摘下来，已在同一父下的也移到末尾
      appendChild(c) {
        if (c.parentElement && c.parentElement !== this) c.parentElement.removeChild(c);
        this.children = this.children.filter((x) => x !== c);
        c.parentElement = this;
        this.children.push(c);
        return c;
      },
      removeChild(c) { c.parentElement = null; this.children = this.children.filter((x) => x !== c); },
      addEventListener(ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); },
      fire(ev, event) { (this._listeners[ev] || []).slice().forEach((fn) => fn(event || {})); },
      focus() { global.document.activeElement = this; },
      blur() { if (global.document.activeElement === this) global.document.activeElement = null; },
      setSelectionRange() {},
      setAttribute(k, v) { this._attrs[k] = v; },
    };
    return el;
  }

  // 单一挂载根：整棵组件树（含六个面板）都挂在 #app 里
  const ROOT_IDS = ["app"];
  const roots = {};
  ROOT_IDS.forEach((id) => { roots[id] = makeEl("div"); roots[id].className = id; });

  const all = (el) => [el, ...el.children.flatMap(all)];
  const matchClass = (el, cls) => String(el.className).split(" ").includes(cls);
  const body = makeEl("body");
  body.className = "body";

  global.window = global;
  global.document = {
    getElementById: (id) => roots[id] || null,
    createElement: (t) => makeEl(t),
    activeElement: null,
    body: body,
    querySelectorAll: (sel) => {
      // 支持复合类选择器（".cell.is-flash"）：类名列表全部命中才算匹配
      const classes = String(sel).split(".").filter(Boolean);
      const out = [];
      ROOT_IDS.forEach((id) => all(roots[id]).forEach((n) => {
        if (classes.every((c) => matchClass(n, c))) out.push(n);
      }));
      return out;
    },
    querySelector: (sel) => global.document.querySelectorAll(sel)[0] || null,
  };

  const intervals = [];
  const winHandlers = {};
  global.addEventListener = (ev, fn) => { (winHandlers[ev] = winHandlers[ev] || []).push(fn); };
  global.removeEventListener = (ev, fn) => {
    const list = winHandlers[ev] || [];
    const i = list.indexOf(fn);
    if (i >= 0) list.splice(i, 1);
  };
  global.setInterval = (fn, ms) => { const id = intervals.length + 1; intervals.push({ id, fn, ms }); return id; };
  global.clearInterval = (id) => { const i = intervals.findIndex((x) => x.id === id); if (i >= 0) intervals.splice(i, 1); };
  global.Date = Date;

  require(path.join(APP, "sheets.js"));

  const byClass = (cls, scope) => (scope ? all(scope) : global.document.querySelectorAll(`.${cls}`))
    .filter((n) => (scope ? matchClass(n, cls) : true));
  const gridRows = () => all(roots["app"]).filter((n) => matchClass(n, "grid-row"));

  function cellEl(row, col) {
    const target = gridRows()[row];
    if (!target) return null;
    return all(target).filter((n) => matchClass(n, "cell"))[col];
  }
  // 单元格文本在内层节点上（外层只负责布局与选中态），故递归收集
  function textOf(el) {
    if (!el) return "";
    return all(el).map((n) => n.textContent).filter((t) => t && String(t).trim() !== "").join("|");
  }

  function state() {
    const out = {};
    String(window.sheetsTestApi.state()).split("|").forEach((part) => {
      const i = part.indexOf("=");
      out[part.slice(0, i)] = part.slice(i + 1);
    });
    return out;
  }

  function fireKey(key, opts) {
    const event = Object.assign({
      key, target: body, shiftKey: false, metaKey: false, ctrlKey: false, altKey: false,
      preventDefault() {},
    }, opts || {});
    (winHandlers["keydown"] || []).slice().forEach((fn) => fn(event));
  }

  const inputEl = () => global.document.querySelectorAll(".fx-input")[0];
  function typeInInput(text) {
    const el = inputEl();
    el.value = text;
    el.fire("input");
  }
  function pressEnterInInput() {
    keyInInput("Enter");
  }
  // 真实浏览器里 keydown 会从 input 冒泡到 window：先元素监听器，再 window 监听器
  function keyInInput(key, opts) {
    const el = inputEl();
    const event = Object.assign({ key, target: el, shiftKey: false, metaKey: false,
                                  ctrlKey: false, altKey: false, preventDefault() {} }, opts || {});
    (el._listeners.keydown || []).slice().forEach((fn) => fn(event));
    (winHandlers["keydown"] || []).slice().forEach((fn) => fn(event));
  }

  return {
    roots, all, byClass, matchClass, state, fireKey, cellEl, textOf,
    cellText: (row, col) => textOf(cellEl(row, col)),
    inputEl, typeInInput, pressEnterInInput, keyInInput,
    windowKeyHandlerCount: () => (winHandlers.keydown || []).length,
    intervalCount: () => intervals.length,
    clickCell(row, col) {
      const el = cellEl(row, col);
      if (!el) return false;
      el.fire("click");
      return true;
    },
    chip(text) {
      return global.document.querySelectorAll(".chip").find((c) => String(c.textContent).includes(text));
    },
    clickChip(text) {
      const el = this.chip(text);
      if (!el) return false;
      el.fire("click");
      return true;
    },
    runTicks(n) { for (let i = 0; i < (n || 1); i += 1) intervals.slice().forEach((x) => x.fn()); },
    resizeGrid: (rows, cols) => global.sheetsTestApi.resizeGrid(rows, cols),
    unmountAll: () => global.sheetsTestApi.unmount(),
    nodesCreated: () => created,
    resetNodeCounter() { created = 0; },
    activeElement: () => global.document.activeElement,
  };
}

module.exports = { boot, APP };
