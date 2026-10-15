const uiFixture = require('./ci/ui-fixtures.cjs');
// Execute the actual draft model. This is a host state-machine check, not ArkUI.
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const src = fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateWizardModel.ets', 'utf8');
const feedbackBox={exports:{},require:()=>({})};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProfileApplyFeedback.ets','utf8')).outputText,feedbackBox);
const feedback={...feedbackBox.exports.ProfileApplyFeedback,recovery:()=>''};
const sandbox = { exports: {}, require:()=>({ProfileApplyFeedback:feedback}) };
vm.runInNewContext(ts.transpileModule(src).outputText, sandbox);
const Model = sandbox.exports.TemplateWizardModel;
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => { resolve=a; reject=b; }); return { promise, resolve, reject }; };
const inputs = () => ({ groups: ['Pick'], selectors: ['Pick'], current: { templateId: 'original', version: 1 } });
const preview = { revision: 'version-synthetic', digest: 'synthetic', summary: '8 条 AI 规则' };
(async () => {
  let previews = 0, applies = 0;
  let pending = deferred();
  const host = { load: async () => inputs(), preview: () => { previews++; return pending.promise; },
    apply: async (_plan, checked) => { applies++; assert.equal(checked, preview); return '已应用'; } };
  const model = new Model(host, () => {});
  await model.load(); model.choose('ai', 'Pick');
  const inspecting = model.inspect(); await model.inspect();
  assert.equal(previews, 1); assert.equal(model.busy, true);
  model.choose('original', ''); assert.equal(model.templateId, 'ai');
  pending.resolve(preview); await inspecting;
  await Promise.all([model.apply(), model.apply()]); assert.equal(applies, 1);
  model.choose('automatic', 'Pick'); pending = deferred();
  const automatic = model.inspect(); pending.resolve(preview); await automatic;
  await model.apply(); assert.equal(applies, 1); // confirmation required
  await model.apply(true); assert.equal(applies, 2);
  model.choose('original', ''); assert.equal(model.preview, null);

  // Leaving during load, preview or apply suppresses every old result/UI callback.
  for (const phase of ['load', 'preview', 'apply']) {
    const late = deferred(); let changes = 0;
    const fake = { load: async () => inputs(), preview: async () => preview, apply: async () => '已应用' };
    fake[phase] = () => late.promise;
    const page = new Model(fake, () => changes++);
    let operation;
    if (phase === 'load') operation = page.load();
    else { await page.load(); page.choose('ai', 'Pick'); operation = page.inspect();
      if (phase === 'apply') { await operation; operation = page.apply(); } }
    const before = changes; page.close();
    late.resolve(phase === 'load' ? inputs() : phase === 'preview' ? preview : '已应用');
    await operation; assert.equal(changes, before); assert.equal(page.result, '');
  }

  // Failures permit retry; selection changes invalidate a previous preview.
  let fail = true;
  const failed = new Model({ load: async () => inputs(), preview: async () => preview,
    apply: async () => { if (fail) throw Error('synthetic'); return '已保存'; } }, () => {});
  await failed.load(); failed.choose('ai', 'Pick'); await failed.inspect(); await failed.apply();
  assert.equal(failed.preview, null); assert.equal(failed.busy, false); assert.ok(failed.error);
  fail = false; await failed.apply(); assert.equal(failed.result, '');
  await failed.inspect(); failed.choose('original', ''); await failed.apply(); assert.equal(failed.result, '');
  await failed.inspect(); await failed.apply(); assert.equal(failed.result, '已保存');
  console.log('PASS: template wizard duplicate clicks, confirmation, failure retry and late results');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Execute the real page's event methods, excluding only the ArkUI builder DSL.
let pageSource = fs.readFileSync('cexing/entry/src/main/ets/pages/TemplateWizard.ets', 'utf8');
pageSource = pageSource.slice(0, pageSource.indexOf('  @Builder')) + '\n}';
pageSource = pageSource.replace(/@Consume\('[^']*'\) /g, '').replace(/@Component\n/g, '').replace(/@(State|Prop|Consume) /g, '').replace('export struct ', 'export class ');
let dialog = deferred(), dialogs = 0;
const pageSandbox = { exports: {}, getContext: () => ({}), $r: () => '', require: name => {
  if (name.endsWith('/UiText')) return uiFixture.module;
  if(name.endsWith('/ProfileApplyFeedback'))return {ProfileApplyFeedback:feedback};
  if (name === '@kit.ArkUI') return { promptAction: { showDialog: () => { dialogs++; return dialog.promise; } } };
  if (name === '../lib/AiProbeBinding') return { AiProbeBinding: class { revision() { return ''; } } };
  if (name === './NativeTheme') return { NativeTheme: {} };
  if (name === '../lib/TemplateHost') return { createTemplateWizardHost: () => { throw Error('explicit test host expected'); } };
  return { TemplateWizardModel: Model };
} };
Object.assign(pageSandbox, uiFixture.globals);
vm.runInNewContext(ts.transpileModule(pageSource).outputText, pageSandbox);
(async () => {
  let commits = 0, closed = 0;
  const page = new pageSandbox.exports.TemplateWizard();
  page.host = { load: async () => inputs(), preview: async () => preview,
    apply: async () => { commits++; return '已应用'; } };
  page.onClose = () => closed++;
  page.aboutToAppear(); await new Promise(setImmediate);
  assert.equal(page.model.ready, true); page.model.choose('automatic', 'Pick'); await page.model.inspect();
  assert.equal(page.model.templateId, 'automatic'); assert.ok(page.model.preview);
  const first = page.apply(); await page.apply(); assert.equal(dialogs, 1);
  dialog.resolve({ index: 0 }); await first; assert.equal(commits, 0);
  dialog = deferred(); const second = page.apply(); page.close(); dialog.resolve({ index: 1 });
  await second; assert.equal(commits, 0); assert.equal(closed, 1);
  // An old page's dialog cannot apply into a newly entered page.
  dialog = deferred(); page.aboutToAppear(); await new Promise(setImmediate);
  assert.equal(page.model.ready, true); page.model.choose('automatic', 'Pick'); await page.model.inspect();
  assert.equal(page.model.templateId, 'automatic'); assert.ok(page.model.preview);
  const third = page.apply(); page.aboutToDisappear(); page.aboutToAppear();
  dialog.resolve({ index: 1 }); await third; assert.equal(commits, 0);
  dialog = deferred();
  page.model.choose('ai', 'Pick');
  page.host.preview = async () => ({ ...preview, inactiveEdits: true });
  await page.model.inspect();
  const inactive = page.apply();
  assert.equal(page.confirming, true); dialog.resolve({ index: 0 }); await inactive;
  assert.equal(commits, 0);
  console.log('PASS: template page repeated confirmation, cancel/back and page replacement');
})().catch(error => { console.error(error); process.exitCode = 1; });
