const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
let data, position, closed = 0, failRead = false, current = true, short = false;
const io = { OpenMode: { READ_ONLY: 0 }, open: async () => ({ fd: 1 }),
  stat: async () => ({ size: data.length }), close: async () => { closed++; },
  read: async (_, buffer, options) => {
    if (failRead) throw Error('permission/I/O');
    const length = Math.min(buffer.byteLength, data.length - options.offset, short ? 7 : Infinity);
    new Uint8Array(buffer).set(data.subarray(options.offset, options.offset + length));
    return length;
  } };
const sandbox = { exports: {}, setTimeout, require: key => key === '@kit.CoreFileKit' ? { fileIo: io } :
  { util: { TextDecoder: { create: (encoding, options) => { const decoder = new TextDecoder(encoding, options);
    return { decodeToString: (input, options) => decoder.decode(input, options) }; } } } } };
vm.runInNewContext(ts.transpileModule(fs.readFileSync('cexing/entry/src/main/ets/lib/BoundedFileReader.ets', 'utf8')).outputText, sandbox);
const { BoundedFileReader: read, IMPORT_CONFIG_BYTES: limit } = sandbox.exports;
(async () => {
  for (const mib of [1, 8, 16, 32]) {
    data = Buffer.alloc(mib * 1024 * 1024, 65);
    if (data.length > limit) await assert.rejects(read.bytes('synthetic', limit), /上限/);
    else assert.equal((await read.bytes('synthetic', limit)).byteLength, data.length);
  }
  data = Buffer.from('proxies: [合成]'); short = true;
  assert.equal(await read.yaml('synthetic'), data.toString()); short = false;
  data = Buffer.from([0xc0, 0xaf]); await assert.rejects(read.yaml('synthetic'));
  failRead = true; await assert.rejects(read.bytes('synthetic', limit), /I\/O/); failRead = false;
  current = false; const before = closed;
  await assert.rejects(read.bytes('synthetic', limit, () => current), /取消/);
  assert.equal(closed, before, 'cancellation before open owns no fd');
  current = true;
  const originalRead = io.read;
  io.read = async (...args) => { const result = await originalRead(...args); current = false; return result; };
  await assert.rejects(read.bytes('synthetic', limit, () => current), /取消/);
  assert.equal(closed, before + 1, 'in-flight cancellation closes its fd');
  assert.throws(() => read.checkConfigSize('中'.repeat(Math.floor(limit / 3) + 1)), /上限/);
  assert.throws(() => read.checkConfigSize('\ud800'), /编码/);
  const written = Buffer.alloc(100000); let synced = false;
  current = true; io.write = async (_,chunk,options) => { const bytes=Buffer.from(chunk);const n=Math.min(bytes.length,7);bytes.copy(written,options.offset,0,n);return n; };io.fsync=async()=>{synced=true};
  const payload=Buffer.alloc(100000,0x65);await read.write('synthetic',payload.buffer.slice(payload.byteOffset,payload.byteOffset+payload.byteLength),()=>current);
  assert.deepEqual(written,payload);assert.equal(synced,true);
  const fdCount=closed;io.write=async()=>{throw Error('full')};await assert.rejects(read.write('synthetic',new ArrayBuffer(1)),/full/);assert.equal(closed,fdCount+1);
  console.log('PASS: bounded byte limits, short reads, strict UTF-8, I/O errors and cancellation/fd ownership');
})().catch(error => { console.error(error); process.exitCode = 1; });
