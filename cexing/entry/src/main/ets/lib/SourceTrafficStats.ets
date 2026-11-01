import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CoreApi, AppTrafficRow, AppTrafficSummary, AppRouteRule, AppRouteStatus } from './CoreApi';
import { VpnController, VpnStatus } from './VpnController';
import { trafficPeriod } from './TrafficLedger';
import { SourceTrafficState, SourceBucket, SourceIdentity, SOURCE_JSON_LIMIT,
  restoreSourceTraffic, recordSourceTraffic, sourceRows, markSourceGap } from './SourceTrafficLedger';

export type SourceTrafficPeriod = 'current' | 'today' | 'month' | 'all';
class SourceRouteCache {
  version: number = 1;
  rules: AppRouteRule[] = [];
}
function validSavedRoutes(rules: AppRouteRule[]): boolean {
  return Array.isArray(rules) && rules.length <= 2048 && rules.every((rule: AppRouteRule, index: number) =>
    rule !== null && typeof rule === 'object' && Number.isInteger(rule.uid) && rule.uid >= 0 && rule.uid <= 2147483647 &&
    typeof rule.target === 'string' && rule.target.length > 0 && rule.target.length <= 256 && typeof rule.available === 'boolean' &&
    rules.findIndex((other: AppRouteRule) => other.uid === rule.uid) === index);
}
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
  routeStatus: AppRouteStatus | null = null;
  savedRoutes: AppRouteRule[] = [];
  routeReadFailed: boolean = false;
}
export namespace SourceTrafficStats {
  let state: SourceTrafficState = new SourceTrafficState();
  let store: preferences.Preferences | null = null;
  let loaded: boolean = false;
  let loadUnavailable: boolean = false;
  let loadFailed: boolean = false;
  let saved: boolean = true;
  let recordFailed: boolean = false;
  let persistRejected: boolean = false;
  let readFailed: boolean = false;
  let generation: number = 0;
  let sampling: Promise<void> | null = null;
  let live: AppTrafficSummary | null = null;
  let liveHost: string = '';
  let routeStatus: AppRouteStatus | null = null;
  let routeHost: string = '';
  let savedRoutes: AppRouteRule[] = [];
  let routeReadFailed: boolean = false;
  let pendingRoutes: string | null = null;
  let pending: string | null = null;
  let writer: Promise<void> | null = null;

