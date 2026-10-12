"use strict";
// All content is synthetic. This prototype has no network, VPN or production storage access.
const params = new URLSearchParams(location.search);
document.documentElement.dataset.arkDepth =
  params.get("depth") === "moderate" ? "moderate" : "minimal";
const icons = {
  back: '<path d="m14 5-7 7 7 7"/>',
  right: '<path d="m9 5 7 7-7 7"/>',
  arrow: '<path d="M5 19 19 5M5 5h14v14"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  settings:
    '<path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="3" fill="var(--ark-paper)"/><circle cx="15" cy="17" r="3" fill="var(--ark-paper)"/>',
  file: '<path d="M7 3h7l4 4v14H7zM14 3v5h4M10 12h5M10 16h5"/>',
  link: '<path d="m9 15 6-6M8 17l-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0M16 7l1-1a4 4 0 0 1 6 6l-4 4a4 4 0 0 1-6 0"/>',
  clipboard: '<path d="M8 5H5v16h14V5h-3M9 3h6v4H9zM8 12h8M8 16h5"/>',
  panel:
    '<rect x="3" y="4" width="18" height="16" rx="1"/><path d="M3 9h18M10 9v11"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  up: '<path d="M12 20V4m-5 5 5-5 5 5"/>',
  down: '<path d="M12 4v16m-5-5 5 5 5-5"/>',
  wifi: '<path d="M3 8a14 14 0 0 1 18 0M6 12a9 9 0 0 1 12 0M9 16a4 4 0 0 1 6 0"/><circle cx="12" cy="20" r=".5"/>',
  signal: '<path d="M4 20v-4M9 20v-8M14 20V8M19 20V4"/>',
  refresh:
    '<path d="M20 6v5h-5M4 18v-5h5M5 8a8 8 0 0 1 14-2M19 16a8 8 0 0 1-14 2"/>',
  empty: '<path d="M5 3h11l4 4v14H5zM16 3v5h4M9 12h7M9 16h4"/>',
};
const svg = (name) =>
  `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.right}</svg>`;
