// Actual ProfileStore + bounded reader; synthetic platform I/O with stage fault hooks.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require('./transpile-arkts.cjs');
exports.create = () => {
  const data = new Map(), dirs = new Set(['/files/profiles']), fds = new Map(), events = [], logs = [], modules = {};
  let sequence = 0, nextFd = 0;
  const env = { data, events, logs, state: null, fault: null, hook: null, networkError: null, code: 200,
    body: 'proxies: [{name: synthetic, type: direct}]', options: [], destroyed: 0 };
  const event = (op, target) => { events.push({op,target}); if(env.hook)env.hook(op,target); if(env.fault)env.fault(op,target); };
  const target = fd => { assert.ok(fds.has(fd),'fd must be open'); return fds.get(fd); };
  const open = (name, flags) => { event('open',name); if(flags!==0)data.set(name,Buffer.alloc(0)); else assert.ok(data.has(name)); const fd=++nextFd;fds.set(fd,name);return {fd}; };
  const write = (fd, value, options) => { const name=target(fd);event('write',name);const bytes=Buffer.from(value),offset=options?.offset??0,n=Math.min(bytes.length,8191);const old=data.get(name),next=Buffer.alloc(Math.max(old.length,offset+n));old.copy(next);bytes.copy(next,offset,0,n);data.set(name,next);return n; };
  const close = file => { const name=target(file.fd);event('close',name);fds.delete(file.fd); };
  const move = (from,to,mode=0) => { event('rename',to);if(mode===1&&data.has(to))throw Error('synthetic destination exists');assert.ok(data.has(from));data.set(to,data.get(from));data.delete(from); };
  const io = { OpenMode:{READ_ONLY:0,READ_WRITE:2,CREATE:64,TRUNC:512},
    accessSync:p=>data.has(p)||dirs.has(p),mkdirSync:p=>dirs.add(p),
    listFileSync:p=>[...data.keys()].filter(n=>n.startsWith(p+'/')&&!n.slice(p.length+1).includes('/')).map(n=>n.slice(p.length+1)),
    readTextSync:(p,o)=>{event('read',p);assert.ok(data.has(p),p);return data.get(p).subarray(o?.offset??0,o?.length===undefined?undefined:(o.offset??0)+o.length).toString()},
    statSync:p=>({size:data.get(p).length,mtime:1}),stat:async p=>({size:data.get(typeof p==='number'?target(p):p).length}),
    openSync:open,writeSync:write,closeSync:close,fsyncSync:fd=>event('sync',target(fd)),moveFileSync:move,
    unlinkSync:p=>{event('unlink',p);data.delete(p)},open:async(...args)=>open(...args),write:async(...args)=>write(...args),
    close:async f=>close(f),fsync:async fd=>event('sync',target(fd)),moveFile:async(...args)=>move(...args),unlink:async p=>{event('unlink',p);data.delete(p)},
    read:async(fd,buffer,options)=>{const bytes=data.get(target(fd));const n=Math.min(buffer.byteLength,Math.max(0,bytes.length-(options?.offset??0)));new Uint8Array(buffer).set(bytes.subarray(options?.offset??0,(options?.offset??0)+n));return n}
  };
  const logger={info:(...args)=>logs.push(args.join(' ')),warn:(...args)=>logs.push(args.join(' ')),error:(...args)=>logs.push(args.join(' '))};
  const failures=require('./import-failure-fixture.cjs').load(logger);
  Object.assign(modules,{'@kit.CoreFileKit':{fileIo:io},'@kit.ArkTS':{util:{generateRandomUUID:()=>`import-${++sequence}`,TextEncoder:{create:()=>({encodeInto:s=>new TextEncoder().encode(s)})},TextDecoder:{create:(_,options)=>{const d=new TextDecoder('utf-8',options);return{decodeToString:(b,o)=>d.decode(b,o)}}}}},
    '@kit.AbilityKit':{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelfSync:()=>({versionName:'0.1.0'})}},
    '@kit.NetworkKit':{http:{RequestMethod:{GET:'GET'},HttpDataType:{STRING:'string'},createHttp:()=>({request:async(url,options)=>{env.options.push(options);if(env.networkError)throw env.networkError;return {responseCode:env.code,result:env.body,header:{'subscription-userinfo':'upload=1; download=2; total=300'}}},destroy:()=>env.destroyed++})}},
    './Logger':{Logger:logger},'./ImportFailure':failures,'./EffectiveVersions':{EffectiveVersions:{read:()=>env.state,editIntent:()=>null}}});
  const load = name => { if(modules[name])return modules[name];const box={exports:{},setTimeout,require:n=>{assert.ok(n in modules||n==='./BoundedFileReader'||n==='./ProfileName',n);return modules[n]??load(n)}};vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../../cexing/entry/src/main/ets/lib',name.replace('./','')+'.ets'),'utf8')).outputText,box);return modules[name]=box.exports; };
  env.store=load('./ProfileStore').ProfileStore;env.reader=load('./BoundedFileReader').BoundedFileReader;env.failures=failures;env.io=io;env.ctx={filesDir:'/files'};env.fds=fds;
  env.text=p=>data.get(p)?.toString();env.put=(p,v)=>data.set(p,Buffer.from(v));
  return env;
};