  export function initialize(context: common.Context): void {
    if (loaded) { return; }
    let text: string;
    try {
      store = preferences.getPreferencesSync(context, { name: 'cexing_source_traffic_v1' });
      const value = store.getSync('ledger', '');
      text = typeof value === 'string' ? value : '{invalid';
    } catch (_) { loadUnavailable = true; saved = false; return; }
    try { state = restoreSourceTraffic(text); saved = true; loadUnavailable = false; }
    catch (_) { loadFailed = true; loadUnavailable = true; saved = false; }
    try {
      const cache = store.getSync('routes', '');
      if (typeof cache === 'string' && cache.length > 0 && cache.length <= 4 * 1024 * 1024) {
        const decoded = JSON.parse(cache) as SourceRouteCache;
        if (decoded !== null && decoded.version === 1 && validSavedRoutes(decoded.rules)) { savedRoutes = decoded.rules; }
      }
    } catch (_) {} // A display-only cache cannot invalidate the traffic ledger.
    loaded = true;
  }
  async function writePending(): Promise<void> {
    const target = store;
    if (target === null) { return; }
    while (pending !== null || pendingRoutes !== null) {
      const text = pending; pending = null;
      const routes = pendingRoutes; pendingRoutes = null;
      try {
        if (text !== null) { target.putSync('ledger', text); }
        if (routes !== null) { target.putSync('routes', routes); }
        await target.flush(); saved = pending === null && pendingRoutes === null && !recordFailed && !loadFailed && !persistRejected;
      }
      catch (_) { saved = false; }
    }
  }
  function ensureWriter(): Promise<void> {
    if (writer === null && (pending !== null || pendingRoutes !== null)) {
      writer = writePending().finally(() => {
        writer = null;
        if (pending !== null || pendingRoutes !== null) { ensureWriter().catch(() => { saved = false; }); }
      });
    }
    return writer ?? Promise.resolve();
  }
  function persist(): Promise<void> {
    if (!loaded || store === null) { saved = false; return Promise.resolve(); }
    if (!loadFailed) {
      const text = JSON.stringify(state);
      // At most three UTF-8 bytes per UTF-16 code unit: this stays below 6 MiB.
      persistRejected = text.length > SOURCE_JSON_LIMIT;
      if (!persistRejected) { pending = text; }
    }
    saved = false;
    return ensureWriter();
  }
  export function invalidate(): void {
    generation++; live = null; liveHost = ''; readFailed = false;
    routeStatus = null; routeHost = ''; routeReadFailed = false;
    markSourceGap(state, Date.now());
    persist().catch(() => { saved = false; });
  }
  function startSample(): Promise<void> {
    if (sampling !== null) { return sampling; }
    if (!loaded || VpnController.status !== VpnStatus.Connected || VpnController.trafficSession().length === 0) { return Promise.resolve(); }
    sampling = collect(generation, VpnController.trafficSession()).finally(() => { sampling = null; });
    return sampling;
  }
  export async function sample(): Promise<void> {
    if (sampling !== null) { return; }
    await startSample();
  }
  async function collect(request: number, host: string): Promise<void> {
    try {
      const before = await CoreApi.getControllerSession();
      if (!current(request, host)) { return; }
      const summary = before === null ? null : await CoreApi.getAppTraffic().catch(() => null);
      if (!current(request, host)) { return; }
      const routes = before === null ? null : await CoreApi.getAppRoutes().catch(() => null);
      if (!current(request, host)) { return; }
      const after = before === null ? null : await CoreApi.getControllerSession();
      if (!current(request, host)) { return; }
      if (before === null || after !== before) {
        readFailed = true; live = null; liveHost = '';
        routeReadFailed = true; routeStatus = null; routeHost = ''; return;
      }
      if (summary === null || summary.session !== before || summary.state !== 'running') {
        readFailed = true; live = null; liveHost = '';
      } else {
        recordFailed = !recordSourceTraffic(state, host, summary, Date.now());
        live = summary; liveHost = host; readFailed = false;
      }
      if (routes === null || routes.session !== before || routes.state !== 'running' || !validSavedRoutes(routes.rules)) {
        routeReadFailed = true; routeStatus = null; routeHost = '';
      } else {
        routeStatus = routes; routeHost = host; routeReadFailed = false;
        if (routes.storage === 'ready' || (routes.storage === 'writeError' && !routes.blocked)) {
          savedRoutes = routes.rules.map((rule: AppRouteRule): AppRouteRule => ({ uid: rule.uid, target: rule.target, available: rule.available }));
          const cache: SourceRouteCache = { version: 1, rules: savedRoutes };
          pendingRoutes = JSON.stringify(cache);
        }
      }
      persist().catch(() => { saved = false; });
    } catch (_) {
      if (current(request, host)) {
        readFailed = true; live = null; liveHost = '';
        routeReadFailed = true; routeStatus = null; routeHost = '';
      }
    }
  }
  function current(request: number, host: string): boolean {
    return request === generation && VpnController.status === VpnStatus.Connected && host === VpnController.trafficSession();
  }
  export async function refreshLive(): Promise<void> {
    const previous = sampling;
    if (previous !== null) { await previous; }
    await startSample();
  }
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
    return { ready: state.startedAt > 0, saved: saved && !loadFailed && !recordFailed && !persistRejected,
      partial: recordFailed || (period === 'current' ? state.checkpoint.partial : target.partial),
      readFailed: readFailed, historyUnavailable: loadUnavailable, live: available ? live : null, rows: rows, labels: labels, numbers: numbers,
      sampledAt: state.checkpoint.at,
      routeStatus: VpnController.status === VpnStatus.Connected && routeHost === VpnController.trafficSession() ? routeStatus : null,
      savedRoutes: savedRoutes.map((rule: AppRouteRule): AppRouteRule => ({ uid: rule.uid, target: rule.target, available: rule.available })),
      routeReadFailed: routeReadFailed };
  }
}
