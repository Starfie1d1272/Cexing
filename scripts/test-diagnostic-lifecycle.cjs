// Actual production phase/owner methods; no SDK rendering or physical VPN claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const { load: controllerFixture, recover } = require('./test-vpn-recovery.cjs');
const flush = () => new Promise(resolve => setImmediate(resolve));
function compile(name) {
  return ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../cexing/entry/src/main/ets/lib',name+'.ets'),'utf8')).outputText;
}
function runtimeFixture() {
  const events=[], phaseListeners=[], statusListeners=[];
  let stopped=false, phaseOff=0, observeOff=0, fail=false;
  const controller={status:0,cancelRecovery(){},needsStop:()=>stopped,
    getLastStopCompleted:()=>stopped?false:null,verify:async()=>{},
    onChanged:fn=>statusListeners.push(fn),
    onPhase:fn=>{phaseListeners.push(fn);return()=>{phaseOff++;phaseListeners.splice(phaseListeners.indexOf(fn),1);};},
    recover:fn=>{events.push('recover');fn(false);}};
  const diagnostics={initialize:ctx=>{events.push('initialize');if(fail)throw Error('synthetic collector');return Promise.resolve(true);},
    observe:ctx=>{events.push('observe');if(fail)throw Error('synthetic collector');return()=>observeOff++;},
    record:(ctx,event)=>{events.push({ctx,event});if(fail)throw Error('synthetic collector');return Promise.resolve(true);}};
  const modules={
    './VpnController':{VpnController:controller,VpnStatus:{Disconnected:0,Connecting:1,Connected:2,Disconnecting:3}},
    './DiagnosticsService':{DiagnosticsService:diagnostics},
    './ConnectionCards':{ConnectionCards:{publish(){}}},
    './LiveViewKeeper':{LiveViewKeeper:{rebindContext(){},start:async()=>true,stop:async()=>{},ensure(){}}},
    './AutoUpdater':{AutoUpdater:{rebindContext(){},start(){},stop(){},checkAndRun:async()=>{}}},
    './Settings':{Settings:{load:()=>({})}},'./Logger':{Logger:{warn(){}}},
    './ProfileTransactions':{ProfileTransactions:{applyPendingRegionSelection:async()=>false,ensureActiveSmartPolicy:async()=>{}}}
  };
  const host={exports:{},require:name=>{assert.ok(name in modules,name);return modules[name];},
    setTimeout:()=>1,clearTimeout(){},setInterval:()=>2,clearInterval(){}};
  vm.runInNewContext(compile('AppRuntime'),host);
  return {runtime:host.exports.AppRuntime,controller,events,phaseListeners,statusListeners,
    counts:()=>({phaseOff,observeOff}), fail:value=>fail=value, unknown:value=>stopped=value,
    emit:s=>{controller.status=s;statusListeners.forEach(fn=>fn(s));}};
}
(async()=>{
  const actual=controllerFixture({throwStart:true});const phases=[];
  actual.options.throwStart={code:201,message:'https://private.example/secret'};
  const detach=actual.VpnController.onPhase(event=>phases.push(event));
  actual.VpnController.onPhase(()=>{throw Error('synthetic recorder failure');});
  assert.equal(actual.VpnController.start(actual.context),false);
  assert.equal(actual.VpnController.status,actual.VpnStatus.Disconnected);
  assert.equal(phases.find(e=>e.stage==='authorization'&&e.outcome==='failed').code,'201');
  assert.equal(phases[0].object,phases[1].object,'phase records retain the same opaque VPN session association');
  assert.ok(!JSON.stringify(phases).includes('private.example'));
  detach();const count=phases.length;actual.VpnController.start(actual.context);assert.equal(phases.length,count);
  const invalid=controllerFixture();invalid.set({tun:false});const invalidEvents=[];
  invalid.VpnController.onPhase(e=>invalidEvents.push(e));await recover(invalid);
  assert.ok(invalidEvents.some(e=>e.stage==='recovery_validation'&&e.outcome==='unknown'));
  assert.equal(invalid.VpnController.start(invalid.context),false);
  assert.ok(invalidEvents.some(e=>e.code==='STOP_NOT_CONFIRMED'));
  const native=controllerFixture({nativeSnapshot:{session:'running-session',dropped:0,events:[
    {sequence:1,stage:'protect',outcome:'failed',code:'201',durationMs:7,message:'https://private.example/token'},
    {sequence:2,stage:'protect',outcome:'failed',code:'https://private.example',durationMs:7}
  ]}});
  const imported=[];native.VpnController.onPhase(e=>imported.push(e));await recover(native);await flush();
  assert.equal(imported.filter(e=>e.stage==='protect').length,1,'only allowlisted fields/codes cross the native bridge');
  assert.ok(!JSON.stringify(imported).includes('private.example'));
  await native.VpnController.stop(native.context);await flush();
  assert.equal(imported.filter(e=>e.stage==='protect').length,1,'re-reading the same session queue cannot duplicate a phase');
  const owner=runtimeFixture(), first={}, second={};
  owner.runtime.initialize(first);assert.deepEqual(owner.events.slice(0,3),['initialize','observe','recover']);
  owner.runtime.initialize(second);assert.deepEqual(owner.counts(),{phaseOff:1,observeOff:1});
  owner.runtime.abilityDestroyed(first);assert.deepEqual(owner.counts(),{phaseOff:1,observeOff:1},'old Ability cannot dispose the current observer');
  owner.emit(2);owner.runtime.abilityDestroyed(second);
  assert.equal(owner.phaseListeners.length,1,'runtime keeps diagnostics while VPN survives window closure');
  owner.emit(0);assert.deepEqual(owner.counts(),{phaseOff:2,observeOff:2});
  const broken=runtimeFixture();broken.fail(true);let ready=0;
  broken.runtime.initialize({},()=>ready++);assert.equal(ready,1,'collector initialization failure cannot gate recovery');
  broken.phaseListeners[0]({operation:'vpn',stage:'authorization',outcome:'failed',code:'201'});
  assert.equal(broken.controller.status,0);
  const helpers={exports:{}};vm.runInNewContext(compile('VpnPhases'),helpers);
  assert.equal(helpers.exports.VpnPhases.code({code:201,message:'secret'},'FIXED'), '201');
  assert.equal(helpers.exports.VpnPhases.code({code:'https://private.example'},'FIXED'), 'FIXED');
  assert.equal(helpers.exports.VpnPhases.valid({sequence:1,stage:'protect',outcome:'failed',code:'201',durationMs:4}),true);
  assert.equal(helpers.exports.VpnPhases.valid({sequence:2,stage:'protect',outcome:'failed',code:'https://private.example',durationMs:4}),false);
  await flush();console.log('PASS: actual lifecycle phases, runtime observer ownership, fixed-code redaction and collector failure isolation');
})().catch(e=>{console.error(e);process.exitCode=1;});
