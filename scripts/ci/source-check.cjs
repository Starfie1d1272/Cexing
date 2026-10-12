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
const forbidden = /(?:^|\/)(?:\.signing|command-line-tools|oh_modules|node_modules)(?:\/|$)|\.(?:hap|so|a|p12|pfx|p7b|cer|csr|jks|keystore)$/i;
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
const project = JSON5.parse(fs.readFileSync('clash-openharmony/build-profile.json5', 'utf8'));
assert.deepEqual(project.app.signingConfigs, [], 'CI accepts unsigned builds only');
const native = JSON5.parse(fs.readFileSync('clash-openharmony/entry/build-profile.json5', 'utf8'));
assert.deepEqual(native.buildOption.externalNativeOptions.abiFilters, ['arm64-v8a']);
const defaults = YAML.parse(fs.readFileSync('clash-openharmony/entry/src/main/resources/rawfile/override.yaml', 'utf8'));
assert.ok(defaults.dns.enable && defaults.rules.includes('MATCH,DIRECT'));
for (const file of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) assert.ok(fs.statSync(file).size > 0);
for (const file of files.filter(f => /oh-package.json5$/.test(f))) {
  const pkg = JSON5.parse(fs.readFileSync(file, 'utf8'));
  for (const version of Object.values(pkg.dependencies || {})) {
    assert.ok(version.startsWith('file:'), `${file}: external ohpm dependency needs a reviewed lockfile`);
  }
}
console.log('PASS: tracked configuration, unsigned profile, source notices and bounded sensitive-content scan');