const esc = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const state = {
  page: "home",
  profile: false,
  source: "url",
  name: "示例订阅",
  override: "none",
  vpn: "idle",
  granted: false,
  sheet: "",
  error: "",
  update: "",
  updated: "今天 09:41",
  diagnostic: false,
  formUrl: "",
  formName: "",
  formError: "",
  importError: false,
  networkError: false,
  keepAlive: true,
  autoRestore: false,
  autoUpdate: false,
  interval: "24",
  packages: "",
  ipv6: false,
  log: true,
  access: "全部应用",
  port: "7890",
  level: "info",
  mergeText: "log-level: warning",
  lan: false,
  stack: [],
};
let operation = 0;
let vpnOperation = 0;
let returnFocus = null;
let toastTimer;
const app = document.getElementById("app");
function toast(msg) {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}
function go(page) {
  state.stack.push(state.page);
  state.page = page;
  state.sheet = "";
  state.formError = "";
  render(true);
}
function back() {
  if (state.sheet) {
    closeSheet();
    return;
  }
  state.page = state.stack.pop() || "home";
  render(true);
}
function openSheet(sheet) {
  returnFocus = document.activeElement;
  state.sheet = sheet;
  render();
}
function closeSheet() {
  state.sheet = "";
  render();
  if (returnFocus?.dataset.action) {
    app.querySelector(`[data-action="${returnFocus.dataset.action}"]`)?.focus();
  }
}
function button(label, action, kind = "primary", disabled = false) {
  return `<button class="${kind}" data-action="${action}" ${disabled ? "disabled" : ""}>${label}</button>`;
}
function row(title, sub, action, icon = "", tail = "") {
  return `<button class="row" data-action="${action}">${icon ? svg(icon) : ""}<span class="copy"><strong>${title}</strong>${sub ? `<small>${sub}</small>` : ""}</span>${tail ? `<span class="tail">${tail}</span>` : ""}${svg("right").replace("<svg ", '<svg class="chevron" ')}</button>`;
}
function toggle(title, sub, key) {
  return `<div class="row"><span class="copy"><strong>${title}</strong>${sub ? `<small>${sub}</small>` : ""}</span><span class="switchwrap"><button class="switch ${state[key] ? "on" : ""}" data-toggle="${key}" role="switch" aria-checked="${state[key]}" aria-label="${title}"></button></span></div>`;
}
function fact(key, value) {
  return `<div class="fact"><span class="key">${key}</span><span>${value}</span></div>`;
}
function footer(content, note = "") {
  return `<footer class="footer">${note ? `<p class="quiet">${note}</p>` : ""}${content}</footer>`;
}
function nav() {
  const titles = {
    home: "连接",
    import: "添加订阅",
    review: "确认订阅",
    profiles: "订阅",
    profile: "订阅详情",
    overrides: "覆写",
    merge: "Merge YAML",
    settings: "设置",
    network: "网络设置",
    kernel: "内核设置",
    diagnostics: "诊断",
    panel: "Zashboard",
  };
  return `<div class="statusbar" aria-hidden="true"><span>09:41</span><span class="system">${svg("signal")}${svg("wifi")}<span class="battery"></span></span></div><header class="topbar">${state.page === "home" ? `<div class="brand">连接<span class="prototype">交互原型</span></div><button class="icon" data-action="settings" aria-label="设置">${svg("settings")}</button>` : `<div class="title"><button class="icon back" data-action="back" aria-label="返回">${svg("back")}</button><span>${titles[state.page]}</span></div>${state.page === "profiles" ? `<button class="linkbutton" data-action="importMenu">添加</button>` : ""}`}</header>`;
}
function home() {
  if (!state.profile)
    return `<main class="body"><section class="intro"><p class="eyebrow">从一份订阅开始</p><h1>导入订阅，<br>开始连接。</h1><p>链接、YAML 文件或剪贴板。</p></section><div class="import-options">${row("订阅链接", "使用服务提供方的 URL", "url", "link")}${row("配置文件", "导入 YAML 文件", "file", "file")}${row("剪贴板", "粘贴链接或配置内容", "clipboard", "clipboard")}</div></main>${footer(button("添加订阅", "importMenu"))}`;
  const connecting = state.vpn === "connecting",
    connected = state.vpn === "connected",
    stopping = state.vpn === "disconnecting",
    error = state.vpn === "error";
  const label = connected
    ? "已连接"
    : connecting
      ? "连接中"
      : stopping
        ? "断开中"
        : error
          ? "连接中断"
          : "未连接";
  const caption = connected
    ? "内核已就绪"
    : connecting
      ? "等待内核就绪"
      : stopping
        ? "正在释放系统隧道"
        : error
          ? "网络不可用"
          : "订阅已准备就绪";
  return `<main class="body"><section class="hero" aria-label="连接状态"><p class="eyebrow">VPN / 系统连接</p><h1>${label}</h1><p class="state">${connecting || stopping ? '<span class="spinner" aria-hidden="true"></span>' : `<span class="dot ${connected ? "" : "idle"}" aria-hidden="true"></span>`}${caption}</p><div class="summary"><span>${connected ? "会话运行中" : "等待连接"}</span><span>${connected ? "Wi-Fi" : "系统 VPN"}</span></div></section>${error ? `<div class="notice" role="alert"><strong>暂时无法连接网络</strong><p>网络恢复后可重试。</p><button class="linkbutton" data-action="diagnostics">查看诊断 ${svg("right")}</button></div>` : ""}${connected ? `<div class="traffic" aria-label="实时速率"><div><p class="rate"><span data-rate="up">128</span> <span class="unit">${connected ? "KB/s" : ""}</span></p><p class="label">${svg("up")}上传</p></div><div><p class="rate"><span data-rate="down">2.4</span> <span class="unit">${connected ? "MB/s" : ""}</span></p><p class="label">${svg("down")}下载</p></div></div>` : `<p class="quiet idle-traffic">连接后显示实时速率</p>`}<div class="sectionlabel"><span>当前订阅</span><button class="inline linkbutton" data-action="profiles">管理</button></div>${row(esc(state.name), `${state.source === "url" ? "URL 订阅" : "本地配置"} · ${state.updated}`, "profile", "", state.override === "merge" ? "已覆写" : "原始配置")}<button class="handoff" data-action="panel" ${!connected ? "disabled" : ""}>${svg("panel")}<span class="copy"><strong>打开 Zashboard</strong><small>节点 · 策略组 · 规则 · 日志</small></span>${svg("arrow")}</button>${!connected ? '<p class="quiet" style="margin-top:10px">连接后可打开面板</p>' : ""}</main>${footer(button(connected ? "断开连接" : connecting ? "取消连接" : stopping ? "正在断开…" : error ? "重新连接" : "连接 VPN", "vpn", "primary", stopping))}`;
}
function importPage() {
  return `<main class="body subpage"><p class="eyebrow">导入订阅</p><h1>添加一份配置</h1><p class="lead">${state.source === "url" ? "使用完整 Mihomo 订阅链接。" : "粘贴完整 YAML 配置。"}</p><label class="field">名称<input id="name" maxlength="32" value="${esc(state.formName)}" placeholder="例如：日常订阅" autocomplete="off"></label>${state.source === "yaml" ? '<label class="field">配置内容<textarea id="yaml" placeholder="proxies: …"></textarea></label>' : `<label class="field">订阅链接<input id="url" type="url" value="${esc(state.formUrl)}" placeholder="https://example.com/sub.yaml" inputmode="url" autocomplete="off" spellcheck="false"></label>`}${state.formError ? `<p class="field-error" role="alert">${esc(state.formError)}</p>` : ""}${state.importError ? '<div class="notice" role="alert"><strong>下载失败</strong><p>网络连接超时，链接和名称已保留。</p></div>' : ""}<button class="linkbutton" data-action="demoFill">填入示例 ${svg("right")}</button><details class="detailnote"><summary>支持什么格式？</summary><p>完整 Mihomo YAML 或订阅 YAML。剪贴板不可读取时，可手动粘贴。此交互原型使用合成内容演示，不请求订阅服务。</p></details></main>${footer(button(state.update === "import" ? "正在导入…" : state.importError ? "重新导入" : "继续", "importContinue", "primary", state.update === "import"))}`;
}
function review() {
  return `<main class="body subpage"><div class="step"><span>1 导入</span><span class="active">2 确认</span></div><h1>订阅已准备好</h1><div class="reviewname"><strong>${esc(state.formName || "示例订阅")}</strong><small>${state.source === "url" ? "example.com · URL 订阅" : "本地 YAML 配置"}</small></div>${fact("配置检查", "演示通过")}${row("覆写", state.override === "merge" ? "Merge YAML · 更新时重新应用" : "保留原始配置，可稍后设置", "overrides", "", state.override === "merge" ? "已选择" : "不使用")}<details class="detailnote"><summary>启用时会做什么？</summary><p>目标流程会校验配置，并保留系统 TUN、控制面认证和回环约束。合成示例仅用于原型；完整校验与事务回退待实现。</p></details></main>${footer(button("启用订阅", "activate"), "启用后仍需手动连接 VPN")}`;
}
function profiles() {
  return `<main class="body subpage"><h1>你的订阅</h1><p class="lead">${state.profile ? "1 份配置" : "还没有配置"}</p><div style="margin-top:28px">${state.profile ? row(esc(state.name), `${state.source === "url" ? "URL 订阅" : "本地配置"} · 当前使用`, "profile", "file", "已启用") : ""}</div><div class="detailnote">${row("添加订阅", "链接、文件或剪贴板", "importMenu", "link")}</div></main>`;
}
function profile() {
  return `<main class="body subpage"><p class="eyebrow">当前使用</p><h1>${esc(state.name)}</h1><div class="facts">${fact("来源", state.source === "url" ? "example.com · URL 订阅" : "本地文件")}${fact("最近更新", state.updated)}${state.source === "url" ? fact("订阅用量", "12.8 / 100 GB") : ""}</div>${state.update === "error" ? '<div class="notice" role="alert"><strong>更新失败</strong><p>网络超时，仍使用上一份配置。</p><button class="linkbutton" data-action="update">重试更新</button></div>' : ""}<div class="sectionlabel"><span>配置</span></div>${row("覆写", state.override === "merge" ? "Merge YAML" : "保留订阅原始配置", "overrides", "", state.override === "merge" ? "已开启" : "未使用")}${row("重命名", "", "rename")}${row("导出配置", "", "export")}${row("删除订阅", "", "delete")}<details class="detailnote"><summary>更新如何生效？</summary><p>目标方案：重新应用覆写、校验后热加载；失败保留上一份有效配置。源码当前的下载和热加载尚未统一为事务。</p></details></main>${state.source === "url" ? footer(button(state.update === "loading" ? "正在更新…" : "更新订阅", "update", "primary", state.update === "loading")) : ""}`;
}
function overrides() {
  return `<main class="body subpage"><p class="eyebrow">作用于当前订阅</p><h1>订阅覆写</h1><p class="lead" style="margin-top:16px">订阅更新后，重新应用同一份覆写。</p><div style="margin-top:25px"><label class="selectrow"><input type="radio" name="override" value="none" ${state.override === "none" ? "checked" : ""}><span>不使用覆写<small>保留订阅原始配置</small></span></label><label class="selectrow"><input type="radio" name="override" value="merge" ${state.override === "merge" ? "checked" : ""}><span>Merge YAML <span class="pill">方案预览</span><small>单独保存覆写，不改写原始订阅</small></span></label></div>${state.override === "merge" ? row("编辑 Merge YAML", "查看合成示例与差异", "merge") : ""}<div class="sectionlabel"><span>宿主参数</span></div>${row("内核设置", "端口 · 日志等级 · 局域网", "kernel")}<details class="detailnote"><summary>覆写边界</summary><p>系统 TUN 与控制面字段由宿主管理。Merge、完整校验和更新回退属于待实现方案；当前源码支持的是内核参数覆写，不执行 JS 或 Shell 脚本。</p></details></main>${footer(button("完成", "overrideDone"))}`;
}
function merge() {
  return `<main class="body subpage"><p class="eyebrow">方案预览</p><h1>Merge YAML</h1><label class="field">覆写内容<textarea id="merge" spellcheck="false">${esc(state.mergeText)}</textarea></label><div class="facts">${fact("影响范围", "日志等级")}${fact("系统字段", "宿主管理")}</div><button class="linkbutton" data-action="diff">查看差异 ${svg("right")}</button></main>${footer(button("保存覆写", "mergeSave"))}`;
}
function settings() {
  return `<main class="body subpage"><h1>设置</h1><div class="sectionlabel"><span>运行</span></div>${toggle("后台运行", "关闭页面后保持会话", "keepAlive")}${toggle("打开应用自动恢复", "", "autoRestore")}<div class="sectionlabel"><span>系统与连接</span></div>${row("网络设置", "IPv6 · 按应用分流", "network")}${row("内核设置", "端口 · 日志等级 · 局域网", "kernel")}<div class="sectionlabel"><span>订阅</span></div>${toggle("自动更新", `VPN 运行期间，每 ${state.interval} 小时检查`, "autoUpdate")}${state.autoUpdate ? `<div class="row"><span class="copy"><strong>更新间隔</strong></span><select id="interval" aria-label="更新间隔">${["12", "24", "48", "72"].map((x) => `<option value="${x}" ${state.interval === x ? "selected" : ""}>${x} 小时</option>`).join("")}</select></div>` : ""}<div class="sectionlabel"><span>排查问题</span></div>${row("诊断", "系统 VPN、内核与控制面状态", "diagnostics")}${toggle("记录内核日志", "下次启动内核生效", "log")}</main>`;
}
function network() {
  return `<main class="body subpage"><h1>网络设置</h1><p class="lead">更改后，下次启动 VPN 生效。</p><div style="margin-top:28px">${toggle("IPv6", "接管 IPv6 流量", "ipv6")}${row("按应用分流", "本应用自身始终直连", "access", "", esc(state.access))}</div>${state.access !== "全部应用" ? `<label class="field">应用包名<textarea id="packages" placeholder="com.example.app\n每行一个包名">${esc(state.packages)}</textarea></label><p class="quiet" style="margin-top:12px">手动填写包名，系统不允许枚举应用列表。</p>` : ""}</main>${footer(button("保存", "networkSave"))}`;
}
function kernel() {
  return `<main class="body subpage"><h1>内核设置</h1><p class="lead">更改后，下次启动 VPN 生效。</p><label class="field">混合代理端口<input id="port" type="number" min="1" max="65535" value="${esc(state.port)}" inputmode="numeric"></label><label class="field">日志等级<select id="level">${["silent", "error", "warning", "info", "debug"].map((x) => `<option ${state.level === x ? "selected" : ""}>${x}</option>`).join("")}</select></label>${toggle("允许局域网连接", "", "lan")}${state.formError ? `<p class="field-error" role="alert">${state.formError}</p>` : ""}</main>${footer(button("保存", "kernelSave"))}`;
}
function diagnostics() {
  return `<main class="body subpage"><p class="eyebrow">${state.diagnostic ? "检查完成" : "分开检查，不合并推断"}</p><h1>连接诊断</h1><div class="diagnostic">${fact("系统 VPN", state.vpn === "connected" ? "会话已建立" : "未连接")}${fact("内核", state.vpn === "connected" ? "已就绪" : state.vpn === "error" ? "连接中断" : "未运行")}${fact("控制面", state.vpn === "connected" ? "可访问" : "不可访问")}${fact("网络验证", state.diagnostic ? (state.networkError ? "网络不可用" : "尚需真实转发验证") : "未检查")}</div><p class="quiet">内核就绪不等于网络可用。</p>${state.networkError ? '<div class="notice"><strong>检查 Wi-Fi 或移动网络</strong><p>网络恢复后返回连接页重试。</p></div>' : ""}<div style="margin-top:24px">${row("分享诊断摘要", "仅包含状态，不包含订阅链接或密钥", "share")}${row("内核日志", "在 Zashboard 中查看", "panel", "", state.vpn === "connected" ? "" : "需连接")}</div><details class="detailnote"><summary>这次检查覆盖什么？</summary><p>这里演示分层诊断界面；系统会话探测、真实转发验证和安全分享摘要待实现。业务规则与连接日志交给 Zashboard。</p></details></main>${footer(button("重新检查", "diagnose"))}`;
}
function panel() {
  return `<main class="body subpage"><p class="eyebrow">原生 → WEB 面板</p><h1>Zashboard</h1><div class="panelplaceholder">${svg("panel")}<h2>${state.error === "panel" ? "面板暂时无法打开" : "面板接入预览"}</h2><p>${state.error === "panel" ? "VPN 保持连接，可以重新打开。" : "此处将嵌入离线 Zashboard。节点、策略组、Smart、连接、规则和日志由面板管理。"}</p></div><div class="facts">${fact("VPN 会话", state.vpn === "connected" ? "保持连接" : "未连接")}${fact("资源来源", "本地离线资源（待接入）")}</div><button class="linkbutton" data-action="panelRetry">${state.error === "panel" ? "重新打开" : "演示面板加载失败"} ${svg("right")}</button></main>${footer(button("返回连接页", "home"))}`;
}
function sheet() {
  const s = state.sheet;
  if (!s) return "";
  let content = "";
  if (s === "permission")
    return `<div class="overlay"><section class="system-dialog" role="dialog" aria-modal="true" aria-labelledby="dialog-title"><p class="systemtag">系统授权 · 示意</p><h2 id="dialog-title">允许建立 VPN 连接？</h2><p>授权后，应用可通过系统 VPN 接管网络流量。</p><div class="two">${button("暂不允许", "deny", "secondary")}${button("允许", "allow")}</div></section></div>`;
  if (s === "import")
    content = `${row("订阅链接", "输入 URL", "url", "link")}${row("配置文件", "选择 YAML 文件", "file", "file")}${row("剪贴板", "粘贴链接或配置", "clipboard", "clipboard")}`;
  if (s === "file")
    content = `<p class="quiet">选择本地 YAML，或使用合成示例继续体验。</p><label class="field">配置文件<input id="file" type="file" accept=".yaml,.yml,text/yaml"></label>${button("使用示例文件", "demoFile")}`;
  if (s === "clipboard")
    content = `<p class="quiet">无法自动读取时，可在下一页手动粘贴。</p>${button("粘贴订阅链接", "pasteUrl")}${button("粘贴 YAML 内容", "pasteYaml", "secondary")}`;
  if (s === "rename")
    content = `<label class="field">名称<input id="rename" maxlength="32" value="${esc(state.name)}"></label>${button("保存名称", "renameSave")}`;
  if (s === "delete")
    content = `<p class="quiet">${state.vpn !== "idle" ? "先断开 VPN，再删除当前订阅。" : "删除后需重新导入。"}</p>${button(state.vpn !== "idle" ? "断开并删除" : "删除订阅", "deleteConfirm")}`;
  if (s === "disconnect")
    content = `<p class="quiet">所有由系统 VPN 接管的连接将断开。</p>${button("断开连接", "disconnectConfirm")}${button("继续保持连接", "close", "secondary")}`;
  if (s === "access")
    content = ["全部应用", "仅代理名单内应用", "绕过名单内应用"]
      .map(
        (x) =>
          `<button class="row" data-access="${x}"><span class="copy"><strong>${x}</strong></span>${state.access === x ? svg("check") : ""}</button>`,
      )
      .join("");
  if (s === "diff")
    content = `<p class="quiet">仅展示覆写草稿，不执行 YAML 合并。</p>${fact("原始配置", "log-level: info")}${fact("覆写草稿", esc(state.mergeText))}${button("返回编辑", "close")}`;
  const titles = {
    import: "添加订阅",
    file: "导入配置文件",
    clipboard: "从剪贴板导入",
    rename: "重命名",
    delete: "删除订阅？",
    disconnect: "断开 VPN？",
    access: "按应用分流",
    diff: "差异预览",
  };
  return `<div class="overlay" data-overlay><section class="sheet" role="dialog" aria-modal="true" aria-labelledby="dialog-title"><div class="handle" aria-hidden="true"></div><div class="sheetheader"><h2 id="dialog-title">${titles[s]}</h2><button class="icon" data-action="close" aria-label="关闭">${svg("close")}</button></div>${content}</section></div>`;
}
function render(moveFocus = false) {
  const oldModal = app.querySelector('[role="dialog"]');
  const pages = {
    home,
    import: importPage,
    review,
    profiles,
    profile,
    overrides,
    merge,
    settings,
    network,
    kernel,
    diagnostics,
    panel,
  };
  app.innerHTML = nav() + pages[state.page]() + sheet();
  if (state.sheet) {
    app.querySelector("main")?.setAttribute("inert", "");
    app.querySelector("header")?.setAttribute("inert", "");
    app.querySelector("footer")?.setAttribute("inert", "");
    if (!oldModal)
      requestAnimationFrame(() =>
        app.querySelector('[role="dialog"] button')?.focus(),
      );
  } else if (moveFocus) {
    window.scrollTo(0, 0);
    const heading = app.querySelector("h1");
    if (heading) {
      heading.tabIndex = -1;
      heading.focus({ preventScroll: true });
    }
  }
}
function start() {
  state.sheet = "";
  state.error = "";
  state.vpn = "connecting";
  const id = ++vpnOperation;
  render();
  setTimeout(() => {
    if (id !== vpnOperation) return;
    state.vpn = state.networkError ? "error" : "connected";
    render();
  }, 1500);
}
function stop(after) {
  ++vpnOperation;
  state.sheet = "";
  state.vpn = "disconnecting";
  render();
  const id = vpnOperation;
  setTimeout(() => {
    if (id !== vpnOperation) return;
    state.vpn = "idle";
    if (after) after();
    render();
  }, 700);
}
async function action(a) {
  if (
    [
      "settings",
      "profiles",
      "profile",
      "overrides",
      "merge",
      "network",
      "kernel",
      "diagnostics",
    ].includes(a)
  ) {
    go(a);
    return;
  }
  if (a === "back") {
    back();
    return;
  }
  if (a === "close") {
    closeSheet();
    return;
  }
  if (a === "home") {
    state.page = "home";
    state.stack = [];
    render(true);
    return;
  }
  if (a === "importMenu") {
    openSheet("import");
    return;
  }
  if (a === "url") {
    state.source = "url";
    state.formUrl = "";
    state.formName = "";
    state.importError = false;
    go("import");
    return;
  }
  if (a === "file") {
    openSheet("file");
    return;
  }
  if (a === "clipboard") {
    openSheet("clipboard");
    return;
  }
  if (a === "demoFile") {
    state.source = "file";
    state.formName = "本地示例";
    go("review");
    return;
  }
  if (a === "pasteUrl" || a === "pasteYaml") {
    state.source = a === "pasteUrl" ? "url" : "yaml";
    go("import");
    toast("请在输入框中手动粘贴");
    return;
  }
  if (a === "demoFill") {
    state.formName = "示例订阅";
    state.formUrl = "https://example.com/sub.yaml";
    render();
    if (state.source === "yaml")
      document.getElementById("yaml").value =
        "proxies: []\nproxy-groups: []\nrules: []";
    return;
  }
  if (a === "importContinue") {
    state.formName = document.getElementById("name").value.trim();
    state.formUrl = document.getElementById("url")?.value.trim() || "";
    const yaml = document.getElementById("yaml")?.value || "";
    if (
      state.source === "url" &&
      !/^https?:\/\/[^\s/]+(?:\/[^\s]*)?$/.test(state.formUrl)
    ) {
      state.formError = "请输入完整的 http 或 https 链接";
      render();
      return;
    }
    if (
      state.source === "yaml" &&
      !/(proxies|proxy-providers|proxy-groups):/.test(yaml)
    ) {
      state.formError = "请粘贴完整 Mihomo YAML 配置";
      render();
      return;
    }
    state.formError = "";
    state.update = "import";
    render();
    const id = ++operation;
    setTimeout(() => {
      if (id !== operation) return;
      state.update = "";
      if (state.networkError) {
        state.importError = true;
        render();
        return;
      }
      state.importError = false;
      go("review");
    }, 900);
    return;
  }
  if (a === "activate") {
    state.profile = true;
    state.name = state.formName || "示例订阅";
    state.page = "home";
    state.stack = [];
    render(true);
    toast("订阅已启用");
    return;
  }
  if (a === "overrideDone") {
    back();
    return;
  }
  if (a === "mergeSave") {
    state.mergeText = document.getElementById("merge").value;
    back();
    toast("演示覆写已保存");
    return;
  }
  if (a === "diff") {
    state.mergeText = document.getElementById("merge").value;
    openSheet("diff");
    return;
  }
  if (a === "vpn") {
    if (state.vpn === "connected") {
      openSheet("disconnect");
      return;
    }
    if (state.vpn === "connecting") {
      ++vpnOperation;
      state.vpn = "idle";
      render();
      toast("已取消连接");
      return;
    }
    if (!state.granted) {
      openSheet("permission");
      return;
    }
    start();
    return;
  }
  if (a === "allow") {
    state.granted = true;
    start();
    return;
  }
  if (a === "deny") {
    closeSheet();
    toast("未获授权，可再次连接");
    return;
  }
  if (a === "disconnectConfirm") {
    stop();
    return;
  }
  if (a === "update") {
    state.update = "loading";
    render();
    const id = ++operation;
    setTimeout(() => {
      if (id !== operation) return;
      if (state.networkError) {
        state.update = "error";
        render();
        return;
      }
      state.update = "";
      state.updated = "刚刚";
      render();
      toast("订阅已更新");
    }, 1000);
    return;
  }
  if (a === "rename") {
    openSheet("rename");
    return;
  }
  if (a === "renameSave") {
    const name = document.getElementById("rename").value.trim();
    if (!name) {
      toast("名称不能为空");
      return;
    }
    state.name = name;
    closeSheet();
    toast("名称已保存");
    return;
  }
  if (a === "delete") {
    openSheet("delete");
    return;
  }
  if (a === "deleteConfirm") {
    const done = () => {
      state.profile = false;
      state.override = "none";
      state.page = "home";
      state.stack = [];
    };
    if (state.vpn !== "idle") {
      stop(done);
    } else {
      done();
      closeSheet();
    }
    return;
  }
  if (a === "export") {
    const blob = new Blob(
      [
        "# Synthetic prototype fixture\nproxies: []\nproxy-groups: []\nrules: []\n",
      ],
      { type: "text/yaml" },
    );
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "prototype-example.yaml";
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    toast("已导出合成示例");
    return;
  }
  if (a === "access") {
    openSheet("access");
    return;
  }
  if (a === "networkSave") {
    state.packages = document.getElementById("packages")?.value || "";
    back();
    toast("已保存，下次启动 VPN 生效");
    return;
  }
  if (a === "kernelSave") {
    const p = Number(document.getElementById("port").value);
    if (!Number.isInteger(p) || p < 1 || p > 65535) {
      state.formError = "端口须为 1–65535 的整数";
      render();
      return;
    }
    state.port = String(p);
    state.level = document.getElementById("level").value;
    back();
    toast("已保存，下次启动 VPN 生效");
    return;
  }
  if (a === "diagnose") {
    state.diagnostic = true;
    render();
    toast("演示检查已完成");
    return;
  }
  if (a === "share") {
    const summary = `交互原型 · 合成诊断\n系统 VPN：${state.vpn === "connected" ? "会话已建立" : "未连接"}\n内核：${state.vpn === "connected" ? "已就绪" : "未运行"}\n真实转发：未验证\n`;
    const blob = new Blob([summary], { type: "text/plain" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "diagnostic-example.txt";
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
    toast("已导出不含凭据的演示摘要");
    return;
  }
  if (a === "panel") {
    if (state.vpn !== "connected") {
      toast("请先连接 VPN");
      return;
    }
    go("panel");
    return;
  }
  if (a === "panelRetry") {
    state.error = state.error === "panel" ? "" : "panel";
    render();
    return;
  }
}
app.addEventListener("click", (e) => {
  const control = e.target.closest("[data-action]");
  if (control) {
    action(control.dataset.action);
    return;
  }
  const toggleButton = e.target.closest("[data-toggle]");
  if (toggleButton) {
    state[toggleButton.dataset.toggle] = !state[toggleButton.dataset.toggle];
    toggleButton.classList.toggle("on");
    toggleButton.setAttribute(
      "aria-checked",
      state[toggleButton.dataset.toggle],
    );
    if (toggleButton.dataset.toggle === "autoUpdate") render();
    return;
  }
  const access = e.target.closest("[data-access]");
  if (access) {
    state.access = access.dataset.access;
    closeSheet();
  }
  if (e.target.matches("[data-overlay]")) closeSheet();
});
app.addEventListener("change", async (e) => {
  if (e.target.id === "interval") {
    state.interval = e.target.value;
    render();
  }
  if (e.target.name === "override") {
    state.override = e.target.value;
    render();
  }
  if (e.target.id === "file") {
    const file = e.target.files[0];
    if (!file) return;
    if (file.size > 32 * 1024 * 1024) {
      toast("配置文件超过 32MB");
      return;
    }
    const content = await file.text();
    if (!/(proxies|proxy-providers|proxy-groups):/.test(content)) {
      toast("请选择完整 Mihomo YAML 文件");
      return;
    }
    state.source = "file";
    state.formName = file.name.replace(/\.ya?ml$/i, "");
    go("review");
  }
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    back();
    return;
  }
  if (e.key === "Tab" && state.sheet) {
    const nodes = [
      ...app.querySelectorAll(
        '[role="dialog"] button,[role="dialog"] input,[role="dialog"] textarea',
      ),
    ].filter((x) => !x.disabled);
    const first = nodes[0],
      last = nodes.at(-1);
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last?.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first?.focus();
    }
  }
});
// Deterministic, memory-only QA entry. No persistent save or deletion occurs.
const scenario = params.get("state") || "empty";
if (scenario !== "empty") {
  state.profile = true;
  state.granted = true;
}
if (
  [
    "connected",
    "network-error",
    "panel",
    "panel-error",
    "diagnostics",
    "settings",
  ].includes(scenario)
)
  state.vpn = "connected";
