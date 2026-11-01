const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('./ci/transpile-arkts.cjs');
const source = fs.readFileSync('cexing/entry/src/main/ets/lib/AppTrafficIdentity.ets', 'utf8');
const compiled = ts.transpileModule(source).outputText;
const drain = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function fixture() {
  let now = 0, id = 0, watcher, sendGate = null, activeSends = 0, peakSends = 0;
  const timers = new Map(), lookups = new Map(), sent = [];
  const modules = {
    '@kit.NetworkKit': { connection: { ProtocolType: { PROTO_TYPE_TCP: 1, PROTO_TYPE_UDP: 2 },
      getConnectOwnerUid: (_, local) => new Promise(resolve => lookups.set(local.port, resolve)) } },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } },
    './CoreApi': { CoreApi: { StreamWatcher: class { start(_, cb) { watcher = cb; } stop() { watcher = null; } },
      replyAppIdentities: async (session, replies) => {
        activeSends++; peakSends = Math.max(peakSends, activeSends);
        sent.push({ session, replies });
        try { if (sendGate) await sendGate; return true; } finally { activeSends--; }
      } } }
  };
  const sandbox = { exports: {}, require: key => { assert.ok(key in modules, key); return modules[key]; },
    setTimeout: (fn, delay) => { const key = ++id; timers.set(key, { fn, at: now + delay }); return key; },
    clearTimeout: key => timers.delete(key) };
  vm.runInNewContext(compiled, sandbox);
  const consumer = new sandbox.exports.AppTrafficIdentity(); consumer.start();
  return { consumer, lookups, sent, peak: () => peakSends, gate: value => { sendGate = value; },
    batch: (session, ports) => watcher({ session, requests: ports.map(port => ({ id: String(port), protocol: 'tcp',
      local: { address: '192.0.2.1', family: 1, port }, remote: { address: '198.51.100.1', family: 1, port: 443 } })) }),
    advance: async duration => {
      const until = now + duration; await drain();
      while (true) {
        const first = [...timers.entries()].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!first) break;
        now = first[1].at; timers.delete(first[0]); first[1].fn(); await drain();
      }
      now = until; await drain();
    } };
}
(async () => {
  const fast = fixture(); fast.batch('one', [1, 2]); fast.lookups.get(1)(1001);
  await fast.advance(20);
  assert.equal(fast.sent.length, 1, 'Fast UID must send while another lookup is stalled');
  assert.equal(fast.sent[0].replies[0].uid, 1001);
  await fast.advance(1000);
  assert.equal(fast.sent[1].replies[0].status, 'timeout');
  assert.equal(fast.consumer.lookups, 1, 'Timed-out native lookup retains its concurrency slot');

  const burst = fixture();
  for (let batch = 0; batch < 4; batch++) burst.batch('one', Array.from({ length: 32 }, (_, i) => batch * 32 + i + 1));
  for (const resolve of burst.lookups.values()) resolve(1001);
  await burst.advance(0);
  assert.equal(burst.sent.length, 4, 'Ready replies drain without a 20ms pause for every batch');
  assert.equal(burst.peak(), 1, 'Burst draining retains one HTTP sender');

  const bounded = fixture();
  for (let batch = 0; batch < 8; batch++) bounded.batch('one', Array.from({ length: 32 }, (_, i) => batch * 32 + i + 1));
  assert.equal(bounded.lookups.size, 128);
  await bounded.advance(1100);
  assert.ok(bounded.sent.every(batch => batch.replies.length <= 32));
  bounded.consumer.start(); bounded.batch('two', [900]);
  assert.equal(bounded.lookups.size, 128, 'Restart must not bypass unresolved native lookup slots');
  bounded.lookups.get(1)(1001); await bounded.advance(20);
  assert.ok(bounded.sent.filter(batch => batch.session === 'two').every(batch => batch.replies.every(reply => reply.id === '900')),
    'Late replies from the stopped generation must never enter the new session');

  const serial = fixture(); let release;
  serial.gate(new Promise(resolve => { release = resolve; }));
  serial.batch('one', [1]); serial.lookups.get(1)(1001); await serial.advance(20);
  serial.consumer.start(); serial.batch('two', [2]); serial.lookups.get(2)(1002); await serial.advance(20);
  assert.equal(serial.sent.length, 1, 'A restart must retain the in-flight sender slot');
  release(); await serial.advance(20);
  assert.equal(serial.sent.length, 2); assert.equal(serial.sent[1].session, 'two'); assert.equal(serial.peak(), 1);
  console.log('PASS: independent fast UID replies, bounded timeout slots, session isolation and single reply sender');
})().catch(error => { console.error(error); process.exitCode = 1; });
