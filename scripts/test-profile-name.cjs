// Host-only fixture compilation; application syntax is checked by the SDK build.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ProfileName.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } });
const context = { exports: {} };
vm.runInNewContext(compiled.outputText, context);
const suggest = context.exports.suggestProfileName;
const fallback = 'sub_123';
const cases = [
  [{ 'content-disposition': 'attachment; filename=iKuuu_V2.yaml' }, 'iKuuu_V2'],
  [{ 'Content-Disposition': 'attachment; filename="My subscription.yml"' }, 'My subscription'],
  [{ 'content-disposition': "attachment; filename=fallback.yaml; filename*=UTF-8''%E5%B8%B8%E7%94%A8.yaml" }, '常用'],
  [{ 'content-disposition': "attachment; filename*=UTF-8''%ZZ; filename=usable.yaml" }, 'usable'],
  [{ 'content-disposition': 'attachment; filename="../../secret.yaml"' }, fallback],
  [{ 'content-disposition': 'attachment; filename="..\\secret.yaml"' }, fallback],
  [{ 'content-disposition': 'attachment; filename=".yaml"' }, fallback],
  [{ 'content-disposition': 'attachment; filename="bad\nname.yaml"' }, fallback],
  [{ 'content-disposition': 'attachment; filename=' + 'a'.repeat(81) }, fallback],
  [{ 'content-disposition': {} }, fallback],
  [{}, fallback]
];
for (const [headers, expected] of cases) {
  assert.equal(suggest(headers, fallback), expected);
}
console.log(`PASS: ${cases.length} profile-name cases against actual ArkTS helper`);
