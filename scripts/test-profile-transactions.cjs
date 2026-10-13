// Synthetic method-level checks against the actual ArkTS transaction module.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ProfileTransactions.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;
const files = { 'old.yaml': 'proxies: [old]', 'new.yaml': 'proxies: [new]' };
let active = 'old.yaml';
let response = 'applied';
let resolveApply;
let pending = false;
let uncertain = false;
let applies = 0;
let failDiskRollback = false;
const controller = { VpnStatus: { Disconnected: 0, Connected: 2 }, VpnController: { status: 2 } };
const core = { CoreApi: {
  isAlive: async () => true,
  applyConfigText: async () => { applies++; return pending ? await new Promise(resolve => { resolveApply = resolve; }) : response; }
} };
const store = { ProfileStore: {
  isApplyUncertain: () => uncertain,
  markApplyUncertain: () => { uncertain = true; },
  getProfileContent: (_, name) => files[name] ?? null,
  getActiveContent: () => files[active],
  getActiveFile: () => active,
  prepareContent: content => { if (content.includes('bad')) throw new Error('parse'); return content; },
  setActive: (_, name) => { active = name; },
  updateProfileContent: (_, name, content) => {
    if (failDiskRollback) throw new Error('PROFILE_ROLLBACK_FAILED');
    files[name] = content;
  },
  downloadFromOrigin: async () => ({ content: 'proxies: [updated]', meta: {} }),
  commitDownloaded: (_, name, value) => { files[name] = value.content; }
} };
const context = { exports: {}, require: name => {
  if (name.endsWith('CoreApi')) return core;
  if (name.endsWith('ProfileStore')) return store;
  if (name.endsWith('VpnController')) return controller;
  return {};
} };
vm.runInNewContext(js, context);
const tx = context.exports.ProfileTransactions;
(async () => {
  response = 'rejected';
  await assert.rejects(tx.activate({}, 'new.yaml'), /拒绝/);
  assert.equal(active, 'old.yaml');
  await assert.rejects(tx.edit({}, 'old.yaml', 'bad'), /parse/);
  assert.equal(files['old.yaml'], 'proxies: [old]');
  response = 'unknown';
  await assert.rejects(tx.update({}, 'old.yaml'), /未知/);
  assert.equal(files['old.yaml'], 'proxies: [old]');
  await assert.rejects(tx.activate({}, 'new.yaml'), /断开 VPN/);
  controller.VpnController.status = 0;
  uncertain = false; // explicit VPN stop clears the persistent marker
  assert.equal(await tx.activate({}, 'new.yaml'), 'saved');
  assert.equal(active, 'new.yaml');
  controller.VpnController.status = 2;
  response = 'applied';
  pending = true;
  const first = tx.update({}, 'new.yaml');
  await new Promise(resolve => setTimeout(resolve, 0));
  await assert.rejects(tx.edit({}, 'new.yaml', 'proxies: [edit]'), /正在进行/);
  resolveApply('applied');
  assert.equal(await first, 'applied');
  assert.equal(files['new.yaml'], 'proxies: [updated]');
  pending = false;
  const before = applies;
  assert.equal(await tx.activate({}, 'new.yaml'), 'applied');
  assert.equal(applies, before + 1, 'selecting the current file must confirm runtime application');
  failDiskRollback = true;
  await assert.rejects(tx.edit({}, 'new.yaml', 'proxies: [changed]'), /保存配置失败/);
  assert.equal(uncertain, true, 'failed disk rollback must block further activation');
  console.log('PASS: rejected, unknown, parse, and concurrent profile transactions');
})().catch(error => { console.error(error); process.exitCode = 1; });
