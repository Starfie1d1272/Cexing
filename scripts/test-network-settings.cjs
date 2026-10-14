const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const code = ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets', 'utf8')).outputText;
function fixture(disk = new Map()) {
  const cache = new Map(disk);
  let puts = 0, flushes = 0, policy = {};
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
    flush() { this.flushSync(); }
  };
  const sandbox = {exports: {}, require: key => key === '@kit.ArkData' ?
    {preferences: {getPreferencesSync: () => p}} : key === './Logger' ? {Logger: {error() {}}} : {}};
  vm.runInNewContext(code, sandbox);
  return {settings: sandbox.exports.Settings, cache, disk,
    fail(value) { puts = 0; flushes = 0; policy = value; },
    cold() { return fixture(disk).settings.load({}).allowLan; }};
}
let f = fixture();
assert.equal(f.settings.load({}).allowLan,false);
f.cache.set('allowLan',true);
assert.equal(f.settings.load({}).allowLan,false,'legacy true is not consent');
f.settings.save({},f.settings.load({}));
assert.equal(f.cold(),false);
f.settings.setAllowLan({},true);
assert.equal(f.cold(),true);
f.settings.save({},f.settings.load({}));
assert.equal(f.cold(),true);
// Every enable write and flush stage, with one-shot and continuing failure.
for (const kind of ['put','flush']) for (const stage of [1,2,3]) for (const persistent of [false,true]) {
  f = fixture();
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  assert.throws(() => f.settings.setAllowLan({},true));
  assert.equal(f.settings.load({}).allowLan,false, `enable ${kind}/${stage}/${persistent}`);
  assert.equal(f.cold(),false,'failed enable cannot invent a durable grant in this precommit failure fixture');
  f.fail({}); f.settings.setAllowLan({},true);
  assert.equal(f.settings.load({}).allowLan,true);
  assert.equal(f.cold(),true);
}
// Durable previous consent must remain visibly possible after failed revocation.
// A new VM represents the app or VPN Extension with a distinct Preferences cache.
for (const kind of ['put','flush']) for (const stage of kind === 'put' ? [1,2] : [1]) for (const persistent of [false,true]) {
  f = fixture(); f.settings.setAllowLan({},true);
  f.fail({[kind]:stage, [kind === 'put' ? 'persistentPut' : 'persistentFlush']:persistent});
  assert.throws(() => f.settings.setAllowLan({},false));
  assert.equal(f.settings.load({}).allowLan,true, `failed revoke ${kind}/${stage}/${persistent} must show prior consent`);
  assert.equal(f.cold(),true,'extension/new process still sees old durable consent');
  f.fail({}); f.settings.setAllowLan({},false);
  assert.equal(f.settings.load({}).allowLan,false);
  assert.equal(f.cold(),false,'successful retry revokes across processes');
}
console.log('PASS: separate cache/disk and process VMs; every enable/revoke put/flush stage, continuing failure, prior-consent warning and durable retry');

// Ordinary batches must report every failure, restore cached reads and survive a fresh process.
for (const kind of ['put', 'flush']) for (const stage of kind === 'put' ? [1, 5, 13] : [1]) {
  f = fixture();
  const s = f.settings.load({}); s.ipv6 = true; s.mixedPort = 9090;
  f.fail({ [kind]: stage });
  assert.throws(() => f.settings.save({}, s), /保存失败/);
  assert.equal(f.settings.load({}).ipv6, false);
  assert.equal(f.settings.load({}).mixedPort, 7890);
  assert.equal(f.disk.get('ipv6'), false);
  f.fail({}); f.settings.save({}, s);
  assert.equal(fixture(f.disk).settings.load({}).mixedPort, 9090);
}
console.log('PASS: ordinary put/flush failure, rollback, durable readback and retry');
