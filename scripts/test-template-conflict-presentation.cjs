const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('./ci/transpile-arkts.cjs');
const box={exports:{}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/TemplateConflictPresentation.ets','utf8')).outputText,box);
const describe=box.exports.describeTemplateConflict;
const snapshot=entries=>({templateId:'ai',version:1,entries});
const rule=(id,value)=>({id,section:'rules',value});
const request={kind:'subscription',base:snapshot([rule('a','DOMAIN,a.synthetic,Old'),rule('b','DOMAIN,b.synthetic,Old')]),
 mine:snapshot([rule('a','DOMAIN,a.synthetic,Mine A'),rule('b','DOMAIN,b.synthetic,Mine B')]),
 next:snapshot([rule('a','DOMAIN,a.synthetic,New A'),rule('b','DOMAIN,b.synthetic,New B')])};
const a=describe(request,{id:'opaque-one',entity:'a',section:'rules',kind:'edit'});
const b=describe(request,{id:'opaque-two',entity:'b',section:'rules',kind:'edit'});
assert.notEqual(a.title,b.title);assert.match(a.title,/a.synthetic/);assert.match(b.title,/b.synthetic/);
assert.match(a.mine,/Mine A/);assert.match(a.template,/New A/);assert.match(b.mine,/Mine B/);
assert.ok(!JSON.stringify([a,b]).includes('opaque-'));
const mapping={id:'group',section:'proxy-groups',value:{name:'US selector',password:'private: synthetic-token',proxies:['US-one']}};
const privateRequest={kind:'subscription',base:snapshot([mapping]),mine:snapshot([mapping]),next:snapshot([{...mapping,value:{...mapping.value,password:'https://private.invalid/?token=next'}}])};
const hidden=describe(privateRequest,{id:'secret-hash',entity:'group',section:'proxy-groups',kind:'edit',path:['password']});
assert.match(hidden.title,/US selector.*凭据/);assert.ok(!JSON.stringify(hidden).match(/synthetic-token|private.invalid|secret-hash/));
assert.notEqual(hidden.mine,hidden.template);
const deleted=describe({...request,next:snapshot([])},{id:'x',entity:'a',section:'rules',kind:'delete/edit'});
assert.equal(deleted.template,'删除此项');assert.match(deleted.mine,/Mine A/);
const order=describe({...request,next:snapshot([...request.next.entries].reverse())},
 {id:'order-hash',entity:'order',section:'rules',kind:'order'});
assert.notEqual(order.mine,order.template);assert.match(order.mine,/a.synthetic/);assert.match(order.template,/b.synthetic/);
const longList=['US-one','US-two','US-three','US-four'];
const listRequest={...privateRequest,mine:snapshot([{...mapping,value:{...mapping.value,proxies:[...longList,'Mine-tail']}}]),
 next:snapshot([{...mapping,value:{...mapping.value,proxies:[...longList,'New-tail']}}])};
const list=describe(listRequest,{id:'list-hash',entity:'group',section:'proxy-groups',kind:'edit',path:['proxies']});
assert.match(list.mine,/Mine-tail/);assert.match(list.template,/New-tail/);
console.log('PASS: same-section conflicts have stable entity labels and separate choices, private fields/URLs stay hidden and deletions are explicit');
