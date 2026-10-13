// Synthetic file I/O regression for existing ProfileStore methods.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ProfileStore.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const data = new Map();
let unlinkResolve;
let unlinkReject;
let delayDelete = false;
let failMetaMove = false;
const io = {
  OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
  accessSync: name => data.has(name) || name === '/files/profiles',
  mkdirSync: () => {},
  openSync: name => { data.set(name, ''); return { fd: name }; },
  writeSync: (name, value) => { data.set(name, value); },
  closeSync: () => {},
  readTextSync: name => data.get(name),
  moveFileSync: (from, to) => {
    if (failMetaMove && to === '/files/profiles/meta.json') throw Error('synthetic metadata write failure');
    data.set(to, data.get(from)); data.delete(from);
  },
  unlinkSync: name => { data.delete(name); },
  unlink: name => delayDelete ? new Promise((resolve, reject) => {
    unlinkResolve = () => { data.delete(name); resolve(); };
    unlinkReject = reject;
  }) : Promise.resolve(data.delete(name))
};
const context = { exports: {}, require: name => {
  if (name === '@kit.CoreFileKit') return { fileIo: io };
  if (name === '@kit.NetworkKit') return { http: {} };
  if (name === '@kit.AbilityKit') return {};
  if (name === '@kit.ArkTS') return { util: {} };
  if (name.endsWith('Logger')) return { Logger: { info() {}, warn() {}, error() {} } };
  if (name.endsWith('ProfileName')) return {};
  return {};
} };
vm.runInNewContext(js, context);
const store = context.exports.ProfileStore;
const ctx = { filesDir: '/files' };
(async () => {
  const first = store.importContent(ctx, 'same', 'proxies: [synthetic]');
  const second = store.importContent(ctx, 'same', 'proxies: [different]');
  assert.equal(first, 'same.yaml');
  assert.equal(second, 'same (2).yaml');
  assert.equal(data.get('/files/profiles/same.yaml'), 'proxies: [synthetic]');
  failMetaMove = true;
  assert.throws(() => store.updateProfileContent(ctx, first, 'proxies: [updated]'), /原配置已恢复/);
  assert.equal(data.get('/files/profiles/same.yaml'), 'proxies: [synthetic]');
  assert.throws(() => store.commitDownloaded(ctx, first, {
    content: 'proxies: [downloaded]', meta: { origin: 'synthetic', sub: {}, updatedAt: 1 }
  }), /原配置已恢复/);
  assert.equal(data.get('/files/profiles/same.yaml'), 'proxies: [synthetic]');
  failMetaMove = false;
  delayDelete = true;
  const removal = store.deleteProfile(ctx, first);
  assert.equal(data.has('/files/profiles/same.yaml'), true);
  unlinkReject(new Error('synthetic failure'));
  await assert.rejects(removal, /synthetic failure/);
  assert.equal(data.has('/files/profiles/same.yaml'), true);
  const retry = store.deleteProfile(ctx, first);
  delayDelete = false;
  unlinkResolve();
  await retry;
  assert.equal(data.has('/files/profiles/same.yaml'), false);
  console.log('PASS: unique imports and awaited deletion success/failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
