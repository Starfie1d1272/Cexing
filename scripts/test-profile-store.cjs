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
let identityCounter = 0;
const asyncBuffers = new Map();
let asyncClosed = 0, failAsyncWrite = false, afterAsyncWrite = null;
let unlinkResolve;
let unlinkReject;
let delayDelete = false;
let failMetaMove = false;
let effectiveState = null;
let invalidPointer = false;
const io = {
  open: async name => { data.set(name, ''); asyncBuffers.set(name, Buffer.alloc(0)); return { fd: name }; },
  write: async (name, buffer, options) => {
    if (failAsyncWrite) throw Error('disk full');
    const input = Buffer.from(buffer), count = Math.min(input.length, 7);
    const before = asyncBuffers.get(name), next = Buffer.alloc(Math.max(before.length, options.offset + count));
    before.copy(next); input.copy(next, options.offset, 0, count); asyncBuffers.set(name, next);
    if (afterAsyncWrite) afterAsyncWrite();
    return count;
  },
  close: async file => { asyncClosed++; data.set(file.fd, asyncBuffers.get(file.fd).toString('utf8')); asyncBuffers.delete(file.fd); },
  fsync: async () => {},
  moveFile: async (from, to) => { data.set(to, data.get(from)); data.delete(from); },
  OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
  accessSync: name => data.has(name) || name === '/files/profiles',
  mkdirSync: () => {},
  openSync: name => { data.set(name, ''); return { fd: name }; },
  writeSync: (name, value) => { data.set(name, value); },
  closeSync: () => {},
  readTextSync: name => data.get(name),
  listFileSync: dir => [...data.keys()].filter(name => name.startsWith(dir + '/') &&
    !name.slice(dir.length + 1).includes('/')).map(name => name.slice(dir.length + 1)),
  statSync: name => ({ size: data.get(name).length, mtime: 1 }),
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
  if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => `synthetic-${++identityCounter}`, TextEncoder: { create: () => ({ encodeInto: text => new TextEncoder().encode(text) }) } } };
  if (name.endsWith('BoundedFileReader')) return { BoundedFileReader: { checkConfigSize() {} } };
  if (name.endsWith('Logger')) return { Logger: { info() {}, warn() {}, error() {} } };
  if (name.endsWith('ProfileName')) return {};
  if (name.endsWith('EffectiveVersions')) return { EffectiveVersions: {
    read: () => { if (invalidPointer) throw Error('invalid pointer'); return effectiveState; },
    original: (_, version) => data.get(`/files/profile-versions/${version.ID}/original.yaml`)
  } };
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
  const upper = store.importContent(ctx, 'UPPER.YAML', 'proxies: [upper]');
  assert.equal(upper, 'UPPER.YAML');
  assert.ok(store.list(ctx).some(profile => profile.file === upper && profile.name === 'UPPER'));
  const upperRenamed = store.renameProfile(ctx, upper, 'MOVED.YML');
  assert.equal(upperRenamed, 'MOVED.YML');
  assert.ok(store.list(ctx).some(profile => profile.file === upperRenamed && profile.name === 'MOVED'));
  assert.equal(data.has('/files/profiles/UPPER.YAML'), false);
  store.saveMergeDraft(ctx, second, 'hosts: {synthetic.example: 192.0.2.1}');
  assert.equal(store.getMergeDraft(ctx, second), 'hosts: {synthetic.example: 192.0.2.1}');
  const identity = store.updateState(ctx, second).id;
  store.saveEditDraft(ctx, second, { revision: 'draft-1', intent: { schemaVersion: 1, revision: 'draft-1', sourceRevision: 's', operations: [] } }, '');
  assert.throws(() => store.saveEditDraft(ctx, second, { revision: 'old', intent: null }, ''), /草稿已变化/);
  const renamed = store.renameProfile(ctx, second, 'renamed');
  assert.equal(store.updateState(ctx, renamed).id, identity);
  assert.equal(store.readEditDraft(ctx, renamed).revision, 'draft-1');
  assert.equal(store.getMergeDraft(ctx, renamed), 'hosts: {synthetic.example: 192.0.2.1}');
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
  const deleted = store.importContent(ctx, 'reused', 'proxies: [source-a]');
  store.saveUpdateState(ctx, deleted, { id: 'source-A', attemptedAt: 100, succeededAt: 100, failedAt: 0, retryAt: 0 });
  const unlink = io.unlink;
  io.unlink = file => file.endsWith('.update.json') ? Promise.reject(Error('sidecar I/O')) : unlink(file);
  await store.deleteProfile(ctx, deleted);
  io.unlink = unlink;
  const replacement = store.importContent(ctx, 'reused', 'proxies: [source-b]');
  assert.equal(replacement, deleted);
  assert.notEqual(store.updateState(ctx, replacement).id, 'source-A');
  assert.equal(store.updateState(ctx, replacement).succeededAt, 0, 'new import never reuses an orphan schedule');
  const unicode = 'proxies: [节点😀, short-write]';
  const imported = await store.importContentAsync(ctx, 'async', unicode);
  assert.equal(data.get(`/files/profiles/${imported}`), unicode); assert.equal(asyncClosed, 1);
  let currentImport = true; afterAsyncWrite = () => { currentImport = false; };
  await assert.rejects(store.importContentAsync(ctx, 'cancelled', unicode, () => currentImport), /取消/);
  assert.equal(data.has('/files/profiles/cancelled.yaml'), false); assert.equal(asyncClosed, 2);
  afterAsyncWrite = null; failAsyncWrite = true;
  await assert.rejects(store.importContentAsync(ctx, 'failed-write', unicode), /disk full/);
  assert.equal(data.has('/files/profiles/failed-write.yaml'), false); assert.equal(asyncClosed, 3);
  failAsyncWrite = false;
  const version = { ID: 'version-test', Path: '/files/profile-versions/version-test/config.yaml', ProfileID: renamed };
  const meta = { origin: 'https://synthetic.invalid/feed', sub: {}, updatedAt: 2 };
  data.set(version.Path, 'proxies: [generated]');
  data.set('/files/profile-versions/version-test/original.yaml', 'proxies: [committed-original]');
  data.set('/files/profile-versions/version-test/source.json', JSON.stringify({ Metadata: JSON.stringify(meta) }));
  effectiveState = { Current: version, Previous: null, Profiles: { [renamed]: version } };
  assert.equal(store.getActiveFile(ctx), renamed);
  assert.equal(store.getActiveContent(ctx), 'proxies: [generated]');
  assert.equal(store.getProfileContent(ctx, renamed), 'proxies: [committed-original]');
  assert.equal(store.getMeta(ctx)[renamed].origin, meta.origin);
  data.delete(`/files/profiles/${renamed}`);
  assert.ok(store.list(ctx).some(profile => profile.file === renamed), 'restored immutable sources remain visible without legacy files');
  invalidPointer = true;
  assert.throws(() => store.getActiveFile(ctx), /invalid pointer/);
  console.log('PASS: unique imports, uppercase YAML listing/rename, awaited deletion and effective-version precedence');
})().catch(error => { console.error(error); process.exitCode = 1; });
