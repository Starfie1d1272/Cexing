import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CoreApi, TrafficMsg } from './CoreApi';
import { VpnController, VpnStatus } from './VpnController';
import { TrafficState, TrafficBucket, trafficPeriod, recordTraffic, restoreTraffic, markTrafficGap, validCounter } from './TrafficLedger';

export class TrafficPoint {
  up: number = 0;
  down: number = 0;
  at: number = 0;
}
export class TrafficView {
  current: TrafficBucket = new TrafficBucket();
  today: TrafficBucket = new TrafficBucket();
  month: TrafficBucket = new TrafficBucket();
  saved: boolean = true;
  ready: boolean = false;
  points: TrafficPoint[] = [];
}
export namespace TrafficStats {
  let state: TrafficState = new TrafficState();
  let store: preferences.Preferences | null = null;
  let loaded: boolean = false;
  let saved: boolean = true;
  let busy: boolean = false;
  let generation: number = 0;
  let points: TrafficPoint[] = [];
  let writing: boolean = false;
  let pending: string | null = null;
  let loadFailed: boolean = false;

  export function initialize(context: common.Context): void {
    if (loaded) { return; }
    let json: string;
    try {
      store = preferences.getPreferencesSync(context, { name: 'cexing_traffic_v1' });
      json = store.getSync('ledger', '') as string;
    } catch (_) { saved = false; return; } // Retry at the next foreground/rebind.
    try { state = restoreTraffic(json); saved = true; }
    catch (_) { saved = false; loadFailed = true; } // Preserve corrupt disk evidence.
    loaded = true;
  }
  function persist(): void {
    if (store === null || !loaded || loadFailed) { saved = false; return; }
    pending = JSON.stringify(state);
    if (!writing) { writePending().catch(() => { saved = false; }); }
  }
  async function writePending(): Promise<void> {
    const target = store;
    if (target === null) { return; }
    writing = true;
    try {
      // One writer plus one replaceable latest snapshot. A stalled flush can
      // never accumulate an unbounded Promise/JSON queue.
      while (pending !== null) {
        const json = pending;
        pending = null;
        try { target.putSync('ledger', json); await target.flush(); saved = pending === null; }
        catch (_) { saved = false; }
      }
    } finally { writing = false; }
  }
  export function invalidate(): void {
    generation++;
    points = [];
    markTrafficGap(state, Date.now());
    persist();
  }
  export async function sample(): Promise<void> {
    if (!loaded || busy || VpnController.status !== VpnStatus.Connected) { return; }
    const session = VpnController.trafficSession();
    if (session.length === 0) { return; }
    const request = generation;
    busy = true;
    try {
      const counters: TrafficMsg | null = await CoreApi.getTraffic();
      if (request !== generation || VpnController.status !== VpnStatus.Connected ||
        session !== VpnController.trafficSession()) { return; }
      if (counters === null || !validCounter(counters.up) || !validCounter(counters.down)) { return; } // Same-epoch next sample can recover the delta.
      const at = Date.now();
      const previous = state.checkpoint;
      const elapsed = at - previous.at;
      if (previous.session === session && counters.up >= previous.up && counters.down >= previous.down &&
        elapsed > 0 && elapsed <= 15000) {
        points.push({ up: (counters.up - previous.up) * 1000 / elapsed,
          down: (counters.down - previous.down) * 1000 / elapsed, at: at });
        while (points.length > 60) { points.shift(); }
      } else { points = []; }
      if (recordTraffic(state, session, counters.up, counters.down, at, trafficPeriod(at))) { persist(); }
    } catch (_) {} // Request failures are recoverable from the next cumulative sample.
    finally { busy = false; }
  }
  export function view(): TrafficView {
    const period = trafficPeriod(Date.now());
    const today = state.days.find((b: TrafficBucket) => b.key === period.day);
    const month = state.months.find((b: TrafficBucket) => b.key === period.month);
    return { current: state.current, today: today ?? new TrafficBucket(), month: month ?? new TrafficBucket(),
      saved: saved, ready: state.startedAt > 0, points: points.slice() };
  }
  export function rate(): TrafficMsg | null {
    const point = points.length > 0 ? points[points.length - 1] : null;
    return point !== null && Date.now() - point.at <= 15000 &&
      VpnController.status === VpnStatus.Connected ? { up: point.up, down: point.down } : null;
  }
}
