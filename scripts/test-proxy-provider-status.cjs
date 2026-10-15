const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let current = { ProfileID: 'synthetic.yaml', ID: 'v1' }, connected = true, session = 's1';
let malformed = false;
let requests = 0, destroyed = 0, failUpdate = false, switchSession = false, uncertain = false;
const modules = {
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET', PUT: 'PUT' }, createHttp: () => ({
    request: async (url, options) => {
      requests++; assert.equal(url, 'http://127.0.0.1:9090/providers/proxies/source%2Fprivate');
      assert.equal(options.header.Authorization, 'Bearer synthetic-access');
      if (switchSession) session = 'new-session';
      if (options.method === 'PUT' && failUpdate) return { responseCode: 503, result: 'private-token-should-never-display' };
      return { responseCode: 200, result: JSON.stringify({ proxies: malformed ? [{ name: 'private-invalid', type: {} }] : [{ name: 'first', type: 'Shadowsocks' }, { name: 'second', type: 'Trojan' }], updatedAt: '2026-10-14T00:00:00Z' }) };
    }, destroy() { destroyed++; } }) } },
  './CoreApi': { CoreApi: { getControllerAccess: () => ({ httpBase: 'http://127.0.0.1:9090', secret: 'synthetic-access' }),
    getControllerSession: async () => session } },
  './EffectiveVersions': { EffectiveVersions: { read: () => ({ Current: current }) } },
  './ProfileStore': { ProfileStore: { getActiveFile: () => current.ProfileID, isApplyUncertain: () => uncertain } },
  './VpnController': { VpnStatus: { Connected: 2 }, VpnController: { get status() { return connected ? 2 : 0; } } }
};
const sandbox = { exports: {}, require: name => modules[name] ?? {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyProviderStatus.ets', 'utf8')).outputText, sandbox);
(async () => {
  const observe = sandbox.exports.ProxyProviderStatus.observe;
  connected = false; let result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', false);
  assert.equal(result.available, false); assert.equal(requests, 0);
  connected = true; result = await observe({}, 'other.yaml', 'v1', 'source/private', true);
  assert.equal(result.available, false); assert.equal(requests, 0, 'inactive source cannot update the running provider');
  uncertain = true; result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', true);
  assert.equal(requests, 0, 'unconfirmed publication cannot query or update a provider'); uncertain = false;
  result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', false);
  assert.equal(result.nodes[0].name, 'first'); assert.equal(result.nodes[1].type, 'Trojan'); assert.equal(result.count, 2); assert.equal(result.available, true); assert.equal(result.refreshed, false);
  failUpdate = true; result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', true);
  assert.equal(result.available, true); assert.equal(result.refreshed, false);
  assert.equal(result.error, '来源更新失败，请重试'); assert.ok(!result.error.includes('private-token'));
  failUpdate = false; malformed = true; result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', false);
  assert.equal(result.available, false); assert.equal(result.nodes.length, 0); assert.ok(!result.error.includes('private-invalid'));
  malformed = false; switchSession = true;
  result = await observe({}, 'synthetic.yaml', 'v1', 'source/private', false);
  assert.equal(result.nodes.length, 0); assert.equal(result.available, false, 'old session result cannot be attributed to current provider');
  assert.equal(destroyed, requests, 'all bounded HTTP requests release their handles');
  console.log('PASS: authenticated pinned provider route, active source/version gate, loaded count, update failure with retained live observation, session changes and request release');
})().catch(error => { console.error(error); process.exitCode = 1; });
