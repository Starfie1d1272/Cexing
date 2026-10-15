// Called by the shared candidate lifecycle harness. Real Model/Store/Tx/Go;
// the harness supplies only platform filesystem ports and the worker transport.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const { resourceContext } = require('./mock-profile-resources.cjs');
let dialog;
async function idle(p) { const end = Date.now() + 15000; while (p.busy) { assert.ok(Date.now() < end); await new Promise(setImmediate); } }
async function page(runtime, ctx, file) {
  const r = runtime({ globals: { getContext: () => ({ ...resourceContext(), ...ctx }), AlertDialog: { show: value => { dialog = value; } } },
    modules: { './ProfileApplyRecovery': { ProfileApplyRecovery: {} }, './ProfileImportInput': { ProfileImportInput: { hasPending: () => false } }, '@kit.ArkUI': { promptAction: { showToast() {} } }, './../pages/NativeTheme': {},
      './../pages/ProxyMappingFormPage': {}, './../pages/ProfileEditPage': { ProfileEditBus: {} } },
    transform: (key, source) => {
      if (key === './ProfileProxyEditorModel' && process.env.CEXING_PROXY_MODEL_SOURCE) return fs.readFileSync(process.env.CEXING_PROXY_MODEL_SOURCE, 'utf8');
      if (!key.endsWith('/ProfileProxyEditorPage')) return source;
      const cut = source.includes('  @Builder') ? source.indexOf('  @Builder') : source.indexOf('  build()');
      return (source.slice(0, cut) + '\n}').split('\n').map(line => line.trimStart().startsWith('@') ?
        line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
    } });
  const module = r.load('pages/ProfileProxyEditorPage'); module.ProfileProxyEditorBus.file = file;
  const p = new module.ProfileProxyEditorPage(); p.visible = true; p.profileRevision = 0; p.navStack = { clear() {}, pushPath() {} };
  p.aboutToAppear(); await idle(p); assert.equal(p.error, '');
  const row = p.rows.find(row => row.label === 'Synthetic'); assert.ok(row); await p.open(row);
  assert.ok(p.formTarget, p.error); return { r, p, model: p.model };
}
exports.run = async function ({ runtime, action, ctx, file, phase }) {
  const r = runtime();
  const Model = r.load('ProfileProxyEditorModel').ProfileProxyEditorModel;
  const metadata = { origin: 'https://example.invalid/proxy-candidate', sub: { upload: 0, download: 0, total: 0, expire: 0 }, updatedAt: 3 };
  const original = 'proxies: [{name: Synthetic, type: socks5, server: 192.0.2.1, port: 1080}]\ndns: {enable: true, nameserver: [192.0.2.1]}\nrules: ["MATCH,DIRECT"]\n';
  const candidate = original.replace('port: 1080', 'port: 1081').replace('nameserver: [192.0.2.1]', 'nameserver: [192.0.2.2]');
  if (phase === 'proxy-save') {
    fs.mkdirSync(path.join(ctx.filesDir, 'profiles'), { recursive: true });
    fs.writeFileSync(path.join(ctx.filesDir, 'profiles', file), original);
    fs.writeFileSync(path.join(ctx.filesDir, 'profiles', 'active.txt'), file);
    const expected = r.versions.read(ctx)?.Current?.ID ?? '';
    const staged = JSON.parse(await action({ op: 'stage', profileId: file, original, metadata: JSON.stringify(metadata), expected }));
    assert.ok(staged.version, 'successful source must stage before candidate setup');
    assert.ok(JSON.parse(await action({ op: 'commit', versionId: staged.version.ID, expected, active: true })).state);
    const host = r.hosts.create(ctx, file, { original: candidate, metadata });
    const session = await host.load();
    const snapshot = await r.editor.list(ctx, candidate, '', staged.version.ID);
    const item = snapshot.sections.find(part => part.section === 'dns').items[0];
    const target = await r.editor.target(ctx, candidate, '', staged.version.ID, 'dns', item.id);
    const intent = session.intent ?? { schemaVersion: 1, revision: 'pending', sourceRevision: session.snapshot.sourceRevision, operations: [] };
    intent.operations.push({ id: 'candidate-dns', kind: 'update', section: 'dns', target: item.id,
      preconditions: { nameserver: target.item.fields.nameserver }, patch: { nameserver: ['192.0.2.5'] } });
    const saved = await host.save(intent, session.revision);
    await host.preview(saved.revision);
    assert.equal(r.store.getProfileContent(ctx, file), original);
    assert.ok(r.store.readEditDraft(ctx, file).source);
    return;
  }
  const actual = await page(runtime, ctx, file);
  const model = actual.model, p = actual.p;
  assert.equal(p.formTarget.value.port, phase === 'proxy-apply' ? 1082 : 1081, 'actual page form follows the candidate projection');
  const item = model.snapshot.sections.find(part => part.section === 'proxies').items.find(item => item.name === 'Synthetic');
  assert.ok(item, 'actual model must expose the persisted candidate node');
  const target = await model.target('proxies', item.id);
  assert.equal(target.value.port, 1081, 'authoring target must use the paired candidate, not successful port 1080');
  if (phase === 'proxy-reopen') {
    assert.equal((await model.presentTarget('proxies', target)).value.port, 1081);
    assert.ok(Array.isArray(await model.smartChoices()));
  } else if (phase === 'proxy-modify') {
    await p.saveForm({ section: 'proxies', name: 'Synthetic', target: p.originalTarget, value: { ...p.formTarget.value, port: 1082 } });
    assert.equal(p.error, ''); assert.equal(p.previewReady, true);
    assert.equal((await model.presentTarget('proxies', target)).value.port, 1082);
    await p.undo(); assert.equal(p.error, '');
    assert.equal((await model.presentTarget('proxies', target)).value.port, 1081);
    const draftPath = path.join(ctx.filesDir, 'profiles', file + '.intent.json');
    const beforeCancel = fs.readFileSync(draftPath);
    await p.undo(); assert.ok(dialog); dialog.primaryButton.action(); await dialog.secondaryButton.action();
    assert.deepEqual(fs.readFileSync(draftPath), beforeCancel, 'cancelled whole-draft restore cannot write');
    await p.undo(); await dialog.secondaryButton.action();
    assert.equal(actual.r.store.readEditDraft(ctx, file).source, undefined);
    assert.equal((await model.target('proxies', item.id)).value.port, 1080);
    await p.undo(); assert.equal(p.error, '');
    assert.ok(actual.r.store.readEditDraft(ctx, file).source);
    await p.open(p.rows.find(row => row.label === 'Synthetic'));
    assert.equal(p.formTarget.value.port, 1081, 'undo restores source together with intent');
    await p.saveForm({ section: 'proxies', name: 'Synthetic', target: p.originalTarget, value: { ...p.formTarget.value, port: 1082 } });
    assert.equal(p.error, ''); assert.equal(p.previewReady, true);
  } else if (phase === 'proxy-apply') {
    assert.equal((await model.presentTarget('proxies', target)).value.port, 1082);
    await p.inspect(); assert.equal(p.error, ''); assert.equal(p.previewReady, true);
    await p.apply(); await idle(p); assert.equal(p.error, '');
    assert.equal(r.store.getProfileContent(ctx, file), candidate);
    assert.equal(r.store.readEditDraft(ctx, file).source, undefined);
    const reopened = new Model(ctx, file); assert.equal(await reopened.load(), true);
    const authoring = await reopened.target('proxies', item.id);
    assert.equal((await reopened.presentTarget('proxies', authoring)).value.port, 1082);
  } else { throw Error('unknown proxy lifecycle phase'); }
  p.aboutToDisappear();
};

if (require.main === module) {
  const fixture = require('./candidate-draft-lifecycle.cjs');
  exports.run(fixture).then(() => { fixture.close(); process.exit(0); }, error => { console.error(error); process.exit(1); });
}
