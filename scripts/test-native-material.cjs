// Verify actual SDK-transpiled material gating; no native rendering or device claim.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'cexing/entry/src/main/ets/pages/NativeMaterial.ets'), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
  target: ts.ScriptTarget.ES2020 } }).outputText;
function run(api, capable, supported) {
  let queries = 0, materials = 0;
  const calls = [];
  const sandbox = { exports: {}, canIUse: () => capable, Color: { Transparent: 'transparent' },
    BlurStyle: { NONE: 'none' }, require: name => {
      if (name === '@kit.BasicServicesKit') return { deviceInfo: { sdkApiVersion: api } };
      if (name === './NativeTheme') return { NativeTheme: { surface: 'surface' } };
      assert.equal(name, '@kit.ArkUI');
      return { uiMaterial: { isImmersiveMaterialSupported: () => { queries++; return supported; },
        ImmersiveStyle: { THIN: 1 }, ImmersiveMaterial: class { constructor(options) { materials++; this.options = options; } } } };
    } };
  vm.runInNewContext(code, sandbox);
  const { NativeMaterial, NativeTabStyle } = sandbox.exports;
  const tabs = {};
  for (const name of ['barOverlap', 'barHeight', 'barBackgroundColor', 'barBackgroundBlurStyle', 'barFloatingStyle']) {
    tabs[name] = value => { calls.push([name, value]); return tabs; };
  }
  new NativeTabStyle(390).applyNormalAttribute(tabs);
  return { NativeMaterial, calls, queries, materials };
}
for (const [api, capable] of [[21, true], [25, true], [26, false]]) {
  const r = run(api, capable, true);
  assert.equal(r.queries, 0); assert.equal(r.materials, 0);
  assert.ok(!r.calls.some(c => c[0] === 'barFloatingStyle'));
  assert.equal(r.NativeMaterial.contentInset(), 0);
}
const solid = run(26, true, false);
assert.equal(solid.materials, 0);
assert.ok(solid.calls.some(c => c[0] === 'barBackgroundBlurStyle' && c[1] === 'none'));
const glass = run(26, true, true);
assert.equal(glass.materials, 1);
assert.ok(!glass.calls.some(c => c[0] === 'barBackgroundBlurStyle'), 'do not layer blur over system material');
const options = glass.calls.find(c => c[0] === 'barFloatingStyle')[1];
assert.equal(options.barBottomMargin, 8); assert.equal(options.barSideMargin, 16);
assert.equal(options.systemMaterial.options.style, 1);
assert.equal(glass.NativeMaterial.contentInset(), 92);
for (const [width, expected] of [[0, 0], [160, 128], [360, 328], [390, 358], [699, 472], [700, 472], [960, 472]]) {
  assert.equal(glass.NativeMaterial.barWidth(width), expected);
}
for (const scale of [1, 1.3, 1.75]) {
  assert.equal(glass.NativeMaterial.contentInset(scale), 92 + (scale - 1) * 40);
  assert.equal(glass.NativeMaterial.fontGrowth(scale), (scale - 1) * 40);
}
function luminance(hex) {
  const values = hex.slice(1).match(/../g).map(v => parseInt(v, 16) / 255)
    .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
}
for (const variant of ['base', 'dark']) {
  const colors = Object.fromEntries(JSON.parse(fs.readFileSync(path.join(root,
    `cexing/entry/src/main/resources/${variant}/element/color.json`), 'utf8')).color.map(c => [c.name, c.value]));
  for (const [foreground, background] of [['ink', 'surface'], ['muted', 'surface'], ['muted', 'paper'],
    ['accent_text', 'soft'], ['error', 'paper'], ['on_accent', 'action']]) {
    const a = luminance(colors['ui_' + foreground]), b = luminance(colors['ui_' + background]);
    const contrast = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    assert.ok(contrast >= 4.5, `${variant} ${foreground}/${background}: ${contrast}`);
  }
}
console.log('PASS: actual material API gating, solid fallback, no duplicate blur, bounded floating widths/inset and theme text contrast');
