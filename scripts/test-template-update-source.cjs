const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let expectedOriginal='prepared original', inputs = [], prepared = 0, pendingRead, precision = false;
const snapshot = { templateId: 'ai', version: 1, entries: [] };
const intent = { schemaVersion: 1, revision: 'intent', sourceRevision: 'source', operations: [], template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } };
let published = structuredClone(intent), paired, activeVersion='version-successful';
const session = revision => ({ profileId: 'one.yaml', revision, intent: structuredClone(intent), snapshot: { sourceRevision: 'source', sections: [] } });
const ticket=()=>({file:'one.yaml',profileIdentity:'identity',profileVersion:'version-successful',activeVersion:activeVersion,activeFile:'one.yaml',draftRevision:intent.revision});
const presentation = { exports: {}, require: () => ({}) };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateConflictPresentation.ets', 'utf8')).outputText, presentation);
const modules = {
 './TemplateConflictPresentation': presentation.exports,
 './ProfileTransactions':{ProfileTransactions:{editTicket:ticket,readEditSource:async(_ctx,captured,current)=>{assert.deepEqual(captured,ticket());assert.equal(current(),true);return paired}}},
 'libentry.so': { versionAction: async (root, raw) => {
  if (precision) return JSON.stringify({ error: 'TEMPLATE_UPDATE_PRECISION' });
  assert.equal(root, '/synthetic'); const value = JSON.parse(raw); assert.equal(value.op, 'template-update-preview'); inputs.push(value.source);
  assert.equal(value.source.profileVersion, 'version-successful'); assert.equal(value.source.original, expectedOriginal);
  assert.equal(value.source.globalMerge, 'global'); assert.equal(value.source.overlay, 'local');
  assert.equal(value.source.url, undefined); assert.equal(value.source.home, undefined);
  if (value.source.action === 'encode') { assert.equal(value.source.stamp, 'a'.repeat(64)); return JSON.stringify({ intent: { ...value.source.intent, template: { ...value.source.intent.template, baseline: snapshot, mine: snapshot } } }); }
  if (pendingRead) { const pending = pendingRead; pendingRead = null; await pending; }
  return JSON.stringify({ stamp: 'a'.repeat(64), request: { kind: 'subscription', base: snapshot, mine: snapshot, next: snapshot } });
 } },
 './EffectiveVersions': { EffectiveVersions: { read: () => ({ Profiles: { 'one.yaml': { ID: 'version-successful' } } }), globalContent: () => 'global', editIntent: () => published } },
 './ProfileStore': { ProfileStore: { readEditDraft:()=>({revision:''}),readEditDraftSource:async()=>undefined,getProfileContent: () => 'original', prepareContent: text => 'prepared ' + text, getEnabledMerge: () => 'local' } },
 './Settings': { Settings: { load: () => ({ ipv6: true }) } },
 './CoreValidator': { CoreValidator: { prepareResources: async () => { prepared++; } } }
};
const sandbox = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateUpdateSource.ets', 'utf8')).outputText, sandbox);
(async () => {
 const source = sandbox.exports.createTemplateUpdateSource({ filesDir: '/synthetic' }, 'one.yaml');
 assert.equal(source.available('ai', 'Pick'), true);
 assert.equal(source.available('ai', 'unsaved-target'), false);
 assert.equal(source.available('region', 'Pick'), false);
 published.disabled = true; assert.equal(source.available('ai', 'Pick'), false); delete published.disabled;
 const first = session('draft-1'); assert.equal((await source.read(first)).kind, 'subscription'); assert.equal(prepared, 1);
 assert.equal((await source.encode(snapshot, first)).template.mine.version, 1);
 await assert.rejects(source.encode(snapshot, session('changed-draft')), /SESSION/);
 const modified = session('draft-1'); modified.intent.operations.push({ id: 'new personal edit' });
 await assert.rejects(source.encode(snapshot, modified), /SESSION/);
 let release; pendingRead = new Promise(resolve => release = resolve);
 const older = source.read(session('old-page')); await new Promise(setImmediate);
 const newer = session('new-page'); await source.read(newer); release();
 await assert.rejects(older, /SESSION/); await source.encode(snapshot, newer);
 assert.equal(source.label({ section: 'rules' }), '分流规则 1 · 内容');
 const downloaded={original:'downloaded',metadata:{origin:'synthetic',sub:{},updatedAt:1}};
 const candidateSource=sandbox.exports.createTemplateUpdateSource({filesDir:'/synthetic'},'one.yaml',downloaded);
 downloaded.original='caller mutation';expectedOriginal='prepared downloaded';
 await candidateSource.read(session('candidate'));await candidateSource.encode(snapshot,session('candidate'));
 paired={original:'paired',metadata:{origin:'synthetic',sub:{},updatedAt:2}};expectedOriginal='prepared paired';
 await source.read(session('restored'));assert.equal(inputs.at(-1).resolvedDraft,true);
 activeVersion='foreign-version';await assert.rejects(source.encode(snapshot,session('restored')),/SOURCE_CHANGED/);activeVersion='version-successful';
 await assert.rejects(candidateSource.read(session('candidate')),/SOURCE_CHANGED/);
 paired=undefined;
 precision = true; await assert.rejects(source.read(session('precise')), /PRECISION/);
 console.log('PASS: real update source uses existing worker/context/provenance, binds candidate encoding and rejects changed/late sessions');
})().catch(error => { console.error(error); process.exitCode = 1; });
