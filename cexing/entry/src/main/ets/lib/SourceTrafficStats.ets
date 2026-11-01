import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CoreApi, AppTrafficRow, AppTrafficSummary } from './CoreApi';
import { VpnController, VpnStatus } from './VpnController';
import { trafficPeriod } from './TrafficLedger';
import { SourceTrafficState, SourceBucket, SourceIdentity, SOURCE_JSON_LIMIT,
  restoreSourceTraffic, recordSourceTraffic, sourceRows, markSourceGap } from './SourceTrafficLedger';

export type SourceTrafficPeriod = 'current' | 'today' | 'month' | 'all';
export class SourceTrafficView {
  ready: boolean = false;
  saved: boolean = true;
  partial: boolean = false;
  readFailed: boolean = false;
  historyUnavailable: boolean = false;
  live: AppTrafficSummary | null = null;
  rows: AppTrafficRow[] = [];
  labels: Record<string, string> = {};
  numbers: Record<string, number> = {};
  sampledAt: number = 0;
}
export namespace SourceTrafficStats {
  let state: SourceTrafficState = new SourceTrafficState();
  let store: preferences.Preferences | null = null;
  let loaded: boolean = false;
  let loadUnavailable: boolean = false;
  let loadFailed: boolean = false;
  let saved: boolean = true;
  let recordFailed: boolean = false;
  let readFailed: boolean = false;
  let generation: number = 0;
  let busy: boolean = false;
  let live: AppTrafficSummary | null = null;
  let liveHost: string = '';
  let pending: string | null = null;
  let writer: Promise<void> | null = null;

  export function initialize(context: common.Context): void {
    if (loaded) { return; }
    let text: string;
    try {
      store = preferences.getPreferencesSync(context, { name: 'cexing_source_traffic_v1' });
      const value = store.getSync('ledger', '');
      if (typeof value !== 'string') { loaded = true; loadFailed = true; loadUnavailable = true; saved = false; return; }
      text = value;
    } catch (_) { loadUnavailable = true; saved = false; return; }
    try { state = restoreSourceTraffic(text); saved = true; loadUnavailable = false; }
    catch (_) { loadFailed = true; loadUnavailable = true; saved = false; }
    loaded = true;
  }
  async function writePending(): Promise<void> {
    const target = store;
    if (target === null) { return; }
    while (pending !== null) {
      const text = pending; pending = null;
      try { target.putSync('ledger', text); await target.flush(); saved = pending === null && !recordFailed; }
      catch (_) { saved = false; }
    }
  }
  function persist(): Promise<void> {
    if (!loaded || store === null || loadFailed) { saved = false; return Promise.resolve(); }
    const text = JSON.stringify(state);
    // At most three UTF-8 bytes per UTF-16 code unit: this stays below 6 MiB.
    if (text.length > SOURCE_JSON_LIMIT) { saved = false; return Promise.resolve(); }
    pending = text; saved = false;
    if (writer === null) {
      writer = writePending().finally(() => {
        writer = null;
        if (pending !== null) { persist().catch(() => { saved = false; }); }
      });
    }
    return writer;
  }
  export function invalidate(): void {
    generation++; live = null; liveHost = ''; readFailed = false;
    markSourceGap(state, Date.now());
    persist().catch(() => { saved = false; });
  }
  export async function sample(): Promise<void> {
    if (!loaded || busy || VpnController.status !== VpnStatus.Connected) { return; }
    const host = VpnController.trafficSession();
    if (host.length === 0) { return; }
    const request = generation;
    busy = true;
    try {
      const before = await CoreApi.getControllerSession();
      if (!current(request, host)) { return; }
      const summary = before === null ? null : await CoreApi.getAppTraffic();
      if (!current(request, host)) { return; }
      const after = summary === null ? null : await CoreApi.getControllerSession();
      if (!current(request, host)) { return; }
      if (summary === null || before === null || after !== before || summary.session !== before || summary.state !== 'running') {
        readFailed = true; live = null; liveHost = ''; return;
      }
      const at = Date.now();
      recordFailed = !recordSourceTraffic(state, host, summary, at);
      live = summary; liveHost = host; readFailed = false;
      persist().catch(() => { saved = false; });
    } catch (_) {
      if (current(request, host)) { readFailed = true; live = null; liveHost = ''; }
    } finally { busy = false; }
  }
  function current(request: number, host: string): boolean {
    return request === generation && VpnController.status === VpnStatus.Connected && host === VpnController.trafficSession();
  }
  export async function refreshLive(): Promise<void> { await sample(); }
  export async function setLabel(uid: number, label: string): Promise<boolean> {
    if (!loaded || loadFailed || !Number.isInteger(uid) || uid < 0 || typeof label !== 'string' || label.length > 40) { return false; }
    const identity = state.identities.find((item: SourceIdentity) => item.uid === uid);
    if (identity === undefined) { return false; }
    identity.label = label.trim();
    await persist();
    return saved;
  }
  export function view(period: SourceTrafficPeriod = 'all'): SourceTrafficView {
    const now = trafficPeriod(Date.now());
    const target: SourceBucket = period === 'today' ? state.days.find((item: SourceBucket) => item.key === now.day) ?? new SourceBucket() :
      period === 'month' ? state.months.find((item: SourceBucket) => item.key === now.month) ?? new SourceBucket() : state.all;
    const available = live !== null && VpnController.status === VpnStatus.Connected && liveHost === VpnController.trafficSession();
    const labels: Record<string, string> = {}; const numbers: Record<string, number> = {};
    state.identities.forEach((item: SourceIdentity) => {
      if (item.uid >= 0) { labels[String(item.uid)] = item.label; numbers[String(item.uid)] = item.number; }
    });
    const pendingSession = VpnController.status === VpnStatus.Connected && VpnController.trafficSession() !== state.checkpoint.host;
    const rows = period === 'current' ? (pendingSession ? [] : sourceRows(state, state.checkpoint.rows)) : sourceRows(state, target.rows);
    return { ready: state.startedAt > 0, saved: saved && !loadFailed && !recordFailed,
      partial: recordFailed || (period === 'current' ? state.checkpoint.partial : target.partial),
      readFailed: readFailed, historyUnavailable: loadUnavailable, live: available ? live : null, rows: rows, labels: labels, numbers: numbers,
      sampledAt: state.checkpoint.at };
  }
}
