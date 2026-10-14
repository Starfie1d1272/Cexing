const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const { load } = require('./test-vpn-recovery.cjs');
function recoveryFixture(options = {}) {
  let marker = true, prepared = 0, current = true;
  const controller = load({ autoBind: true, ...options, onClear: () => { marker = false; } });
  const modules = { './VpnController': controller, './AppRuntime': { AppRuntime: { cancelRestore() {} } },
    './ProfileStore': { ProfileStore: { isApplyUncertain: () => marker } },
    './ProfileTransactions': { ProfileTransactions: { isBusy: () => false,
      ensureActiveSmartPolicy: async () => { assert.equal(marker, false, 'persistent uncertainty must be cleared by confirmed stop'); prepared++; } } } };
  const sandbox = { exports: {}, require: key => modules[key] ?? {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileRecovery.ets','utf8')).outputText, sandbox);
  return { controller, helper: sandbox.exports.ProfileRecovery, marker: () => marker, prepared: () => prepared,
    current: () => current, cancel: () => { current = false; } };
}
(async () => {
  const f = recoveryFixture();
  assert.equal(f.controller.VpnController.needsStop(), false);
  assert.equal(await f.helper.reconnect(f.controller.context, f.current), true);
  assert.equal(f.marker(), false); assert.equal(f.prepared(), 1);
  assert.ok(f.controller.calls.bind >= 1);
  assert.deepEqual([f.controller.calls.stop, f.controller.calls.start], [1, 1]);
  const failed = recoveryFixture({ cleanupFailed: true });
  await assert.rejects(failed.helper.reconnect(failed.controller.context, failed.current), /断开未确认/);
  assert.equal(failed.marker(), true); assert.equal(failed.prepared(), 0); assert.equal(failed.controller.calls.start, 0);
  const cancelled = recoveryFixture({ delayedCleanup: true });
  const old = cancelled.helper.reconnect(cancelled.controller.context, cancelled.current);
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(cancelled.helper.reconnect(cancelled.controller.context, cancelled.current), /稍后重试/);
  cancelled.cancel(); const request = cancelled.controller.cleanupRequests[0];
  request.resolve({errCode:0,reply:{readString:()=>request.request,readBoolean:()=>true}});
  assert.equal(await old, false); assert.equal(cancelled.controller.calls.start, 0);
  console.log('PASS: cold persistent unknown forces confirmed stop; failed cleanup, duplicate recovery and stale page cannot restart');
})().catch(error => { console.error(error); process.exitCode = 1; });
