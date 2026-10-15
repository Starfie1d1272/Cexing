const uiFixture = require('./ci/ui-fixtures.cjs');
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let source = fs.readFileSync('cexing/entry/src/main/ets/pages/SettingsReconnectButton.ets', 'utf8');
source = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n')
  .map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
let dialog, epoch = 1, calls = 0, finish;
const modules = { '../lib/Settings': { Settings: { onChanged() {}, offChanged() {} } }, '../lib/VpnController': { VpnController: { status: 2, settingsNeedReconnect: () => true, configurationEpoch: () => epoch, onChanged() {}, offChanged() {} }, VpnStatus: { Connected: 2 } },
  '../lib/ProfileStore': { ProfileStore: { getActiveFile: () => 'synthetic.yaml' } },
  '../lib/ProfileRecovery': { ProfileRecovery: { reconnect: async (_, current) => { calls++; await new Promise(resolve => { finish = resolve; }); return current(); } } },
  '@kit.ArkUI': { promptAction: { showToast() {} } } };
const sandbox = { exports: {}, require: key => key.endsWith('/UiText') ? uiFixture.module : modules[key] ?? {}, getContext: () => ({}), AlertDialog: { show: value => { dialog = value; } } };
Object.assign(sandbox, uiFixture.globals);
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
(async () => {
  const page = new sandbox.exports.SettingsReconnectButton(); page.navStack = { getAllPathName: () => [] }; page.aboutToAppear();
  page.canApply = false; page.confirm(); assert.equal(dialog, undefined, 'unsaved settings cannot reconnect');
  page.canApply = true; page.confirm(); const dirty = dialog; page.canApply = false;
  await dirty.secondaryButton.action(); assert.equal(calls, 0, 'settings changed while confirmation was open');
  page.canApply = true;
  page.confirm(); const first = dialog; page.confirm(); assert.equal(dialog, first);
  first.primaryButton.action(); assert.equal(calls, 0);
  page.confirm(); const old = dialog; epoch++; await old.secondaryButton.action(); assert.equal(calls, 0);
  page.confirm(); const tabOld = dialog; page.currentVisibleTab = 0; page.onVisibilityChanged();
  await tabOld.secondaryButton.action(); assert.equal(calls, 0, 'old tab confirmation cannot reconnect');
  page.currentVisibleTab = 2; page.onVisibilityChanged();
  page.confirm(); const running = dialog.secondaryButton.action(); assert.equal(calls, 1);
  await dialog.secondaryButton.action(); assert.equal(calls, 1, 'duplicate confirmation cannot stop twice');
  page.aboutToDisappear(); page.aboutToAppear(); finish(); await running;
  assert.equal(page.working, false, 'stale finally cannot leave a reentered button stuck');
  page.confirm(); const left = dialog; page.aboutToDisappear(); await left.secondaryButton.action(); assert.equal(calls, 1);
  console.log('PASS: reconnect interruption confirmation, cancel, duplicate tap, old session and page reentry');
})().catch(error => { console.error(error); process.exitCode = 1; });
