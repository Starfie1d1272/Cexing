const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const snapshot = version => ({ templateId: 'ai', version, entries: [] });
let resolved = false, reads = 0, saves = 0, applies = 0, revision = 0, checked, badDigest = false;
let draft = { schemaVersion: 1, revision: 'intent', sourceRevision: 'source', disabled: true,
 operations: [{ id: 'personal', kind: 'delete', section: 'rules', target: 'private-id' }], smartGroups: { 'private-group': false },
 template: { templateId: 'ai', version: 1, targetGroup: 'Pick' } };
const originalPersonal = JSON.stringify({ operations: draft.operations, smartGroups: draft.smartGroups, disabled: draft.disabled });
const session = () => ({ profileId: 'one.yaml', revision: `draft-${revision}`, intent: structuredClone(draft), snapshot: { sourceRevision: 'source', sections: [] } });
const editor = {
 load: async () => session(),
 save: async (intent, expected) => { assert.equal(expected, `draft-${revision}`); saves++; draft = structuredClone(intent); revision++; return session(); },
 preview: async expected => { assert.equal(expected, `draft-${revision}`); checked = { revision: expected, digest: 'digest', changes: { digest: badDigest ? 'wrong' : 'digest', changes: [{ section: 'rules', before: 8, after: 9 }] }, opaque: 'original receipt' }; return checked; },
 apply: async receipt => { assert.equal(receipt, checked); assert.equal(receipt.revision, `draft-${revision}`); applies++; return 'applied'; }
};
const source = {
 read: async () => { reads++; return { kind: 'template', base: snapshot(1), mine: snapshot(1), next: snapshot(2) }; },
 plan: async candidate => ({ templateId: 'ai', version: candidate.version, targetGroup: 'Pick' }),
 label: () => 'AI 规则'
};
const modules = { './EditorDraftHosts': { EditorDraftHosts: { create: () => editor } }, './TemplateUpdates': { TemplateUpdates: { preview: async (_context, request) => {
 assert.equal(request.base.version, 1); assert.equal(request.next.version, 2);
 return resolved ? { ready: true, candidate: snapshot(2), conflicts: [] } : { ready: false, conflicts: [{ id: 'conflict', section: 'rules', entity: 'ai/web', kind: 'edit' }] };
} } } };
const sandbox = { exports: {}, require: name => { assert.ok(name in modules, name); return modules[name]; } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateUpdateHost.ets', 'utf8')).outputText, sandbox);
(async () => {
 const create = sandbox.exports.createTemplateUpdateHost, host = create({}, 'one.yaml', undefined, source);
 const conflict = await host.preview({}); assert.equal(conflict.ready, false); assert.equal(saves, 0);
 await assert.rejects(host.apply(conflict), /STALE/); assert.equal(applies, 0);
 resolved = true; let result = await host.preview({ conflict: 'mine' });
 assert.equal(reads, 1); assert.equal(saves, 1); assert.equal(result.validation.digest, 'digest'); assert.equal(draft.template.version, 2);
 assert.equal(JSON.stringify({ operations: draft.operations, smartGroups: draft.smartGroups, disabled: draft.disabled }), originalPersonal);
 result.validation.digest = 'tampered'; await assert.rejects(host.apply(result), /STALE/); result.validation.digest = 'digest';
 assert.equal(await host.apply(result), '更新已应用'); assert.equal(applies, 1);
 await assert.rejects(host.apply(result), /STALE/);
 await host.preview({}); assert.equal(reads, 2); // read the successful baseline again
 host.reset(); await host.preview({}); assert.equal(reads, 3); // explicit refresh captures fresh inputs
 badDigest = true; await assert.rejects(host.preview({}), /VALIDATION/);
 await assert.rejects(host.apply(result), /STALE/); assert.equal(applies, 1);
 badDigest = false; await host.preview({}); assert.equal(reads, 4); // failed validation permits a fresh retry
 const wrong = create({}, 'other.yaml', editor, source); await assert.rejects(wrong.preview({}), /SESSION/);
 console.log('PASS: actual update Host retains personal edits, gates unresolved/unvalidated drafts, preserves opaque receipt and consumes once');
})().catch(error => { console.error(error); process.exitCode = 1; });
