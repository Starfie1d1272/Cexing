// Keep every producer's finite literal/template fields compatible with the privacy vocabulary.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'..');
const backend=fs.readFileSync(path.join(root,'core/diagnostics_fields.go'),'utf8');
const set=name=>new Set(backend.match(new RegExp('const '+name+' = "([^"]+)"'))[1].split(/\s+/));
const stages=set('diagnosticStages'), reasons=set('diagnosticReasons');
const codes=new Set(backend.match(/const fixed = "([^"]+)"/)[1].split(/\s+/));
const controller=fs.readFileSync(path.join(root,'cexing/entry/src/main/ets/lib/VpnController.ets'),'utf8');
const native=fs.readFileSync(path.join(root,'cexing/entry/src/main/ets/vpnability/CexingVpnAbility.ets'),'utf8');
const helper=fs.readFileSync(path.join(root,'cexing/entry/src/main/ets/lib/VpnPhases.ets'),'utf8');
for(const source of [controller,native]) {
 for(const call of source.matchAll(/\b(?:phase|diagnostic)\('([^']+)'([^;]*)\);/g)) {
  assert.ok(stages.has(call[1]),`producer stage lost: ${call[1]}`);
  for(const code of call[2].matchAll(/'([A-Z][A-Z0-9_]+)'/g))assert.ok(codes.has(code[1]),`producer code lost: ${code[1]}`);
 }
 for(const code of source.matchAll(/VpnPhases\.code\([^,]+,\s*'([^']+)'\)/g))assert.ok(codes.has(code[1]),code[1]);
}
const nativeStages=[...helper.match(/const stages: string\[\] = \[([\s\S]*?)\];/)[1].matchAll(/'([^']+)'/g)].map(x=>x[1]);
for(const stage of nativeStages){assert.ok(stages.has(stage),stage);assert.ok(codes.has(`${stage.toUpperCase()}_FAILED`),stage);}
for(const reason of ['extension_event_via_ipc','snapshot_missing_at_stop_return','retired_request_not_collected','native_snapshot_not_collected'])assert.ok(reasons.has(reason),reason);
assert.ok(!stages.has('synthetic_private_identifier')&&!codes.has('SYNTHETIC_PRIVATE_TOKEN'),'vocabulary remains finite, not an identifier-format exemption');
console.log('PASS: all finite lifecycle producer stages/codes/reasons survive the diagnostic privacy vocabulary');
