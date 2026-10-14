const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let ipv6 = false;
const calls = [];
const version = { ID: 'version-test', ProfileID: 'a.yaml', Path: '/files/profile-versions/version-test/config.yaml' };
const io = { accessSync: path => !path.endsWith('/state.json'), statSync: () => ({ size: 1 }) };
const core = {
  versionAction: async (_, raw) => { const request = JSON.parse(raw); calls.push([request.op, JSON.parse(request.overrides)]);
    if (request.op === 'stage') return JSON.stringify({ version, receipt: 'r' });
    if (request.op === 'verify') return '{"receipt":"r"}';
    return '{"mergePreview":{"digest":"r","changes":[]}}'; },
  validateOffline: async (_, __, overrides) => { calls.push(['validateOffline', JSON.parse(overrides)]); return ''; },
  previewMerge: async (_, __, ___, overrides) => { calls.push(['previewMerge', JSON.parse(overrides)]); return '{"digest":"r","changes":[]}'; }
};
function load(name) {
  const sandbox = { exports: {}, require: key => key === '@kit.CoreFileKit' ? { fileIo: io } : key === 'libentry.so' ? core :
    key === './Settings' ? { Settings: { load: () => ({ ipv6, mixedPort: 7890, logLevel: 'info', allowLan: false, mode: '', logToFile: true }) } } : {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(`cexing/entry/src/main/ets/lib/${name}.ets`, 'utf8')).outputText, sandbox);
  return sandbox.exports[name];
}
const versions = load('EffectiveVersions'), validator = load('CoreValidator'), context = { filesDir: '/files' };
(async () => {
  for (const flag of [false, true]) {
    ipv6 = flag; calls.length = 0;
    await versions.stage(context, 'a.yaml', 'original', '', '{}', '', null);
    await versions.previewMerge(context, 'original', '', null);
    await versions.verify(context, version, '');
    await validator.validate(context, 'original');
    await validator.previewMerge(context, 'original', '');
    assert.deepEqual(calls.map(([op]) => op), ['stage', 'merge-preview', 'verify', 'validateOffline', 'previewMerge']);
    assert.ok(calls.every(([, settings]) => settings.ipv6 === flag && settings.allowLan === false), 'same explicit IPv6 setting reaches every native validation path');
  }
  console.log('PASS: explicit IPv6 on/off in stage, merge preview, verify and offline validation overrides');
})().catch(error => { console.error(error); process.exitCode = 1; });
