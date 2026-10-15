// Actual subscription page and paired reader/Host over the shared real worker.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const fixture = require('./candidate-draft-lifecycle.cjs');
const { resourceContext } = require('./mock-profile-resources.cjs');
const { phase, ctx, file } = fixture;
async function run() {
  if (phase !== 'profile-resume-update') { await fixture.runPhase(phase); return; }
  const bus = { request: null }; let downloads = 0;
  const r = fixture.runtime({
    globals: { getContext: () => ({ ...resourceContext(), ...ctx }), NavPathStack: class {} },
    modules: { '@kit.ArkUI': { promptAction: { showToast() {} } }, '@kit.ScanKit': {}, '@kit.BasicServicesKit': {},
      './AppRuntime': { AppRuntime: {} }, './ProfileRecovery': { ProfileRecovery: {} }, './ProfileImportInput': { ProfileImportInput: { take: () => null, hasPending: () => false } },
      './../pages/GlobalMergeEditor': {}, './../pages/NativeTheme': {}, './../pages/ProfileEditPage': { ProfileEditBus: {} },
      './../pages/ProfileTemplatePage': { ProfileTemplateBus: {} }, './../pages/ProfileUpdatePage': { ProfileUpdateBus: bus },
      './../pages/ProfileProxyEditorPage': { ProfileProxyEditorBus: {} }, './../pages/RuleDnsEditorPage': { RuleDnsEditorBus: {} } },
    transform: (key, source) => {
      if (!key.endsWith('/ProfilePage')) return source;
      return (source.slice(0, source.indexOf('  @Builder')) + '\n}').split('\n').map(line => line.trimStart().startsWith('@') ?
        line.replace(/@\w+(?:\([^\n)]*\))?\s*/g, '') : line).join('\n').replace('export struct ', 'export class ');
    }
  });
  r.store.downloadFromOrigin = async () => { downloads++; throw Error('pending update must not download'); };
  const Page = r.load('pages/ProfilePage').ProfilePage;
  function page() {
    const p = new Page(), paths = []; p.pageVisible = true; p.rootVisible = true; p.currentVisibleTab = 1; p.pageGeneration = 1;
    p.navStack = { getAllPathName: () => paths.slice(), pushPath: value => paths.push(value.name) }; return { p, paths };
  }
  const draftPath = path.join(ctx.filesDir, 'profiles', file + '.intent.json');
  const original = r.store.getProfileContent(ctx, file), before = fs.readFileSync(draftPath);
  const first = page(); await first.p.updateFile(file);
  assert.equal(downloads, 0); assert.equal(first.paths.join(','), 'profileTemplateUpdate');
  assert.ok(bus.request.source.original.includes('US-two'));
  const host = r.hosts.create(ctx, file, bus.request.source), session = await host.load();
  await host.preview(session.revision);
  assert.equal(r.store.getProfileContent(ctx, file), original); assert.deepEqual(fs.readFileSync(draftPath), before);
  bus.request = null; const departed = page();
  fixture.hooks.read = async () => { departed.p.pageVisible = false; departed.p.pageGeneration++; };
  await departed.p.updateFile(file);
  assert.equal(downloads, 0); assert.equal(bus.request, null); assert.equal(departed.paths.length, 0);
  assert.equal(r.store.getProfileContent(ctx, file), original); assert.deepEqual(fs.readFileSync(draftPath), before);
}
run().then(() => { fixture.close(); process.exit(0); }, error => { console.error(error); process.exit(1); });
