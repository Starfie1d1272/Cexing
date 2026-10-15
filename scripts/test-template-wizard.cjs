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
  await failed.inspect(); await failed.apply(); assert.equal(failed.result, '', 'unchanged published plan is inert');
  failed.choose('ai', 'Pick'); await failed.inspect(); await failed.apply(); assert.equal(failed.result, '已保存');
  let dependencyApplies=0;
  const dependent=new Model({load:async()=>inputs(),preview:async(_plan,pause)=>{
    if(!pause)throw Error('TEMPLATE_DEPENDENCIES:2');return preview;
  },apply:async()=>{dependencyApplies++;return '已保存';}},()=>{});
  await dependent.load();dependent.inputs.published = {templateId:'ai',version:1,targetGroup:'Pick'};await dependent.inspect();assert.equal(dependent.dependencies,2);
  assert.equal(dependent.preview,null);await dependent.apply();assert.equal(dependencyApplies,0);
  await dependent.inspect(true);assert.equal(dependent.dependencies,0);assert.equal(dependent.preview,preview);
  await dependent.apply();assert.equal(dependencyApplies,1);
  const regionPlan = {templateId:'region',version:1,region:{mode:'all',selector:'Pick',enable:true,assignments:{a:'日本',b:'美国'}}};
  let draftPlan=structuredClone(regionPlan), regionApplied=0, capturedPlan;
  const regionHost={load:async()=>({...inputs(),current:structuredClone(draftPlan),published:structuredClone(regionPlan)}),
    preview:async plan=>{capturedPlan=JSON.parse(JSON.stringify(plan));draftPlan=structuredClone(capturedPlan);return preview},
    apply:async()=>{regionApplied++;return '已保存'}};
  const regionModel=new Model(regionHost,()=>{});await regionModel.load();
  assert.equal(regionModel.hasChanges(),false);regionModel.choose('region','');assert.equal(regionModel.target,'Pick');
  assert.equal(regionModel.regionPlan().mode,'all');assert.equal(regionModel.hasChanges(),false);
  regionModel.configureRegion('all',{b:'美国',a:'日本'});assert.equal(regionModel.hasChanges(),false,'mapping order is inert');
  regionModel.configureRegion('all',{a:'美国',b:'美国'});assert.equal(regionModel.hasChanges(),true,'same ID and selector with different assignments is a change');
  await regionModel.inspect();assert.equal(capturedPlan.region.mode,'all');assert.equal(regionApplied,0);
  regionModel.choose('region','');assert.equal(regionModel.preview,preview,'selected radio is a no-op, including its receipt');
  regionModel.close();const reentered=new Model(regionHost,()=>{});await reentered.load();
  assert.equal(reentered.hasChanges(),true);assert.equal(reentered.regionPlan().mode,'all');
  assert.equal(reentered.regionPlan().assignments.a,'美国');
  reentered.configureRegion('region',{b:'美国',a:'日本'});assert.equal(reentered.hasChanges(),true,'mode matters even with the same selector and mapping');
  reentered.configureRegion('all',{a:'日本',b:'美国'});assert.equal(reentered.hasChanges(),false);
  const archived=new Model({load:async()=>({...inputs(),regionDraft:regionPlan.region})},()=>{});
  await archived.load();archived.choose('region','');assert.equal(archived.regionPlan().mode,'all');assert.equal(archived.regionPlan().assignments.a,'日本');
  const exitModel=new Model({load:async()=>({...inputs(),current:{templateId:'ai',version:1,targetGroup:'Pick'}})},()=>{});
  await exitModel.load();exitModel.choose('ai','');assert.equal(exitModel.target,'Pick');assert.equal(exitModel.hasChanges(),false);
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
  page.regionOnly=true;page.model.choose('region','Pick');let regionCandidate;
  page.host.preview=async plan=>{regionCandidate=structuredClone(plan);return preview;};dialog=deferred();
  const createOnly=page.apply();dialog.resolve({index:1});await createOnly;
  assert.equal(regionCandidate.region.enable,false);assert.equal(commits,1,'only explicitly confirmed creation publishes');
  console.log('PASS: template page repeated confirmation, cancel/back and page replacement');
})().catch(error => { console.error(error); process.exitCode = 1; });

(async()=>{
 const saved={templateId:'region',version:1,region:{mode:'all',selector:'Pick',enable:true,assignments:{one:'美国'}}};
 let draft=structuredClone(saved),saves=0,applies=0;
 const host={load:async()=>({...inputs(),current:structuredClone(draft),published:structuredClone(saved)}),
   regionPreview:async plan=>{assert.ok(['all','region'].includes(plan.mode));return {eligible:true,providerPending:false,selectors:['Pick'],regions:['美国','日本'],nodes:{one:plan.assignments.one??'美国',two:'日本'},counts:{},unknown:0}},
   preview:async plan=>{saves++;draft=JSON.parse(JSON.stringify(plan));return preview},apply:async()=>{applies++;return '已保存'}};
 const page=new pageSandbox.exports.TemplateWizard();page.host=host;page.aboutToAppear();await new Promise(setImmediate);
 page.openRegionAdvanced();await new Promise(setImmediate);assert.equal(page.regionMode,'all');assert.equal(page.regionAssignments.one,'美国');
 page.regionAssignments={one:'日本'};page.showRegionAdvanced=false;page.regionGeneration++;
 page.openRegionAdvanced();await new Promise(setImmediate);assert.equal(page.regionAssignments.one,'美国','cancelled adjustments do not alter the model');assert.equal(saves,0);
 page.regionAssignments={one:'日本'};await page.refreshRegionPreview();await page.saveRegionDraft();
 assert.equal(draft.region.mode,'all');assert.equal(draft.region.assignments.one,'日本');assert.equal(applies,0);assert.equal(page.showRegionAdvanced,false);
 page.aboutToDisappear();page.aboutToAppear();await new Promise(setImmediate);page.openRegionAdvanced();await new Promise(setImmediate);
 assert.equal(page.regionMode,'all');assert.equal(page.regionAssignments.one,'日本','saved draft survives reentry');assert.equal(page.model.hasChanges(),true);
 console.log('PASS: unified region advanced cancellation, all mode, mapping draft save/reentry and inert publication');
})().catch(error=>{console.error(error);process.exitCode=1});
