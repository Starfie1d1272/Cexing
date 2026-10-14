// Exercise the real packaged-model installer with synthetic bytes and a private-file mock.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');

const model = new Uint8Array([1, 2, 3, 4]);
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/SmartModelAssets.ets'), 'utf8');
const code = ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020
} }).outputText;

function fixture(bundled = model) {
  const files = new Map();
  let writes = 0;
  const io = {
    OpenMode: { READ_ONLY: 1, WRITE_ONLY: 2, CREATE: 4, NOFOLLOW: 8 },
    accessSync: p => files.has(p),
    lstatSync: p => {
      if (!files.has(p)) throw Error('missing');
      return { size: files.get(p).length, isSymbolicLink: () => false, isFile: () => true };
    },
    openSync: (p, flags) => {
      if (flags & 2) { files.set(p, new Uint8Array()); writes++; }
      return { fd: { path: p, cursor: 0 } };
    },
    readSync: (fd, buffer) => {
      const src = files.get(fd.path), count = Math.min(src.length - fd.cursor, buffer.byteLength);
      new Uint8Array(buffer).set(src.subarray(fd.cursor, fd.cursor + count)); fd.cursor += count; return count;
    },
    writeSync: (fd, buffer) => { const value = new Uint8Array(buffer); files.set(fd.path, value.slice()); return value.length; },
    fsyncSync() {}, closeSync() {},
    renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); },
    unlinkSync: p => files.delete(p)
  };
  const modules = {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
      let bytes;
      return { update: async value => { bytes = value.data; }, digest: async () => ({ data: crypto.createHash('sha256').update(bytes).digest() }) };
    } } },
    './SmartModelPin': { SMART_MODEL_BYTES: model.length, SMART_MODEL_SHA256: hash(model), SMART_MODEL_RAWFILE: 'smart/Model.bin' }
  };
  const sandbox = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`); return modules[name];
  }, Date, Uint8Array, ArrayBuffer };
  vm.runInNewContext(code, sandbox);
  return { assets: sandbox.exports.SmartModelAssets, files, get writes() { return writes; },
    context: { filesDir: '/private', resourceManager: { getRawFileContent: async () => {
      if (bundled === null) throw Error('no packaged model'); return bundled;
    } } } };
}

(async () => {
  const first = fixture();
  assert.equal((await first.assets.inspect(first.context)).state, 'missing');
  assert.equal(first.writes, 0, 'status must not install');
  assert.equal((await first.assets.prepare(first.context)).state, 'ready');
  assert.equal(hash(first.files.get('/private/Model.bin')), hash(model));
  assert.equal((await first.assets.prepare(first.context)).state, 'ready');
  assert.equal(first.writes, 1, 'Valid installed model should not be rewritten');

  assert.equal((await first.assets.inspect(first.context)).state, 'ready');
  const damaged = fixture();
  damaged.files.set('/private/Model.bin', new Uint8Array([9, 9]));
  assert.equal((await damaged.assets.inspect(damaged.context)).state, 'invalid');
  assert.equal(damaged.writes, 0);
  assert.equal((await damaged.assets.prepare(damaged.context)).state, 'ready');
  assert.deepEqual(Array.from(damaged.files.get('/private/Model.bin.previous')), [9, 9]);
  assert.equal(hash(damaged.files.get('/private/Model.bin')), hash(model));

  const missing = fixture(null);
  assert.equal((await missing.assets.prepare(missing.context)).state, 'missing');
  assert.equal(missing.writes, 0);
  missing.files.set('/private/Model.bin', model);
  assert.equal((await missing.assets.prepare(missing.context)).state, 'ready');

  const corrupt = fixture(new Uint8Array([1, 2, 3, 5]));
  assert.equal((await corrupt.assets.prepare(corrupt.context)).state, 'invalid');
  assert.equal(corrupt.writes, 0);
  console.log('PASS: bundled Smart model first install, reuse, damaged-file backup, missing and invalid fallback');
})().catch(error => { console.error(error); process.exitCode = 1; });
