// Pure production-route A/B fixtures. No device, network or persistent setting changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const sandbox = {exports:{},require:()=>({})};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/VpnController.ets','utf8')).outputText,sandbox);
const {buildVpnRoutes,vpnRouteExceptions}=sandbox.exports;
const expected=['139.9.98.98/32','139.9.99.99/32','139.9.0.0/16','49.4.0.0/16','121.36.0.0/16','125.88.0.0/16','119.147.0.0/16','183.61.0.0/16'];
assert.deepEqual(Array.from(vpnRouteExceptions()),expected);
const changed=vpnRouteExceptions();changed.pop();assert.equal(vpnRouteExceptions().length,8,'callers cannot change defaults');
const fixtures=[];
for(const ipv6 of [false,true]) {
 const baseline=buildVpnRoutes(ipv6);
 assert.equal(baseline.length,ipv6?10:9);
 assert.equal(baseline.filter(r=>r.isDefaultRoute).length,ipv6?2:1);
 assert.equal(baseline.filter(r=>r.isExcludedRoute).length,8);
 for(const cidr of expected) {
  const routes=buildVpnRoutes(ipv6,expected.filter(c=>c!==cidr));
  assert.equal(routes.length,baseline.length-1);
  assert.equal(routes.filter(r=>r.isDefaultRoute).length,ipv6?2:1);
  fixtures.push({ipv6,removed:cidr,baseline,candidate:routes,deviceValidated:false});
 }
}
function matches(ip,cidr) {
 const [address,bits]=cidr.split('/');
 const value=x=>x.split('.').reduce((n,b)=>(n*256+Number(b))>>>0,0);
 const mask=bits==='32'?0xffffffff:(0xffffffff << (32-Number(bits)))>>>0;
 return (value(ip)&mask)===(value(address)&mask);
}
for(const ip of ['139.9.98.98','139.9.1.9','49.4.2.3','121.36.2.3','125.88.2.3','119.147.2.3','183.61.2.3']) assert.ok(expected.some(c=>matches(ip,c)));
for(const ip of ['139.10.0.1','49.5.0.1','192.0.2.1','8.8.8.8']) assert.ok(!expected.some(c=>matches(ip,c)));
if(process.argv.includes('--fixtures')) process.stdout.write(JSON.stringify(fixtures,null,2)+'\n');
else console.log('PASS: preserved route scope, copied defaults, matching/nonmatching traffic and 16 pure per-CIDR A/B fixtures (not device results)');
