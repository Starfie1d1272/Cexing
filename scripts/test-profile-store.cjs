// Synthetic file I/O regression for existing ProfileStore methods.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ProfileStore.ets'), 'utf8');
assert.equal((source.match(/maxLimit: IMPORT_CONFIG_BYTES/g) ?? []).length, 2, 'URL import and update share the file byte limit');
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
let effectiveState = null, publishedIntent = null;
let invalidPointer = false, renameMoves = 0;
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
    renameMoves++;
    if (failMetaMove && to === '/files/profiles/meta.json') throw Error('synthetic metadata write failure');
    data.set(to, data.get(from)); data.delete(from);
  },
  unlinkSync: name => { data.delete(name); },
  unlink: name => delayDelete ? new Promise((resolve, reject) => {
    unlinkResolve = () => { data.delete(name); resolve(); };
    unlinkReject = reject;
  }) : Promise.resolve(data.delete(name))
};
const syntheticYaml = 'proxies: [{name: synthetic, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: synthetic}]';
let requestCount = 0, destroyed = 0;
let responseCode = 200, forceBase64 = false, responseYaml = syntheticYaml;
let appVersion = '0.1.0';
const requests = [];
const http = { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
  request: async (url, options) => {
    requests.push({ url, options });
    requestCount++;
    // Subscription services commonly negotiate their response from the client UA.
    const clash = /clash|mihomo/i.test(options.header?.['User-Agent'] ?? '');
    return { responseCode, result: clash && !forceBase64 ? responseYaml : Buffer.from('ss://synthetic@example.invalid:443').toString('base64'),
      header: { 'subscription-userinfo': 'upload=1; download=2; total=953482739712' } };
  }, destroy: () => { destroyed++; }
}) };
const context = { exports: {}, require: name => {
  if (name === '@kit.CoreFileKit') return { fileIo: io };
  if (name === '@kit.NetworkKit') return { http };
  if (name === '@kit.AbilityKit') return { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync: () => ({ versionName: appVersion }) } };
  if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => `synthetic-${++identityCounter}`, TextEncoder: { create: () => ({ encodeInto: text => new TextEncoder().encode(text) }) } } };
  if (name.endsWith('BoundedFileReader')) return { BoundedFileReader: { checkConfigSize() {} } };
  if (name.endsWith('Logger')) return { Logger: { info() {}, warn() {}, error() {} } };
  if (name.endsWith('ProfileName')) return { suggestProfileName: () => 'remote', profileNameFromUrl: () => 'remote' };
  if (name.endsWith('EffectiveVersions')) return { EffectiveVersions: {
    editIntent: () => publishedIntent,
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
  const collisionSource = store.importContent(ctx, 'collision-source', 'proxies: [untouched]');
  const sourceBase = `/files/profiles/${collisionSource}`;
  for (const suffix of ['.url','.last-good','.merge.json','.region-select.json','.region-previous.json','.update.json','.intent.json']) {
    data.set(`${sourceBase}${suffix}`, `source${suffix}`);
  }
  for (const destination of ['collision-target.yaml', ...['.url','.last-good','.merge.json','.region-select.json','.region-previous.json','.update.json','.intent.json'].map(s => `collision-target.yaml${s}`), 'drafts/collision-target.yaml.draft']) {
    const targetPath = `/files/profiles/${destination}`;data.set(targetPath,'existing destination');
    const snapshot = [...data.entries()], moves = renameMoves;
    assert.throws(() => store.renameProfile(ctx,collisionSource,'collision-target'), /已有资料|已存在同名配置/);
    assert.equal(renameMoves,moves,'collision preflight must finish before moving anything');
    assert.deepEqual([...data.entries()],snapshot,'rename rejection must preserve both sources and all destination sidecars');
    data.delete(targetPath);
  }
  const metaPath='/files/profiles/meta.json',savedMeta=data.get(metaPath);
  data.set(metaPath,JSON.stringify({...JSON.parse(savedMeta??'{}'),'collision-target.yaml':{origin:'synthetic',sub:{},updatedAt:0}}));
  const metaSnapshot=[...data.entries()];
  assert.throws(()=>store.renameProfile(ctx,collisionSource,'collision-target'),/目标名称已有资料/);
  assert.deepEqual([...data.entries()],metaSnapshot,'orphan destination metadata must not be replaced');
  if(savedMeta===undefined)data.delete(metaPath);else data.set(metaPath,savedMeta);
  const importing=store.importContentAsync(ctx,'reserved-target','proxies: [new import]');
  assert.throws(()=>store.renameProfile(ctx,collisionSource,'reserved-target'),/目标名称已有资料/);
  assert.equal(data.get(sourceBase),'proxies: [untouched]');await importing;
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
  const unicode = 'proxies: [节点😀, short-write]', closedBeforeImports = asyncClosed;
  const imported = await store.importContentAsync(ctx, 'async', unicode);
  assert.equal(data.get(`/files/profiles/${imported}`), unicode); assert.equal(asyncClosed, closedBeforeImports + 1);
  let currentImport = true; afterAsyncWrite = () => { currentImport = false; };
  await assert.rejects(store.importContentAsync(ctx, 'cancelled', unicode, () => currentImport), /取消/);
  assert.equal(data.has('/files/profiles/cancelled.yaml'), false); assert.equal(asyncClosed, closedBeforeImports + 2);
  afterAsyncWrite = null; failAsyncWrite = true;
  await assert.rejects(store.importContentAsync(ctx, 'failed-write', unicode), /disk full/);
  assert.equal(data.has('/files/profiles/failed-write.yaml'), false); assert.equal(asyncClosed, closedBeforeImports + 3);
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
  publishedIntent = { schemaVersion:1, revision:'draft-1', sourceRevision:'s', operations:[],
    template:{templateId:'ai',version:1,targetGroup:'Main',baseline:{templateId:'ai',version:1,entries:[]},mine:{templateId:'ai',version:1,entries:[],deleted:['ai/openai']}} };
  assert.equal(store.readEditDraft(ctx,renamed).intent.template.mine.deleted[0],'ai/openai','successful generated provenance supersedes the already-applied sidecar');
  store.saveEditDraft(ctx,renamed,{revision:'unapplied',intent:{schemaVersion:1,revision:'unapplied',sourceRevision:'s',operations:[]}},'draft-1');
  assert.equal(store.readEditDraft(ctx,renamed).intent.template,undefined,'unapplied private draft remains isolated');
  invalidPointer = true;
  assert.throws(() => store.getActiveFile(ctx), /invalid pointer/);
  effectiveState = null; invalidPointer = false; failMetaMove = false;
  const remote = await store.importFromUrl(ctx, 'https://example.invalid/subscription');
  assert.equal(store.getProfileContent(ctx, remote), syntheticYaml);
  const candidate = await store.downloadFromOrigin(ctx, remote);
  assert.equal(candidate.content, syntheticYaml);
  assert.equal(candidate.meta.sub.total, 953482739712);
  assert.equal(requestCount, 2); assert.equal(destroyed, 2);
  assert.equal(store.getOrigin(ctx, remote), 'https://example.invalid/subscription');
  assert.equal(store.getMeta(ctx)[remote].sub.total, 953482739712);
  const versions = context.require('./EffectiveVersions').EffectiveVersions;
  versions.regionPlan = () => null;
  versions.overlay = () => '';
  versions.stage = async (_, file, original, overlay, metadata) => {
    const version = { ID: 'synthetic-updated', Path: '/versions/updated', ProfileID: file };
    data.set(version.Path, original);
    data.set(`/files/profile-versions/${version.ID}/original.yaml`, original);
    data.set(`/files/profile-versions/${version.ID}/source.json`, JSON.stringify({ Metadata: metadata }));
    return { version, receipt: '' };
  };
  versions.commit = async (_, version) => { effectiveState = { Current: null, Profiles: { [remote]: version } }; };
  const txContext = { exports: {}, require: name => {
    if (name.endsWith('ProfileStore')) return { ProfileStore: store };
    if (name.endsWith('EffectiveVersions')) return { EffectiveVersions: versions };
    if (name.endsWith('VpnController')) return { VpnStatus: { Disconnected: 0 }, VpnController: {
      status: 0, holdConfiguration: () => () => {}, configurationEpoch: () => 0 } };
    if (name.endsWith('Settings')) return { Settings: { load() {}, async idle() {} } };
    if (name.endsWith('CoreValidator')) return { CoreValidator: { async prepareResources() {} } };
    if (name.endsWith('ProfileRegionChoices')) return { ProfileRegionChoices: {
      selector: () => '', prepare: async () => ({ state: null }) } };
    return context.require(name);
  } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/lib/ProfileTransactions.ets'), 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
  } }).outputText, txContext);
  // Use the actual update transaction and HTTP download, with only platform/version storage mocked.
  const tx = txContext.exports.ProfileTransactions;
  appVersion = '0.2.0';
  responseYaml = syntheticYaml.replace('name: synthetic', 'name: updated');
  assert.equal(await tx.update(ctx, remote), 'saved');
  assert.equal(store.getProfileContent(ctx, remote), responseYaml);
  assert.equal(store.getOrigin(ctx, remote), 'https://example.invalid/subscription');
  assert.equal(store.getMeta(ctx)[remote].sub.total, 953482739712);
  assert.equal(requests[0].options.header['User-Agent'], 'ClashMeta/1.0 Cexing/0.1.0');
  assert.equal(requests[1].options.header['User-Agent'], requests[0].options.header['User-Agent']);
  assert.equal(requests[2].options.header['User-Agent'], 'ClashMeta/1.0 Cexing/0.2.0');
  assert.ok(requests.every(request => request.url === 'https://example.invalid/subscription'));
  for (const failure of ['format', 'http']) {
    forceBase64 = failure === 'format'; responseCode = failure === 'http' ? 503 : 200;
    const before = [...data.entries()], pointer = JSON.stringify(effectiveState);
    const error = failure === 'http' ? /HTTP 503/ : /不是合法的 mihomo 配置/;
    await assert.rejects(store.importFromUrl(ctx, 'https://example.invalid/subscription'), error);
    await assert.rejects(tx.update(ctx, remote), error);
    assert.deepEqual([...data.entries()], before, 'failed import/update preserves all existing subscriptions and metadata');
    assert.equal(JSON.stringify(effectiveState), pointer, 'failed update preserves the effective pointer');
  }
  assert.equal(requestCount, 7); assert.equal(destroyed, requestCount);
  console.log('PASS: subscription UA negotiation, actual import/update, failure preservation; unique imports, uppercase YAML listing/rename, awaited deletion and effective-version precedence');
})().catch(error => { console.error(error); process.exitCode = 1; });