if (scenario === "permission") {
  state.granted = false;
  state.sheet = "permission";
}
if (scenario === "connecting") state.vpn = "connecting";
if (scenario === "network-error") {
  state.vpn = "error";
  state.networkError = true;
}
if (scenario === "import-error") {
  state.page = "import";
  state.profile = false;
  state.formUrl = "https://example.com/sub.yaml";
  state.formName = "示例订阅";
  state.importError = true;
}
if (
  ["review", "overrides", "settings", "diagnostics", "profile"].includes(
    scenario,
  )
)
  state.page = scenario;
if (scenario === "review") {
  state.formName = "示例订阅";
  state.profile = false;
}
if (scenario === "overrides") state.override = "merge";
if (scenario === "update-error") {
  state.page = "profile";
  state.update = "error";
}
if (scenario === "panel" || scenario === "panel-error") {
  state.page = "panel";
  if (scenario === "panel-error") state.error = "panel";
}
if (scenario === "disconnect") {
  state.vpn = "connected";
  state.sheet = "disconnect";
}
window.prototypeQA = {
  setNetworkError(value) {
    state.networkError = !!value;
  },
  state: () => ({ ...state, stack: [...state.stack] }),
};
render();

// A visible synthetic stream for normal walkthroughs; screenshot scenarios freeze samples.
let sampleIndex = 0;
setInterval(() => {
  if (state.vpn !== "connected" || params.has("state")) return;
  const samples = [
    [128, "2.4"],
    [144, "1.8"],
    [96, "3.1"],
    [112, "2.2"],
  ];
  const sample = samples[sampleIndex++ % samples.length];
  const up = app.querySelector('[data-rate="up"]');
  const down = app.querySelector('[data-rate="down"]');
  if (up) up.textContent = sample[0];
  if (down) down.textContent = sample[1];
}, 1600);
