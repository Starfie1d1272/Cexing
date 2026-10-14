const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/SettingsPage.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  @Builder')) + '\n}')
  .split('\n').map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
  .join('\n').replace('export struct ', 'export class ');
let finishStart, sheet, fail = false, pendingIdle = Promise.resolve();
const saved = { keepAlive: true, autoUpdate: false, autoRestore: true, autoUpdateIntervalHours: 24, logToFile: true };
const toasts = [];
const modules = {
  '../lib/Settings': { Settings: { idle: () => pendingIdle, load: () => ({ ...saved }), save: (_, value) => {
    if (fail) throw Error('I/O'); Object.assign(saved, value);
  } } },
  '../lib/VpnController': { VpnController: { status: 2 }, VpnStatus: { Connected: 2 } },
  '../lib/LiveViewKeeper': { LiveViewKeeper: { start: () => new Promise(resolve => { finishStart = resolve; }), stop: async () => {} } },
  '@kit.ArkUI': { promptAction: { showToast: value => toasts.push(value.message) } }
};
const sandbox = { exports: {}, require: key => modules[key] ?? {}, getContext: () => ({}),
  ActionSheet: { show: value => { sheet = value; } } };
vm.runInNewContext(ts.transpileModule(methods).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.SettingsPage(); page.aboutToAppear(); await new Promise(resolve => setImmediate(resolve));
  const old = page.onKeepAliveChange(true); await new Promise(resolve => setImmediate(resolve)); await page.onKeepAliveChange(false); finishStart(true); await old;
  assert.equal(toasts.length, 0, 'old keepalive completion cannot report success after a newer disable');
  page.onIntervalTap(); const before = saved.autoUpdateIntervalHours; page.aboutToDisappear(); sheet.sheets[0].action();
  assert.equal(saved.autoUpdateIntervalHours, before, 'a stale sheet cannot save after navigation');
  page.aboutToAppear(); fail = true; await page.onLogToFileChange(false);
  assert.equal(page.logToFile, true); assert.equal(toasts.at(-1), '保存失败，请重试');
  let ready;
  pendingIdle = new Promise(resolve => { ready = resolve; });
  page.aboutToAppear(); assert.equal(page.ready, false);
  saved.autoUpdate = true; ready(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(page.ready, true); assert.equal(page.autoUpdate, true, 'reentry reloads confirmed values after pending writes');
  console.log('PASS: settings save failure, stale async keepalive feedback and cancelled/navigation sheet callbacks');
})().catch(error => { console.error(error); process.exitCode = 1; });
