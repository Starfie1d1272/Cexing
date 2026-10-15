const assert = require('node:assert/strict');
const fs = require('node:fs'), vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const kit = { util: { Base64Helper: class { decodeSync(value) { return Uint8Array.from(Buffer.from(value, 'base64')); } },
  TextDecoder: { create: (_encoding, options) => ({ decodeToString: value => new TextDecoder('utf-8', options).decode(value) }) } } };
const sandbox = { exports: {}, require: name => { assert.equal(name, '@kit.ArkTS'); return kit; } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/ProxyNodeImport.ets', 'utf8')).outputText, sandbox);
const parse = sandbox.exports.ProxyNodeImport.parse;
const b64 = value => Buffer.from(value).toString('base64url');
const ss = parse(`ss://${b64('aes-128-gcm:literal%40secret')}@127.0.0.1:443#Synthetic`);
assert.equal(ss.password, 'literal%40secret', 'base64 credentials must never be percent-decoded twice');
assert.equal(ss.name, 'Synthetic');
assert.equal(parse('ss://aes-128-gcm:literal%40secret@127.0.0.1:443').password, 'literal@secret');
assert.equal(parse(`ss://${b64('aes-128-gcm:synthetic@127.0.0.1:443')}`).password, 'synthetic');
const uuid = '00000000-0000-4000-8000-000000000001';
const vless = parse(`vless://${uuid}@[::1]:443?encryption=none&type=ws&security=tls&sni=example.invalid&host=example.invalid&path=%2Fsynthetic#Node`);
assert.equal(vless.server, '::1'); assert.equal(vless.tls, true); assert.equal(vless['ws-opts'].path, '/synthetic');
assert.equal(parse('trojan://synthetic%3Apassword@127.0.0.1:443?security=tls').password, 'synthetic:password');
const trojanSni = parse('trojan://synthetic@127.0.0.1:443?security=tls&sni=example.invalid');
assert.equal(trojanSni.sni, 'example.invalid'); assert.equal(trojanSni.servername, undefined); assert.equal(trojanSni.tls, undefined);
const vmess = parse('vmess://' + b64(JSON.stringify({ v: '2', ps: 'Synthetic', add: '127.0.0.1', port: '443', id: uuid, aid: '0', net: 'grpc', path: 'synthetic', tls: 'tls' })));
assert.equal(vmess.type, 'vmess'); assert.equal(vmess['grpc-opts']['grpc-service-name'], 'synthetic');
for (const value of ['https://example.invalid', 'ss://broken', 'ss://x@127.0.0.1:0',
  `vless://${uuid}@127.0.0.1:443?type=ws&type=tcp`, `vless://${uuid}@127.0.0.1:443?unexpected=private`,
  `vless://${uuid}@127.0.0.1:443?allowInsecure=1`, `vless://${uuid}@127.0.0.1:443?path=%ZZ`,
  'trojan://synthetic@127.0.0.1:443?security=none', 'ss://aes-128-gcm:synthetic@127.0.0.1:443?plugin=unrecognized',
  'vmess://' + b64(JSON.stringify({ add: '127.0.0.1', port: 443, id: uuid, privateUnknown: 'private-secret' })), 'x'.repeat(8193)]) {
  assert.throws(() => parse(value), error => !error.message.includes('private-secret') && !error.message.includes(uuid));
}
console.log('PASS: SS plain/base64/legacy, VMess, VLESS IPv6/WS and Trojan imports; bounded malformed/duplicate/unknown/insecure input rejection and safe failures');
