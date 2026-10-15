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

function fixture(bundled = model, expected = model) {
  const files = new Map();
  let writes = 0;
  const faults = {};
  const io = {
    OpenMode: { READ_ONLY: 1, WRITE_ONLY: 2, CREATE: 4, NOFOLLOW: 8 },
    accessSync: p => files.has(p),
    lstatSync: p => {
      if (!files.has(p)) throw Error('missing');
      return { size: files.get(p).length, isSymbolicLink: () => false, isFile: () => true };
    },
    openSync: (p, flags) => {
      if (flags & 2) { files.set(p, new Uint8Array()); if (!p.endsWith('model-recovery.lock')) writes++; }
      return { fd: { path: p, cursor: 0 }, tryLock() { if (faults.lock) throw Error('locked'); } };
    },
    readSync: (fd, buffer) => {
      if (faults.firstRead && fd.path === '/private/Model.bin') { faults.firstRead = false; return 0; }
      const src = files.get(fd.path), count = Math.min(src.length - fd.cursor, buffer.byteLength);
      new Uint8Array(buffer).set(src.subarray(fd.cursor, fd.cursor + count)); fd.cursor += count; return count;
    },
    writeSync: (fd, buffer) => { const value = new Uint8Array(buffer).slice(); if (faults.corrupt) value[0] ^= 1; files.set(fd.path, value); return faults.short ? value.length - 1 : value.length; },
    fsyncSync() { if (faults.sync) throw Error('fsync'); }, closeSync() {},
    renameSync: (from, to) => { if (faults.rename && from.endsWith('.bundled.tmp')) throw Error('publish'); files.set(to, files.get(from)); files.delete(from); if (faults.afterPublish && from.endsWith('.bundled.tmp')) files.get(to)[0] ^= 1; },
    unlinkSync: p => files.delete(p)
  };
  io.open = async (...args) => io.openSync(...args);
  io.read = async (fd, buffer, options) => { fd.cursor = options.offset; return io.readSync(fd, buffer); };
  io.write = async (fd, buffer, options) => {
    const value = new Uint8Array(buffer).slice(); if (faults.corrupt) value[0] ^= 1;
    const before=files.get(fd.path), result=new Uint8Array(Math.max(before.length,options.offset+value.length));
    result.set(before);result.set(value,options.offset);files.set(fd.path,result);
    return faults.short ? value.length-1 : value.length;
  };
  io.fsync = async fd => io.fsyncSync(fd);
  io.close = async file => io.closeSync(file);
  const modules = {
    '@kit.CoreFileKit': { fileIo: io },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
      let bytes;
      return { update: async value => { bytes = value.data; }, digest: async () => ({ data: crypto.createHash('sha256').update(bytes).digest() }) };
    } } },
    './SmartModelPin': { SMART_MODEL_BYTES: expected.length, SMART_MODEL_SHA256: hash(expected), SMART_MODEL_RAWFILE: 'smart/Model.bin' }
  };
  const sandbox = { exports: {}, require: name => {
    assert.ok(name in modules, `Missing mock: ${name}`); return modules[name];
  }, Date, Uint8Array, ArrayBuffer };
  vm.runInNewContext(code, sandbox);
  return { assets: sandbox.exports.SmartModelAssets, files, faults, modules, get writes() { return writes; },
    context: { filesDir: '/private', resourceManager: { getRawFileContent: async () => {
      if (bundled === null) throw Error('no packaged model'); return bundled;
    } } } };
}

(async () => {
  const large = new Uint8Array(131077).fill(7); const chunked = fixture(large, large);
  assert.equal((await chunked.assets.prepare(chunked.context)).state, 'ready');
  assert.equal(hash(chunked.files.get('/private/Model.bin')), hash(large));
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
  for (const fault of ['corrupt', 'short', 'sync', 'rename', 'afterPublish']) {
    const broken = fixture(); const previous = new Uint8Array([9, 8, 7]);
    broken.files.set('/private/Model.bin', previous.slice()); broken.faults[fault] = true;
    assert.equal((await broken.assets.prepare(broken.context)).state, 'invalid', fault);
    assert.deepEqual(Array.from(broken.files.get('/private/Model.bin')), Array.from(previous), `${fault}: previous model preserved`);
    assert.ok(!broken.files.has('/private/Model.bin.bundled.tmp'), `${fault}: staging cleaned`);
  }
  const serialized = fixture();
  const concurrent = await Promise.all([serialized.assets.prepare(serialized.context), serialized.assets.prepare(serialized.context)]);
  assert.ok(concurrent.every(result => result.state === 'ready'));
  assert.equal(serialized.writes, 1, 'concurrent prepare calls must not replace each other staging');
  const intact = fixture(); intact.files.set('/private/Model.bin', model.slice());
  intact.faults.firstRead = true; intact.faults.corrupt = true;
  assert.equal((await intact.assets.prepare(intact.context)).state, 'invalid');
  assert.equal(hash(intact.files.get('/private/Model.bin')), hash(model), 'valid prior bytes preserved when initial read was transiently unavailable');
  const missingCorrupt = fixture(); missingCorrupt.faults.corrupt = true;
  missingCorrupt.modules['./SmartModelAssets'] = { SmartModelAssets: missingCorrupt.assets };
  missingCorrupt.modules['./GeoDataAssets'] = { GeoDataAssets: {} };
  missingCorrupt.modules['./ZashboardAssets'] = { ZashboardAssets: {} };
  const recoverySource = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/ResourceRecovery.ets'), 'utf8');
  const recovery = { exports: {}, require: name => missingCorrupt.modules[name] };
  vm.runInNewContext(ts.transpileModule(recoverySource).outputText, recovery);
  await assert.rejects(recovery.exports.ResourceRecovery.restore(missingCorrupt.context, 'model', {cancelled:false}, () => true), /恢复失败/);
  assert.ok(!missingCorrupt.files.has('/private/Model.bin'), 'full-length corrupt write must not publish or claim recovery');
  missingCorrupt.faults.corrupt = false;
  await recovery.exports.ResourceRecovery.restore(missingCorrupt.context, 'model', {cancelled:false}, () => true);
  assert.equal((await missingCorrupt.assets.inspect(missingCorrupt.context)).state, 'ready');
  console.log('PASS: model staged/published hash checks, failed-write preservation/cleanup, serialized recovery and final target guard');
})().catch(error => { console.error(error); process.exitCode = 1; });
