const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const feedback = require('./ci/load-profile-feedback.cjs');
const box = { exports: {}, require: name => name === './ProfileApplyFeedback' ? feedback : {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/RoutingModel.ets','utf8')).outputText,box);
const { RoutingModel } = box.exports;
(async()=>{
 const legacy = {templateId:'ai',version:1,targetGroup:'Personal Exit'};
 const catalogue = {nodes:{'HK fixture':'香港','JP fixture':'日本','US provider':'美国','mystery':'未知'},providerNodes:{public:['US provider']},directNodes:['HK fixture','JP fixture','mystery'], providers:['public'],regions:['香港','日本','美国','未知'],unknown:1,pending:false,services:[],overlayRulesDigest:'a'.repeat(64)};
 let view, previews=0, applications=0, published=structuredClone(legacy), saved, receipt;
 const host={load:async()=>({groups:[],selectors:[],current:published,published}), catalogue:async()=>catalogue,
  preview:async plan=>{previews++;saved=structuredClone(plan);receipt={revision:`r${previews}`,digest:'digest',summary:'safe preview'};return receipt;},
  apply:async(plan,checked)=>{assert.equal(checked,receipt);assert.deepEqual(JSON.parse(JSON.stringify(plan)),saved);applications++;published=structuredClone(plan);return '方案已应用';},
  smart:async()=>{throw new Error('SMART_NO_COMPATIBLE_GROUP');}};
 const model=new RoutingModel(host,next=>view=next); await model.load();
 assert.equal(view.plan.targetGroup,'Personal Exit'); assert.equal(view.changed,false); assert.equal(applications,0);
 model.recommend(); assert.equal(view.plan.routing.outlets[0].algorithm,'smart'); assert.equal(applications,0);
 const ai=view.plan.routing.outlets[1];
 assert.deepEqual(Array.from(model.selectedNodes(ai,view.plan.routing)),['JP fixture','US provider']);
 ai.scope.regions=['日本','美国']; assert.equal(model.selectedNodes(ai,view.plan.routing).length,2);
 ai.scope.providers=['public']; assert.deepEqual(Array.from(model.selectedNodes(ai,view.plan.routing)),['US provider']);
 const custom=structuredClone(view.plan.routing);custom.outlets[1].algorithm='fallback';custom.outlets[1].scope.regions=['日本'];model.updateRouting(custom);model.subscription();model.manage();assert.equal(view.plan.routing.outlets[1].algorithm,'fallback');assert.equal(view.plan.routing.outlets[1].scope.regions[0],'日本','mode round-trip preserves personalized scope');model.recommend();
 const pendingOutlet=structuredClone(view.plan.routing.outlets[0]);pendingOutlet.scope.providers=['removed'];const priorProviders=catalogue.providerNodes;catalogue.providerNodes=null;assert.equal(model.selectedNodes(pendingOutlet,view.plan.routing).length,0,'missing provider metadata stays an empty pending scope');catalogue.providerNodes=priorProviders;
 await model.inspect(); assert.equal(applications,0,'preview cannot publish'); await model.apply(); assert.equal(applications,1);
 assert.equal(view.changed,false); model.subscription(); assert.equal(view.changed,true); await model.inspect();await model.apply();assert.equal(published.templateId,'original');
 assert.equal(await model.inspect(false,true),false);assert.match(view.message,/没有可转换/);await model.apply();assert.equal(applications,2,'empty Smart preview cannot report applied');
 let resolve; host.preview=()=>new Promise(done=>resolve=done);model.recommend();const pending=model.inspect();model.close();resolve({revision:'late',digest:'late',summary:'late'});assert.equal(await pending,false);await model.apply();assert.equal(applications,2);
 console.log('PASS: routing preserves legacy intent, composes country/provider scopes, separates preview/apply, rejects empty Smart and late completion');
})().catch(error=>{console.error(error);process.exitCode=1;});
