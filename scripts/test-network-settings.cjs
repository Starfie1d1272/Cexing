const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets', 'utf8');
const kv = new Map();
let fail = false, failFlush = 0, flushes = 0, failRollbackPut = false;
const persisted = new Map();
const p = { getSync: (key, value) => kv.has(key) ? kv.get(key) : value,
 putSync(key, value) { if ((fail && key === 'allowLan') || (failRollbackPut && flushes >= 3 && key === 'allowLanConfirmed' && value === false)) throw Error('synthetic'); kv.set(key,value); },
 flush() {}, flushSync() {
  if (++flushes === failFlush) throw Error("synthetic flush");
  persisted.clear(); for (const [key, value] of kv) persisted.set(key, value);
 } };
const sandbox = {exports: {}, require: key => key === '@kit.ArkData' ?
 {preferences: {getPreferencesSync: () => p}} : key === './Logger' ? {Logger: {error() {}}} : {}};
vm.runInNewContext(ts.transpileModule(source).outputText, sandbox);
const Settings = sandbox.exports.Settings;
assert.equal(Settings.load({}).allowLan,false);
kv.set('allowLan',true);
assert.equal(Settings.load({}).allowLan,false,'legacy true is not consent');
Settings.save({}, Settings.load({}));
assert.equal(kv.has('allowLanConfirmed'),false,'unrelated save cannot grant consent');
Settings.setAllowLan({},true);
assert.equal(Settings.load({}).allowLan,true);
Settings.save({}, Settings.load({}));
assert.equal(Settings.load({}).allowLan,true);
fail = true;
assert.throws(() => Settings.setAllowLan({},true));
assert.equal(Settings.load({}).allowLan,false,'partial persistence revokes consent');
fail = false;
Settings.setAllowLan({},false);
assert.equal(Settings.load({}).allowLan,false);
for (const stage of [1, 2, 3]) {
  flushes = 0; failFlush = stage;
  assert.throws(() => Settings.setAllowLan({},true));
  assert.equal(Settings.load({}).allowLan,false, `flush stage ${stage} must revoke cached consent`);
  assert.equal(kv.get('allowLanConfirmed'), false);
  assert.equal(persisted.get('allowLanConfirmed'),false);
  failFlush = 0; Settings.setAllowLan({},true);
  assert.equal(Settings.load({}).allowLan,true,'new successful explicit confirmation can recover');
}
flushes = 0; failFlush = 3; failRollbackPut = true;
assert.throws(() => Settings.setAllowLan({},true));
assert.equal(kv.get('allowLanConfirmed'),true,'simulate rollback put also failing');
assert.equal(Settings.load({}).allowLan,false,'process guard must cover failed cache rollback');
Settings.save({}, Settings.load({}));
assert.equal(Settings.load({}).allowLan,false,'unrelated save cannot clear failure guard');
failFlush = 0; failRollbackPut = false;
Settings.setAllowLan({},false);
assert.equal(Settings.load({}).allowLan,false);
console.log('PASS: fresh/legacy defaults, explicit consent, unrelated save and persistence failure');
