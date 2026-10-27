const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync(path.join(__dirname, '../cexing/entry/src/main/ets/lib/GeoDataAssets.ets'), 'utf8');
const code = ts.transpileModule(source).outputText;
const bundled = new Uint8Array([1, 2, 3, 4]);

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cexing-geodata-'));
  const faults = {};
  const io = {
    OpenMode: { READ_ONLY: 1, WRITE_ONLY: 2, CREATE: 4, NOFOLLOW: 8 },
    accessSync: p => fs.existsSync(p),
    lstatSync: fs.lstatSync,
    openSync(p, flags) {
      const fd = fs.openSync(p, (flags & 2 ? fs.constants.O_WRONLY | fs.constants.O_CREAT : fs.constants.O_RDONLY) | fs.constants.O_NOFOLLOW, 0o600);
      return { fd, tryLock() {}, path: p };
    },
    closeSync: f => fs.closeSync(f.fd),
    readSync: (fd, buffer) => fs.readSync(fd, new Uint8Array(buffer)),
    writeSync(fd, buffer) {
      if (faults.space) throw Error('ENOSPC');
      const data = new Uint8Array(buffer);
      if (faults.corrupt) data[0] = 99;
      const written = fs.writeSync(fd, data);
      if (faults.cancel) faults.cancel.cancelled = true;
      return written;
    },
    fsyncSync: fs.fsyncSync,
    renameSync(from, to) { if (faults.rename) throw Error('rename'); fs.renameSync(from, to); },
    unlinkSync: fs.unlinkSync
  };
  const modules = { '@kit.CoreFileKit': { fileIo: io }, '@kit.CryptoArchitectureKit': { cryptoFramework: {
    createMd() { let bytes; return { update: async v => { bytes = v.data; }, digest: async () => ({ data: crypto.createHash('sha256').update(bytes).digest() }) }; }
  } } };
  const sandbox = { exports: {}, require: n => { assert.ok(n in modules); return modules[n]; }, Uint8Array, ArrayBuffer, Date };
  vm.runInNewContext(code, sandbox);
  const context = { filesDir: root, resourceManager: { getRawFileContent: async name => {
    assert.ok(['geodata/geoip.metadb', 'geodata/geosite.dat'].includes(name));
    if (faults.offline || (faults.geositeMissing && name === 'geodata/geosite.dat')) throw Error('package missing');
    return bundled.slice();
  } } };
  return { assets: sandbox.exports.GeoDataAssets, context, faults, root, target: path.join(root, 'geoip.metadb'), cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

(async () => {
  const f = fixture();
  try {
    assert.equal(await f.assets.inspect(f.context), 'missing');
    assert.deepEqual(fs.readdirSync(f.root), [], 'inspect must be read only');
    await f.assets.restore(f.context, { cancelled: false });
    assert.equal(await f.assets.inspect(f.context), 'ready');
    assert.deepEqual(fs.readFileSync(path.join(f.root, 'geosite.dat')), Buffer.from(bundled));
    fs.unlinkSync(path.join(f.root, 'geosite.dat'));
    assert.equal(await f.assets.inspect(f.context), 'missing');
    await f.assets.restore(f.context, { cancelled: false });
    fs.writeFileSync(f.target, Buffer.from([9, 8]));
    assert.equal(await f.assets.inspect(f.context), 'invalid');
    await f.assets.restore(f.context, { cancelled: false });
    assert.deepEqual(fs.readFileSync(f.target), Buffer.from(bundled));
    // Failure to prepare the second resource keeps its prior file intact.
    const site = path.join(f.root, 'geosite.dat');
    fs.writeFileSync(site, Buffer.from([7, 6]));
    f.faults.geositeMissing = true;
    await assert.rejects(f.assets.restore(f.context, { cancelled: false }));
    assert.deepEqual(fs.readFileSync(site), Buffer.from([7, 6]));
    delete f.faults.geositeMissing;
    await f.assets.restore(f.context, { cancelled: false });
    // An empty prior file is corrupt but recoverable.
    fs.writeFileSync(f.target, Buffer.alloc(0));
    await f.assets.restore(f.context, { cancelled: false });
    for (const fault of ['space', 'corrupt', 'rename', 'offline']) {
      const previous = fs.readFileSync(f.target);
      f.faults[fault] = true;
      await assert.rejects(f.assets.restore(f.context, { cancelled: false }));
      f.faults[fault] = false;
      assert.deepEqual(fs.readFileSync(f.target), previous, `${fault}: last file preserved`);
      assert.ok(fs.readdirSync(f.root).every(name => !name.includes('.restore-')), 'staging cleaned');
    }
    const token = { cancelled: false };
    f.faults.cancel = token;
    await assert.rejects(f.assets.restore(f.context, token), /已取消/);
    delete f.faults.cancel;
    assert.deepEqual(fs.readFileSync(f.target), Buffer.from(bundled));
    await assert.rejects(f.assets.restore(f.context, { cancelled: true }), /已取消/);
    // Queue must recover after rejected operations.
    await Promise.all([f.assets.restore(f.context, { cancelled: false }), f.assets.restore(f.context, { cancelled: false })]);
    const outside = path.join(f.root, 'other'); fs.writeFileSync(outside, Buffer.from([7]));
    fs.unlinkSync(f.target); fs.symlinkSync(outside, f.target);
    await assert.rejects(f.assets.restore(f.context, { cancelled: false }), /Unsafe/);
    assert.deepEqual(fs.readFileSync(outside), Buffer.from([7]));
    console.log('PASS: GeoData read-only status, repair, offline/space/hash/rename rollback, cancellation and symlink boundary');
  } finally { f.cleanup(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
