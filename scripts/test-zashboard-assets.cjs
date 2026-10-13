// Real ArkTS resource implementation, TypeScript host fixture, synthetic rawfiles and real temp filesystem.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const crypto = require('node:crypto');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ZashboardAssets.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } });
const digest = data => crypto.createHash('sha256').update(data).digest('hex');
const pin = {};
const modes = { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 2, NOFOLLOW: 4 };
let rejectSelection = false;
let rejectLock = false;
let rejectPublish = false;
const fileIo = {
  OpenMode: modes, accessSync: fs.existsSync, mkdirSync: fs.mkdirSync, lstatSync: fs.lstatSync,
  listFileSync: fs.readdirSync, rmdirSync: p => fs.rmSync(p, { recursive: true }),
  unlinkSync: fs.unlinkSync,
  openSync(p, flags) { return { fd: fs.openSync(p, flags & modes.WRITE_ONLY ? (p.endsWith('deployment.lock') ? 'a' : 'wx') : fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW), tryLock() { if (rejectLock) throw Error('synthetic lock contention'); } }; },
  closeSync: f => fs.closeSync(f.fd), readSync: (fd, data) => fs.readSync(fd, Buffer.from(data)),
  writeSync: (fd, data) => fs.writeSync(fd, Buffer.from(data)), fsyncSync: fs.fsyncSync,
  renameSync(from, to) {
    if (rejectSelection && to.endsWith('/ui/index.html')) throw Error('synthetic disk failure');
    if (rejectPublish && from.includes('/zashboard-staging-') && to.includes('/ui/versions/')) throw Error('synthetic publish failure');
    fs.renameSync(from, to);
  }
};
const modules = {
  '@kit.CoreFileKit': { fileIo },
  '@kit.ArkTS': { util: {
    TextDecoder: class { decodeToString(data) { return new TextDecoder().decode(data); } },
    TextEncoder: class { encodeInto(data) { return new TextEncoder().encode(data); } }
  } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd() {
    const md = crypto.createHash('sha256');
    return { update: async blob => md.update(blob.data), digest: async () => ({ data: new Uint8Array(md.digest()) }) };
  } } },
  './ZashboardPin': pin
};
const context = { exports: {}, require: name => { assert.ok(modules[name], name); return modules[name]; } };
vm.runInNewContext(compiled.outputText, context);
const Assets = context.exports.ZashboardAssets;
modules['./ZashboardAssets'] = { ZashboardAssets: Assets };
const policySource = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ZashboardPolicy.ets'), 'utf8');
const policyContext = { exports: {}, require: context.require };
vm.runInNewContext(ts.transpileModule(policySource, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, policyContext);
const Policy = policyContext.exports.ZashboardPolicy;
const url = 'http://127.0.0.1:9090/ui/';
assert.equal(Policy.validSession(false, url, 'a'.repeat(64)), false);
assert.equal(Policy.validSession(true, url, 'a'.repeat(64)), true);
for (const bad of ['http://localhost:9090/ui/', 'https://127.0.0.1:9090/ui/', 'http://127.0.0.1:0/ui/', 'http://127.0.0.1:65536/ui/', url + '?secret=synthetic', 'http://user@127.0.0.1:9090/ui/']) {
  assert.equal(Policy.validSession(true, bad, 'a'.repeat(64)), false);
}
for (const good of [url, url + '#/', url + '#/proxies', url + 'versions/' + 'a'.repeat(64) + '/#/proxies']) assert.equal(Policy.navigation(url, 'a'.repeat(64), good), true);
for (const bad of ['https://example.invalid/', 'file:///tmp/index.html', url + '../restart', url + 'index.html', url + '?secret=synthetic', url + '#/../restart', url + 'versions/' + 'b'.repeat(64) + '/']) assert.equal(Policy.navigation(url, 'a'.repeat(64), bad), false);
for (const good of ['http://127.0.0.1:9090/proxies', 'http://127.0.0.1:9090/ui/assets/local.js', 'ws://127.0.0.1:9090/traffic']) assert.equal(Policy.request(url, good), true);
for (const bad of ['http://127.0.0.1:9091/version', 'http://127.0.0.1:9090.evil.invalid/version', 'https://example.invalid/a.js', 'http://127.0.0.1:9090/restart', 'http://127.0.0.1:9090/%72estart', 'http://127.0.0.1:9090/upgrade/ui', 'http://127.0.0.1:9090/ui/../restart']) assert.equal(Policy.request(url, bad), false);
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'zashboard-regression-'));
let resources;
function fixture(text, filename = 'index.html') {
  const content = Buffer.from(text);
  const files = [{ path: filename, size: content.length, sha256: digest(content) }];
  const version = digest(JSON.stringify(files));
  const data = Buffer.from(JSON.stringify({ schema: 1, version, sourceSha: '1'.repeat(40), files }));
  pin.ZASHBOARD_VERSION = version;
  pin.ZASHBOARD_MANIFEST_SHA256 = digest(data);
  resources = { 'zashboard/manifest.json': data, ['zashboard/' + filename]: content };
  return version;
}
const host = { filesDir: home, resourceManager: { async getRawFileContent(p) {
  assert.ok(resources[p], 'unknown resource'); return new Uint8Array(resources[p]);
} } };
(async () => {
  const oldSource = require('node:child_process').execFileSync('git', ['show',
    '2c0c1ed95c06f65770445a82f5afd59adb43376c:clash-openharmony/entry/src/main/ets/lib/ZashboardAssets.ets'],
    { cwd: path.join(__dirname, '..'), encoding: 'utf8' });
  const oldContext = { exports: {}, require: context.require };
  vm.runInNewContext(ts.transpileModule(oldSource, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, oldContext);
  const oldHome = path.join(home, 'baseline');
  fs.mkdirSync(oldHome);
  const oldHost = { filesDir: oldHome, resourceManager: host.resourceManager };
  const oldVersion = fixture('baseline-resource');
  assert.equal((await oldContext.exports.ZashboardAssets.prepare(oldHost)).version, oldVersion);
  fs.writeFileSync(oldHome + '/ui/versions/' + oldVersion + '/index.html', 'broken baseline');
  assert.equal((await oldContext.exports.ZashboardAssets.prepare(oldHost)).directory, '');
  assert.equal((await oldContext.exports.ZashboardAssets.prepare(oldHost)).directory, '');
  assert.equal((await Assets.prepare(oldHost)).version, oldVersion);
  assert.equal(fs.readFileSync(oldHome + '/ui/versions/' + oldVersion + '/index.html', 'utf8'), 'baseline-resource');
  console.log('PASS: 2c0c1ed damaged-version retry failure reproduced; fixed prepare repairs identical version from packaged bytes');
  for (const p of ['../secret', '/index.html', 'a//b', 'a/./b', 'a/../b', 'a\\b', '%2e%2e/a', 'a?b']) assert.equal(Assets.safePath(p), false, p);
  assert.equal(Assets.safePath('assets/font-a.woff2'), true);
  const firstVersion = fixture('first');
  const first = await Assets.prepare(host);
  assert.equal(first.version, firstVersion);
  assert.equal(fs.readFileSync(first.directory + '/versions/' + firstVersion + '/index.html', 'utf8'), 'first');
  const before = fs.readFileSync(home + '/ui/index.html', 'utf8');
  fs.writeFileSync(first.directory + '/versions/' + firstVersion + '/index.html', 'broken without previous');
  resources['zashboard/index.html'] = Buffer.from('bad packaged resource');
  assert.equal((await Assets.prepare(host)).directory, '');
  fixture('first');
  assert.equal((await Assets.prepare(host)).version, firstVersion);
  assert.equal(fs.readFileSync(first.directory + '/versions/' + firstVersion + '/index.html', 'utf8'), 'first');
  rejectLock = true;
  assert.equal((await Assets.prepare(host)).directory, '');
  rejectLock = false;
  assert.equal(fs.readFileSync(home + '/ui/index.html', 'utf8'), before);
  fs.writeFileSync(home + '/ui/index.html', 'invalid synthetic record');
  const repaired = await Assets.prepare(host);
  assert.equal(repaired.version, firstVersion);
  assert.ok(repaired.error);
  assert.equal(fs.readFileSync(home + '/ui/index.html', 'utf8'), before);
  const same = await Promise.all([Assets.prepare(host), Assets.prepare(host)]);
  assert.ok(same.every(v => v.version === firstVersion));
  const secondVersion = fixture('second');
  rejectSelection = true;
  const failedCommit = await Assets.prepare(host);
  rejectSelection = false;
  assert.equal(failedCommit.version, firstVersion);
  assert.equal(failedCommit.fallback, true);
  assert.equal(fs.readFileSync(home + '/ui/index.html', 'utf8'), before);
  const second = await Assets.prepare(host);
  assert.equal(second.version, secondVersion);
  const reverted = await Assets.rollback(host);
  assert.equal(reverted.version, firstVersion);
  assert.equal((await Assets.rollback(host)).version, secondVersion);
  fs.writeFileSync(second.directory + '/versions/' + secondVersion + '/index.html', 'broken');
  resources['zashboard/index.html'] = Buffer.from('bad packaged resource');
  const fallback = await Assets.prepare(host);
  assert.equal(fallback.version, firstVersion);
  assert.equal(fallback.fallback, true);
  fixture('second');
  const selectorBeforeRepair = fs.readFileSync(home + '/ui/index.html', 'utf8');
  rejectPublish = true;
  assert.equal((await Assets.prepare(host)).version, firstVersion);
  rejectPublish = false;
  assert.equal(fs.readFileSync(home + '/ui/index.html', 'utf8'), selectorBeforeRepair);
  assert.equal(fs.readFileSync(second.directory + '/versions/' + secondVersion + '/index.html', 'utf8'), 'broken');
  const recovered = await Assets.prepare(host);
  assert.equal(recovered.version, secondVersion);
  assert.equal(recovered.fallback, false);
  assert.equal(fs.readFileSync(second.directory + '/versions/' + secondVersion + '/index.html', 'utf8'), 'second');
  assert.ok(fs.readdirSync(home).some(n => n.startsWith('zashboard-quarantine-' + secondVersion)));
  fs.unlinkSync(second.directory + '/versions/' + secondVersion + '/index.html');
  assert.equal((await Assets.prepare(host)).version, secondVersion);
  assert.equal(fs.readFileSync(second.directory + '/versions/' + secondVersion + '/index.html', 'utf8'), 'second');
  assert.equal((await Assets.rollback(host)).version, firstVersion);
  fixture('second');
  fs.writeFileSync(second.directory + '/versions/' + secondVersion + '/manifest.json', 'invalid stored manifest');
  assert.equal((await Assets.prepare(host)).version, secondVersion);
  assert.doesNotThrow(() => JSON.parse(fs.readFileSync(second.directory + '/versions/' + secondVersion + '/manifest.json', 'utf8')));
  assert.equal((await Assets.rollback(host)).version, firstVersion);
  fixture('traversal', '../secret');
  assert.equal((await Assets.prepare(host)).version, firstVersion);
  assert.equal(fs.existsSync(home + '/secret'), false);
  fixture('third');
  resources['zashboard/index.html'] = Buffer.from('wrong');
  assert.equal((await Assets.prepare(host)).version, firstVersion);
  fs.symlinkSync('/tmp', first.directory + '/versions/' + firstVersion + '/unsafe');
  assert.equal((await Assets.prepare(host)).version, secondVersion);
  fs.unlinkSync(first.directory + '/versions/' + firstVersion + '/unsafe');
  fs.writeFileSync(first.directory + '/versions/' + firstVersion + '/extra.js', 'unlisted');
  assert.equal((await Assets.prepare(host)).version, secondVersion);
  fixture('first');
  const repairedExtra = await Assets.prepare(host);
  assert.equal(repairedExtra.version, firstVersion);
  assert.equal(fs.existsSync(first.directory + '/versions/' + firstVersion + '/extra.js'), false);
  const selectedDirectory = first.directory + '/versions/' + firstVersion;
  fs.rmSync(selectedDirectory, { recursive: true });
  fs.symlinkSync('/synthetic-missing-target', selectedDirectory);
  assert.equal((await Assets.prepare(host)).version, firstVersion);
  assert.equal(fs.lstatSync(selectedDirectory).isDirectory(), true);
  console.log('PASS: Web origin/navigation/lifecycle endpoint policy, path rejection, verified install, serialized reopen, atomic failure, rollback, corruption fallback, bad rawfile, symlink and unlisted-file rejection');
})().finally(() => fs.rmSync(home, { recursive: true, force: true })).catch(e => { console.error(e); process.exitCode = 1; });
