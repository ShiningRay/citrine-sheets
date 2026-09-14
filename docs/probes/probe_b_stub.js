// probe_b_stub.js — DOM 桩（照抄 examples/stub_check.js 的做法，加仪器化）
// 用法: node probe_b_stub.js
function makeEl(tag) {
  const el = {
    tagName: String(tag).toUpperCase(),
    textContent: "",
    value: "",
    checked: false,
    placeholder: "",
    className: "",
    style: {},
    children: [],
    parentElement: null,
    _listeners: {},
    appendChild(c) { c.parentElement = this; this.children.push(c); return c; },
    removeChild(c) { c.parentElement = null; this.children = this.children.filter((x) => x !== c); },
    addEventListener(ev, fn) {
      (this._listeners[ev] = this._listeners[ev] || []).push(fn);
      global.$listener_binds.push(this.tagName + ":" + ev);
    },
    fire(ev, event) { (this._listeners[ev] || []).forEach((fn) => fn(event || {})); },
  };
  global.$created.push(el);
  return el;
}

global.$created = [];
global.$listener_binds = [];
global.$create_calls = 0;
global.$intervals = [];
global.$cleared = [];

const app = makeEl("div");
global.window = global;
global.document = {
  getElementById: () => app,
  createElement: (t) => { global.$create_calls += 1; return makeEl(t); },
};
global.setInterval = function (fn, ms) { $intervals.push({ fn: fn, ms: ms }); return $intervals.length; };
global.clearInterval = function (id) { $cleared.push(id); };

global.walk = function (el) {
  return [el].concat(el.children.flatMap(function (c) { return walk(c); }));
};
global.byTag = function (root, tag) {
  return walk(root).filter((n) => n.tagName === String(tag).toUpperCase());
};
global.byClass = function (root, cls) {
  return walk(root).filter((n) => n.className === cls);
};
global.eventsOf = function (el) { return Object.keys(el._listeners).join(",") || "<无>"; };
global.dumpTree = function (el, depth) {
  depth = depth || 0;
  var out = "  ".repeat(depth) + "<" + el.tagName + " class=" + JSON.stringify(el.className) +
    "> ev=[" + eventsOf(el) + "] text=" + JSON.stringify(el.textContent) +
    (el.tagName === "INPUT" ? " value=" + JSON.stringify(el.value) + " checked=" + el.checked : "") + "\n";
  el.children.forEach(function (c) { out += dumpTree(c, depth + 1); });
  return out;
};

require("./probe_b_dom.js");
