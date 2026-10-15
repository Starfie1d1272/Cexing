const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const code = ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets', 'utf8')).outputText;
function fixture(disk = new Map()) {
  const cache = new Map(disk);
  let puts = 0, flushes = 0, policy = {}, delayed = null;
  const p = {
    getSync: (key, fallback) => cache.has(key) ? cache.get(key) : fallback,
    putSync(key, value) {
      puts++;
      if (puts === policy.put || (policy.persistentPut && puts >= policy.put)) throw Error('put failure');
      cache.set(key, value);
    },
    flushSync() {
      flushes++;
      if (flushes === policy.flush || (policy.persistentFlush && flushes >= policy.flush)) throw Error('flush failure');
      disk.clear(); for (const [key, value] of cache) disk.set(key,value);
    },
    async flush() { if (delayed) { const gate = delayed; delayed = null; await gate; } this.flushSync(); }
  };
  const sandbox = {exports: {}, require: key => key === '@kit.ArkData' ?
    {preferences: {getPreferencesSync: () => p}} : key === './Logger' ? {Logger: {error() {}}} : {}};
  vm.runInNewContext(code, sandbox);
  return { hold() { let release; delayed = new Promise(resolve => { release = resolve; }); return release; }, settings: sandbox.exports.Settings, cache, disk,
    fail(value) { puts = 0; flushes = 0; policy = value; },
    cold() { return fixture(disk).settings.load({}).allowLan; }};
}
(async () => {
let f = fixture();
assert.equal(f.settings.load({}).allowLan,false);
f.cache.set('allowLan',true);
assert.equal(f.settings.load({}).allowLan,false,'legacy true is not consent');
await f.settings.save({},f.settings.load({}), ['ipv6']);
assert.equal(f.cold(),false);
await f.settings.setAllowLan({},true);
assert.equal(f.cold(),true);
await f.settings.save({},f.settings.load({}), ['ipv6']);
assert.equal(f.cold(),true);
// Every enable write and flush stage, with one-shot and continuing failure.
for (const kind of ['put','flush']) for (const stage of kind === 'put' ? [1,14,15,16,17] : [1,2,3]) for (const persistent of [false,true]) {
  f = fixture();
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  await assert.rejects(() => f.settings.setAllowLan({},true));
  assert.equal(f.settings.load({}).allowLan,false, `enable ${kind}/${stage}/${persistent}`);
  assert.equal(f.cold(),false,'failed enable cannot invent a durable grant in this precommit failure fixture');
  f.fail({}); await f.settings.setAllowLan({},true);
  assert.equal(f.settings.load({}).allowLan,true);
  assert.equal(f.cold(),true);
}
// Durable previous consent must remain visibly possible after failed revocation.
// A new VM represents the app or VPN Extension with a distinct Preferences cache.
for (const kind of ['put','flush']) for (const stage of kind === 'put' ? [1,14,15,16] : [1]) for (const persistent of [false,true]) {
  f = fixture(); await f.settings.setAllowLan({},true);
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  await assert.rejects(() => f.settings.setAllowLan({},false));
  assert.equal(f.settings.load({}).allowLan,true, `failed revoke ${kind}/${stage}/${persistent} must show prior consent`);
  assert.equal(f.cold(),true,'extension/new process still sees old durable consent');
  f.fail({}); await f.settings.setAllowLan({},false);
  assert.equal(f.settings.load({}).allowLan,false);
  assert.equal(f.cold(),false,'successful retry revokes across processes');
}
console.log('PASS: separate cache/disk and process VMs; every enable/revoke put/flush stage, continuing failure, prior-consent warning and durable retry');

// Ordinary batches must report every failure, restore cached reads and survive a fresh process.
for (const kind of ['put', 'flush']) for (const stage of kind === 'put' ? [1, 5, 14, 15, 20, 27] : [1]) {
  f = fixture();
  const s = f.settings.load({}); s.ipv6 = true; s.mixedPort = 9090;
  f.fail({ [kind]: stage });
  await assert.rejects(() => f.settings.save({}, s, ['ipv6', 'mixedPort']), /保存失败/);
  assert.equal(f.settings.load({}).ipv6, false);
  assert.equal(f.settings.load({}).mixedPort, 7890);
  assert.equal(fixture(f.disk).settings.load({}).ipv6, false);
  f.fail({}); await f.settings.save({}, s, ['ipv6', 'mixedPort']);
  assert.equal(fixture(f.disk).settings.load({}).mixedPort, 9090);
}
f = fixture();
const ipv6Edit = f.settings.load({}), portEdit = f.settings.load({});
ipv6Edit.ipv6 = true; portEdit.mixedPort = 9090;
const release = f.hold(); let done = false;
const first = f.settings.save({}, ipv6Edit, ['ipv6']).then(() => { done = true; });
await new Promise(resolve => setImmediate(resolve));
assert.equal(done, false); assert.equal(f.settings.load({}).ipv6, false, 'pending cache is not durable state');
const second = f.settings.save({}, portEdit, ['mixedPort']);
release(); await Promise.all([first, second]);
let cold = fixture(f.disk).settings.load({});
assert.equal(cold.ipv6, true); assert.equal(cold.mixedPort, 9090, 'queued scoped saves preserve unrelated fields');
const on = f.settings.load({}), off = f.settings.load({}); on.ipv6 = true; off.ipv6 = false;
await Promise.all([f.settings.save({}, on, ['ipv6']), f.settings.save({}, off, ['ipv6'])]);
assert.equal(fixture(f.disk).settings.load({}).ipv6, false, 'latest same-field intent wins');
const releaseLan = f.hold(); const ordinary = f.settings.save({}, f.settings.load({}), ['ipv6']);
await new Promise(resolve => setImmediate(resolve)); const grant = f.settings.setAllowLan({}, true);
assert.equal(f.cold(), false); releaseLan(); await Promise.all([ordinary, grant]); assert.equal(f.cold(), true);
await f.settings.setAllowLan({}, false); assert.equal(f.cold(), false);
console.log('PASS: ordinary put/flush failure, rollback, durable readback and retry');

})().catch(error => { console.error(error); process.exitCode = 1; });
