// Parse tracked configuration, enforce unsigned builds, scan without printing values.
const fs = require('node:fs');
const cp = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const JSON5 = require('json5');
const YAML = require('yaml');
const root = path.resolve(__dirname, '../..');
process.chdir(root);
const files = cp.execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' }).split('\0').filter(Boolean);
const forbidden = /(?:^|\/)(?:\.signing|command-line-tools|oh_modules|node_modules)(?:\/|$)|\.(?:hap|so|a|p12|pfx|p7b|cer|csr|crt|der|pem|key|jks|keystore)$/i;
const secrets = [
  /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{40,}\b/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /https?:\/\/[^\s'"<>]+[?&](?:token|access_token|authkey)=[A-Za-z0-9%._~-]{16,}/i
];
for (const file of files) {
  assert.ok(!forbidden.test(file), `Forbidden tracked build/credential file: ${file}`);
  const bytes = fs.readFileSync(file);
  if (bytes.includes(0)) continue;
  const text = bytes.toString('utf8');
  for (const rule of secrets) assert.ok(!rule.test(text), `Potential sensitive content in ${file} (value withheld)`);
  if (/\.json5?$/.test(file)) JSON5.parse(text);
  if (/\.ya?ml$/.test(file)) YAML.parse(text, { uniqueKeys: true });
}
const manifest = JSON.parse(fs.readFileSync('scripts/ci/package.json', 'utf8'));
const lock = JSON.parse(fs.readFileSync('scripts/ci/package-lock.json', 'utf8'));
assert.deepEqual(lock.packages[''].dependencies, manifest.dependencies, 'npm lock differs from manifest');
for (const [name, version] of Object.entries(manifest.dependencies)) {
  assert.equal(lock.packages[`node_modules/${name}`].version, version);
  assert.ok(lock.packages[`node_modules/${name}`].integrity && lock.packages[`node_modules/${name}`].license,
    `npm dependency ${name} requires integrity and license metadata`);
}
const project = JSON5.parse(fs.readFileSync('cexing/build-profile.json5', 'utf8'));
assert.deepEqual(project.app.signingConfigs, [], 'CI accepts unsigned builds only');
const native = JSON5.parse(fs.readFileSync('cexing/entry/build-profile.json5', 'utf8'));
assert.deepEqual(native.buildOption.externalNativeOptions.abiFilters, ['arm64-v8a']);
const app = JSON5.parse(fs.readFileSync('cexing/AppScope/app.json5', 'utf8')).app;
assert.equal(app.bundleName, 'com.starfie1d.cexing');
const moduleConfig = JSON5.parse(fs.readFileSync('cexing/entry/src/main/module.json5', 'utf8')).module;
const vpn = moduleConfig.extensionAbilities.find(ability => ability.type === 'vpn');
assert.equal(vpn.name, 'CexingVpnAbility');
assert.ok(fs.existsSync(path.join('cexing/entry/src/main', vpn.srcEntry)), 'VPN entry must resolve');
for (const scope of ['AppScope', 'entry/src/main']) {
  const label = scope === 'AppScope' ? 'app_name' : 'EntryAbility_label';
  for (const [locale, value] of [['base', 'Cexing'], ['zh_CN', '策星']]) {
    const strings = JSON.parse(fs.readFileSync(`cexing/${scope}/resources/${locale}/element/string.json`, 'utf8')).string;
    assert.equal(strings.find(item => item.name === label).value, value);
  }
}
const defaults = YAML.parse(fs.readFileSync('cexing/entry/src/main/resources/rawfile/override.yaml', 'utf8'));
assert.ok(defaults.dns.enable && defaults.rules.includes('MATCH,DIRECT'));
for (const file of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) assert.ok(fs.statSync(file).size > 0);
for (const file of files.filter(f => /oh-package.json5$/.test(f))) {
  const pkg = JSON5.parse(fs.readFileSync(file, 'utf8'));
  for (const version of Object.values(pkg.dependencies || {})) {
    assert.ok(version.startsWith('file:'), `${file}: external ohpm dependency needs a reviewed lockfile`);
  }
}
console.log('PASS: tracked configuration, unsigned profile, source notices and bounded sensitive-content scan');
