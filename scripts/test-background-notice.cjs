const uiFixture = require('./ci/ui-fixtures.cjs');
// Actual feedback component methods; no claim about device rendering or screen readers.
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/pages/BackgroundNotice.ets', 'utf8');
const methods = (source.slice(0, source.indexOf('  build()')) + '\n}').split('\n')
  .map(line => line.trimStart().startsWith('@') ? line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line)
  .join('\n').replace('export struct ', 'export class ');
const home = fs.readFileSync('cexing/entry/src/main/ets/pages/HomePage.ets', 'utf8');
assert.match(home, /BackgroundNotice\(\{ status: this.status, visible: this.rootVisible && this.currentVisibleTab === 0 \}\)/);
assert.ok(home.indexOf('BackgroundNotice({') < home.indexOf("Button(this.status === VpnStatus.Disconnected"), 'Feedback stays in scroll area above the bottom connection action');
let state = { task: 'active', notification: 'ready', suspended: false }, observer, resolve, retries = 0, removed = 0;
const modules = { './NativeTheme': {}, '../lib/VpnController': { VpnStatus: { Connected: 2, Disconnected: 0 } },
  '../lib/LiveViewKeeper': { LiveViewKeeper: { needsAttention: s => s.task === 'failed' || s.task === 'revoked' || s.suspended || s.notification === 'failed' } },
  '../lib/AppRuntime': { AppRuntime: { backgroundState: () => state, onBackgroundChanged: fn => { observer = fn; return () => { removed++; }; },
    retryBackground: () => { retries++; return new Promise(done => { resolve = done; }); } } } };
const c = { exports: {}, require: key => key.endsWith('/UiText') ? uiFixture.module : modules[key] };
Object.assign(c, uiFixture.globals);
vm.runInNewContext(ts.transpileModule(methods).outputText, c);
(async () => {
  const page = new c.exports.BackgroundNotice(); page.status = 2; page.aboutToAppear();
  assert.equal(page.attention(), false);
  observer(state = { task: 'failed', notification: 'unknown', suspended: false }); assert.equal(page.attention(), true);
  const first = page.retry(); const oldFinish = resolve; await page.retry(); assert.equal(retries, 1, 'Repeated tap has one operation');
  page.visible = false; page.invalidate(); page.visible = true; page.invalidate();
  const second = page.retry(); const currentFinish = resolve; oldFinish(false); await first; assert.equal(page.busy, true, 'Old result cannot clear a newer retry'); currentFinish(true); await second; assert.equal(page.retryFailed, false);
  // The older unresolved result cannot overwrite new-page success or busy state.
  page.aboutToDisappear(); assert.equal(removed, 1); assert.equal(page.active, false);
  const other = new c.exports.BackgroundNotice(); other.status = 2; other.aboutToAppear();
  const retry = other.retry(); const finish = resolve; other.status = 0; other.invalidate(); finish(false); await retry;
  assert.equal(other.attention(), false); assert.equal(other.retryFailed, false);
  let cleared = 0; other.navStack = { clear() { cleared++; } }; other.settings(); assert.equal(cleared, 1); assert.equal(other.tabJump, 2);
  console.log('PASS: failure-only feedback, repeated retry, status/page invalidation, observer release and settings action');
})().catch(error => { console.error(error); process.exitCode = 1; });
