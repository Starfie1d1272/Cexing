const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/Settings.ets', 'utf8');
const kv = new Map();
let fail = false;
const p = { getSync: (key, value) => kv.has(key) ? kv.get(key) : value,
 putSync(key, value) { if (fail && key === 'allowLan') throw Error('synthetic'); kv.set(key,value); },
 flush() {}, flushSync() {} };
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
console.log('PASS: fresh/legacy defaults, explicit consent, unrelated save and persistence failure');
