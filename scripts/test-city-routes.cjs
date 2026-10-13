// Execute the actual locked upstream route builder after the reviewed host patch.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
const source=process.argv[2]; if(!source){console.log('SKIP: optional locked patched Zashboard route fixture; source argument required');process.exit(0);}
const ipaddr=require(path.join(source,'node_modules/ipaddr.js'));
const modules={'@/assembly/connections':{connectionAccessor:()=>({destination:c=>c.destination,hostname:c=>c.host,download:c=>c.downloaded,isDirect:c=>c.direct})},'ipaddr.js':ipaddr};
const context={exports:{},require:k=>modules[k]};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(source,'src/components/overview/earth/routes.ts'),'utf8')).outputText,context);
(async()=>{
 const publicIP={ip:'8.8.8.8',latitude:37.42,longitude:-122.08,city:'Example City',country:'Example'};
 let dns=0,lookups=[];
 const result=await context.exports.buildEarthRoutes([{destination:'8.8.8.8',host:'private.example.invalid',uploadSpeed:1,downloadSpeed:2,downloaded:3,direct:true},{destination:'',host:'another.private.invalid',uploadSpeed:0,downloadSpeed:0,downloaded:0,direct:true}], '', 'en',async ips=>{lookups.push(...ips);return {'8.8.8.8':publicIP};},null,async()=>{dns++;return {};});
 assert.equal(result.origin,null,'unknown origin is not invented');assert.equal(result.routes.length,1);assert.equal(result.routes[0].path.length,1,'destination marker has no invented route arc');assert.equal(result.routes[0].path[0].role,'destination');assert.equal(dns,0,'no extra hostname resolution');assert.deepEqual(Array.from(lookups),['8.8.8.8']);
 console.log('PASS: actual route builder keeps local destination markers, unknown origin and no extra DNS');
})().catch(e=>{console.error(e);process.exitCode=1;});
