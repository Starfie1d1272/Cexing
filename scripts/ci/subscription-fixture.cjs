const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),ts=require('./transpile-arkts.cjs'),ui=require('./ui-fixtures.cjs');
const box={exports:{},...ui.globals,require:n=>{if(n==='./UiText')return ui.module;throw Error('Unexpected subscription dependency '+n)}};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../../cexing/entry/src/main/ets/lib/SubscriptionInfo.ets'),'utf8')).outputText,box);
module.exports=box.exports;
