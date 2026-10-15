const uiFixture = require('./ci/ui-fixtures.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/CoreValidator.ets', 'utf8');
const context = { exports: {}, ...uiFixture.globals, require: key => key.endsWith('/UiText') ? uiFixture.module : key.endsWith('/ProfileApplyFeedback') ? require('./ci/semantic-fixture.cjs') : {} };
vm.runInNewContext(ts.transpileModule(source).outputText, context);
const api = context.exports.CoreValidator;
const base = { section: 'rules', before: 5, after: 5, contentChanged: true, kind: 'modified' };
assert.equal(api.describeMergeChange({ ...base, modified: 5 }), '规则：修改 5 项');
assert.equal(api.describeMergeChange({ ...base, modified: 0, reordered: true }), '规则：顺序已调整');
assert.equal(api.describeMergeChange({ ...base, section: 'dns' }), 'DNS：内容已调整');
assert.equal(api.describeMergeChange({ ...base, kind: 'cleared', after: 0 }), '规则：已清空');
assert.equal(api.describeMergePreview({ digest: 'opaque', changes: [], platformChanges: [{ ...base, kind: 'protected' }] }), '1 项使用设备约束');
assert.equal(api.describeMergePreview({ digest: 'opaque', changes: [] }), '无需更改');
assert(!api.describeMergeChange({ ...base, section: 'private-domain.test' }).includes('private-domain'));
console.log('PASS: equal-count replacement, order, clear, protected input and private section presentation');

assert.match(api.describeMergeFailure(Error('RESOURCE_MISSING'), { id: 'app.string.editor_preview_failed' }), /设置.*修复资源/);
assert.match(api.describeMergeFailure(Error('PROVIDER_UNRESOLVED'), { id: 'app.string.editor_preview_failed' }), /更新订阅.*预览/);
assert.match(api.describeMergeFailure(Error('provider 缓存已变化，请重试'), { id: 'app.string.editor_preview_failed' }), /重新预览/);
assert.match(api.describeMergeFailure(Error('版本发布结果未知，请断开 VPN 后检查'), { id: 'app.string.editor_preview_failed' }), /未确认.*断开/);
assert.ok(!api.describeMergeFailure(Error('https://private.invalid/?token=synthetic'), { id: 'app.string.editor_preview_failed' }).includes('private'));

assert.match(api.describeMergeFailure(Error('备份恢复未确认，请重新打开应用后重试'), { id: 'app.string.editor_preview_failed' }), /重新打开应用/);

assert.match(api.describeMergeFailure(Error('配置已保存，地区选择待重连恢复'), { id: 'app.string.editor_apply_failed' }), /配置已保存.*连接页.*重新连接/);
