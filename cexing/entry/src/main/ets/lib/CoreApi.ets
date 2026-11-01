/*
 * CoreApi.ets - mihomo REST 控制面客户端（主进程 -> :vpn 进程 127.0.0.1:9090）
 * REST 用 http 模块；/traffic 与 /logs 是流式端点，用 WebSocket 订阅。
 * 所有方法失败返回 null/空，不抛异常（VPN 未启动时内核不在）。
 */
import { http, webSocket } from '@kit.NetworkKit';
import { Logger } from './Logger';
import { util } from '@kit.ArkTS';
import { application, common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'coreApi';
const BASE = 'http://127.0.0.1:9090';
const WS_BASE = 'ws://127.0.0.1:9090';
const TIMEOUT = 8000;
const SECRET_FILE = 'controller-security/secret';

/** Sensitive in-memory access for the local panel; never persist or navigate with secret. */
export interface ControllerAccess {
  httpBase: string;
  wsBase: string;
  secret: string;
}

export type ControllerCheck = 'reachable' | 'credentials' | 'authorization' | 'failed';

export interface ControllerUiStatus {
  available: boolean;
  error: string;
}

export interface SmartModelStatus {
  state: string;
  sha256: string;
  predictions: number;
  networkDownload: boolean;
  restartRequired: boolean;
}

export interface SmartGroupStatus {
  useLightGBM: boolean;
}

export interface SmartStatus {
  schemaVersion: number;
  core: string;
  groups: Record<string, SmartGroupStatus>;
  model: SmartModelStatus;
  message: string;
}

export interface SmartModelImport {
  installed: boolean;
  sha256: string;
  restartRequired: boolean;
  message: string;
}

export interface DelayHistory {
  time: string;
  delay: number;
}

export interface ProxyInfo {
  name: string;
  type: string;
  now: string;
  all: string[];
  history: DelayHistory[];
  udp: boolean;
}

export interface ProxiesResp {
  proxies: Record<string, ProxyInfo>;
}

export interface ConfigsResp {
  mode: string;
  'mixed-port': number;
  'allow-lan': boolean;
  'log-level': string;
}

export type ConfigApplyResult = 'applied' | 'rejected' | 'unknown';

interface ConnectionsResp {
  downloadTotal: number;
  uploadTotal: number;
}

export interface TrafficMsg {
  up: number;
  down: number;
}

export interface AppTrafficBytes {
  upload: number;
  download: number;
  connections: number;
  active: number;
}
export interface AppTrafficRoutes {
  proxy: AppTrafficBytes;
  direct: AppTrafficBytes;
  unclassified: AppTrafficBytes;
}
export interface AppTrafficReason {
  at: number;
  route: string;
  rule: string;
  policy: string[];
}
export interface AppTrafficRow {
  bundleVerified: boolean; // Always false until a public verification route exists.
  identityStatus: string;
  uid: number;
  bundleName: string;
  routes: AppTrafficRoutes;
  recent: AppTrafficReason[];
}
export interface AppTrafficSummary {
  schemaVersion: number;
  session: string;
  state: string;
  startedAt: number;
  endedAt: number;
  partial: boolean;
  totals: AppTrafficRoutes;
  apps: AppTrafficRow[];
  identityFailures: Record<string, number>;
}
export interface AppIdentityAddress {
  address: string;
  family: number;
  port: number;
}
export interface AppIdentityRequest {
  id: string;
  protocol: string;
  local: AppIdentityAddress;
  remote: AppIdentityAddress;
}
export interface AppIdentityBatch {
  session: string;
  requests: AppIdentityRequest[];
}
export interface AppIdentityReply {
  id: string;
  uid: number;
  status: string;
}

export namespace CoreApi {
  let filesDir: string = '';

  export function bindContext(context: common.Context): void {
    filesDir = context.filesDir;
  }

  /** Read on each connection, including cold UI-process recovery. Never generate here. */
  export function getControllerAccess(): ControllerAccess | null {
    try {
      if (filesDir.length === 0) {
        filesDir = application.getApplicationContext().createModuleContext('entry').filesDir;
      }
      const secret = fileIo.readTextSync(`${filesDir}/${SECRET_FILE}`);
      if (!/^[0-9a-f]{64}$/.test(secret)) {
        return null;
      }
      return { httpBase: BASE, wsBase: WS_BASE, secret: secret };
    } catch (e) {
      return null; // Missing/corrupt credential must never fall back to anonymous HTTP.
    }
  }


  async function request(method: http.RequestMethod, path: string, body?: string | ArrayBuffer, contentType: string = 'application/json'): Promise<string | null> {
    const access = getControllerAccess();
    if (access === null) {
      return null;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(BASE + path, {
        method: method,
        header: { 'Content-Type': contentType, 'Authorization': `Bearer ${access.secret}` },
        extraData: body,
        connectTimeout: TIMEOUT,
        readTimeout: TIMEOUT
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        return typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      }
      Logger.warn(TAG, `${method} request rejected (${resp.responseCode})`);
      return null;
    } catch (e) {
      Logger.warn(TAG, `${method} request failed`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /** Live TUN session only. An unavailable Controller returns null; no disk fallback. */
  export async function getAppTraffic(): Promise<AppTrafficSummary | null> {
    const response = await request(http.RequestMethod.GET, '/ohos/app-traffic');
    if (response === null || response.length > 1024 * 1024) { return null; }
    try {
      const summary = JSON.parse(response) as AppTrafficSummary;
      return validAppTrafficSummary(summary) ? summary : null;
    } catch (_) { return null; }
  }

  export async function replyAppIdentities(session: string, replies: AppIdentityReply[]): Promise<boolean> {
    if (replies.length === 0 || replies.length > 32) { return false; }
    return await request(http.RequestMethod.POST, '/ohos/app-traffic/identity',
      JSON.stringify({ session: session, replies: replies })) !== null;
  }

  /** Startup UI degradation report; API readiness is independent of this status. */
  export async function getControllerUiStatus(): Promise<ControllerUiStatus | null> {
    const result = await request(http.RequestMethod.GET, '/ohos/ui-status');
    if (result === null) {
      return null;
    }
    try {
      return JSON.parse(result) as ControllerUiStatus;
    } catch (e) {
      return null;
    }
  }

  /** Non-secret Controller generation; distinguishes a new core from old page sessions. */
  export async function getControllerSession(): Promise<string | null> {
    const result = await request(http.RequestMethod.GET, '/ohos/session');
    if (result === null) { return null; }
    try {
      const session = (JSON.parse(result) as Record<string, string>)['session'];
      return typeof session === 'string' && /^[0-9a-f]{32}$/.test(session) ? session : null;
    } catch (_) { return null; }
  }

  /** User diagnosis retains a safe failure category, never response bodies or credentials. */
  export async function checkController(): Promise<ControllerCheck> {
    const access = getControllerAccess();
    if (access === null) { return 'credentials'; }
    const req = http.createHttp();
    try {
      const response = await req.request(access.httpBase + '/version', {
        method: http.RequestMethod.GET,
        header: { 'Authorization': `Bearer ${access.secret}` },
        connectTimeout: 4000, readTimeout: 4000
      });
      if (response.responseCode === 401 || response.responseCode === 403) { return 'authorization'; }
      if (response.responseCode !== 200) { return 'failed'; }
      const version = JSON.parse(typeof response.result === 'string' ? response.result : JSON.stringify(response.result)) as Record<string, string>;
      return typeof version['version'] === 'string' && version['version'].length > 0 ? 'reachable' : 'failed';
    } catch (_) { return 'failed'; }
    finally { req.destroy(); }
  }

  export async function isAlive(): Promise<boolean> {
    return (await request(http.RequestMethod.GET, '/version')) !== null;
  }

  export async function getConfigs(): Promise<ConfigsResp | null> {
    const s = await request(http.RequestMethod.GET, '/configs');
    if (s === null) {
      return null;
    }
    try {
      return JSON.parse(s) as ConfigsResp;
    } catch (e) {
      return null;
    }
  }

  export async function patchMode(mode: string): Promise<boolean> {
    // PATCH 枚举成员 API 26 才加入，低版本系统运行时为 undefined 会退化成 GET；
    // HTTP 方法本质是报文字符串，直接传字面量即可（mihomo REST 正常处理 PATCH）
    const s = await request('PATCH' as http.RequestMethod, '/configs', JSON.stringify({ mode: mode }));
    return s !== null;
  }

  export async function getProxies(): Promise<Record<string, ProxyInfo> | null> {
    const s = await request(http.RequestMethod.GET, '/proxies');
    if (s === null) {
      return null;
    }
    try {
      return (JSON.parse(s) as ProxiesResp).proxies;
    } catch (e) {
      return null;
    }
  }

  export async function selectProxy(group: string, name: string): Promise<boolean> {
    const s = await request(http.RequestMethod.PUT, `/proxies/${encodeURIComponent(group)}`,
      JSON.stringify({ name: name }));
    return s !== null;
  }

  /**
   * 单次 REST 取累计流量（TrafficStats 后台差分采样用）。
   * 注意：/traffic 是无限流式端点（mihomo 每 1s tick 持续输出，REST 单次请求永不结束），
   * 故改取 /connections 的累计总量实现同语义：up=uploadTotal, down=downloadTotal。
   */
  export async function getTraffic(): Promise<TrafficMsg | null> {
    const s = await request(http.RequestMethod.GET, '/connections');
    if (s === null) {
      return null;
    }
    try {
      const r = JSON.parse(s) as ConnectionsResp;
      const t: TrafficMsg = { up: r.uploadTotal, down: r.downloadTotal };
      return validTraffic(t) ? t : null;
    } catch (e) {
      return null;
    }
  }

  /** 出口节点延迟测速：GET /proxies/{name}/delay（gstatic 204 探针）；失败返回 null */
  export async function delayTest(name: string): Promise<number | null> {
    const s = await request(http.RequestMethod.GET,
      `/proxies/${encodeURIComponent(name)}/delay?timeout=3000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`);
    if (s === null) {
      return null;
    }
    try {
      const r = JSON.parse(s) as Record<string, number>;
      const d = r['delay'];
      return typeof d === 'number' ? d : null;
    } catch (e) {
      return null;
    }
  }

  /** 热切换配置：PUT /configs?force=true {"path": 绝对路径}（路径须在 mihomo homeDir 下） */
  export async function reloadConfig(absPath: string, overrides?: string): Promise<boolean> {
    const s = await request(http.RequestMethod.PUT, '/configs?force=true',
      JSON.stringify({ path: absPath, overrides: overrides }));
    return s !== null;
  }


  /** A transport failure cannot establish whether the core accepted the request. */
  export async function applyConfigText(content: string, expectedSession?: string): Promise<ConfigApplyResult> {
    const access = getControllerAccess();
    if (access === null) { return 'unknown'; }
    const req = http.createHttp();
    try {
      const resp = await req.request(BASE + '/configs?force=true', {
        method: http.RequestMethod.PUT,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${access.secret}` },
        extraData: JSON.stringify({ payload: content, expectedSession: expectedSession }),
        connectTimeout: TIMEOUT,
        readTimeout: TIMEOUT
      });
      return resp.responseCode >= 200 && resp.responseCode < 300 ? 'applied' : 'rejected';
    } catch (_) {
      return 'unknown';
    } finally {
      req.destroy();
    }
  }

  export async function getSmartStatus(): Promise<SmartStatus | null> {
    const result = await request(http.RequestMethod.GET, '/smart/status');
    if (result === null) { return null; }
    try {
      const status = JSON.parse(result) as SmartStatus;
      return status.schemaVersion === 1 ? status : null;
    } catch (_) { return null; }
  }

  export async function importSmartModel(bytes: ArrayBuffer): Promise<SmartModelImport | null> {
    if (bytes.byteLength !== 9345218) { return null; }
    const result = await request(http.RequestMethod.POST, '/smart/model', bytes, 'application/octet-stream');
    if (result === null) { return null; }
    try {
      const imported = JSON.parse(result) as SmartModelImport;
      return imported.installed === true ? imported : null;
    } catch (_) { return null; }
  }

  /** 通用流订阅（/traffic /logs）：mihomo 流端点支持 WebSocket upgrade */
  export class StreamWatcher<T> {
    private ws: webSocket.WebSocket | null = null;
    private cb: (msg: T) => void = () => {};
    private path: string = '';
    private stopped: boolean = true;
    private gotFirst: boolean = false;
    private reconnectTimer: number = -1;
    private trafficDeadline: number = -1;
    private generation: number = 0;

    start(path: string, cb: (msg: T) => void): void {
      // Do not accept caller-supplied tokens/URLs which could enter logs or history.
      if (path !== '/ohos/app-traffic/identity' && !/^\/(traffic|memory|connections|logs)(\?level=(debug|info|warning|error|silent))?$/.test(path)) {
        return;
      }
      if (!this.stopped && this.path === path) {
        return;
      }
      this.stop();
      this.stopped = false;
      this.path = path;
      this.cb = cb;
      this.connect(this.generation);
    }

    private retry(generation: number): void {
      if (this.stopped || generation !== this.generation || this.reconnectTimer >= 0) {
        return;
      }
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = -1;
        if (generation === this.generation) {
          this.connect(generation);
        }
      }, 3000);
    }

    private releaseSocket(): void {
      if (this.trafficDeadline >= 0) { clearTimeout(this.trafficDeadline); this.trafficDeadline = -1; }
      const ws = this.ws;
      this.ws = null;
      if (ws === null) {
        return;
      }
      try {
        ws.off('open');
        ws.off('message');
        ws.off('close');
        ws.off('error');
        ws.close().catch(() => {});
      } catch (e) {
        Logger.warn(TAG, 'ws close failed');
      }
    }

    private connect(generation: number): void {
      if (this.stopped || generation !== this.generation) {
        return;
      }
      this.releaseSocket();
      const access = getControllerAccess();
      if (access === null) {
        this.retry(generation);
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      ws.on('open', () => {
        if (this.ws === ws && generation === this.generation) {
          Logger.info(TAG, 'ws open');
        }
      });
      ws.on('message', (_err: Object, value: string | ArrayBuffer) => {
        if (this.stopped || this.ws !== ws || generation !== this.generation) {
          return;
        }
        try {
          let text = '';
          if (typeof value === 'string') {
            text = value;
          } else if (value instanceof ArrayBuffer) {
            text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value));
          }
          if (text.length > 0) {
            const sample = JSON.parse(text) as T;
            if (this.path === '/traffic') {
              if (!validTraffic(sample as TrafficMsg)) { return; }
              this.armTrafficDeadline(ws, generation);
            }
            if (!this.gotFirst) {
              this.gotFirst = true;
              Logger.info(TAG, 'ws first message');
            }
            this.cb(sample);
          }
        } catch (e) {
          // Ignore a malformed message without logging arbitrary payloads.
        }
      });
      const reconnect = (): void => {
        if (this.ws !== ws || generation !== this.generation || this.stopped) {
          return;
        }
        this.releaseSocket();
        this.retry(generation);
      };
      ws.on('close', reconnect);
      ws.on('error', () => {
        Logger.warn(TAG, 'ws connection failed');
        reconnect();
      });
      this.armTrafficDeadline(ws, generation);
      ws.connect(access.wsBase + this.path, {
        header: { 'Authorization': `Bearer ${access.secret}` }
      }).catch(() => {
        reconnect();
      });
    }

    private armTrafficDeadline(ws: webSocket.WebSocket, generation: number): void {
      if (this.path !== '/traffic') { return; }
      if (this.trafficDeadline >= 0) { clearTimeout(this.trafficDeadline); }
      this.trafficDeadline = setTimeout(() => {
        if (this.stopped || this.ws !== ws || generation !== this.generation) { return; }
        this.trafficDeadline = -1;
        this.releaseSocket();
        this.retry(generation);
      }, 5000);
    }

    stop(): void {
      this.stopped = true;
      this.generation++;
      this.gotFirst = false;
      if (this.reconnectTimer >= 0) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = -1;
      }
      this.releaseSocket();
    }
  }
}

export function validTraffic(sample: TrafficMsg): boolean {
  return sample !== null && typeof sample === 'object' &&
    typeof sample.up === 'number' && Number.isFinite(sample.up) && sample.up >= 0 &&
    typeof sample.down === 'number' && Number.isFinite(sample.down) && sample.down >= 0;
}

export function formatRate(bytesPerSec: number): string {
  if (!Number.isFinite(bytesPerSec) || bytesPerSec < 0) { return '—'; }
  if (bytesPerSec < 1024) {
    return `${bytesPerSec} B/s`;
  }
  if (bytesPerSec < 1024 * 1024) {
    return `${(bytesPerSec / 1024).toFixed(1)} KB/s`;
  }
  return `${(bytesPerSec / 1024 / 1024).toFixed(2)} MB/s`;
}

function validAppTrafficRoutes(routes: AppTrafficRoutes): boolean {
  if (routes === null || typeof routes !== 'object') { return false; }
  return [routes.proxy, routes.direct, routes.unclassified].every((value: AppTrafficBytes) => {
    return value !== null && typeof value === 'object' &&
      [value.upload, value.download, value.connections, value.active].every((count: number) =>
        typeof count === 'number' && Number.isFinite(count) && count >= 0);
  });
}

function validAppTrafficSummary(summary: AppTrafficSummary): boolean {
  if (summary === null || typeof summary !== 'object' || summary.schemaVersion !== 1 ||
    typeof summary.session !== 'string' || !/^[0-9a-f]{32}$/.test(summary.session) ||
    (summary.state !== 'running' && summary.state !== 'closed') ||
    typeof summary.partial !== 'boolean' ||
    ![summary.startedAt, summary.endedAt].every((time: number) =>
      typeof time === 'number' && Number.isFinite(time) && time >= 0) ||
    !validAppTrafficRoutes(summary.totals) || !Array.isArray(summary.apps) || summary.apps.length > 129) { return false; }
  return summary.apps.every((row: AppTrafficRow) => row !== null && typeof row === 'object' &&
    (row.identityStatus === 'uid' || row.identityStatus === 'unknown') &&
    typeof row.uid === 'number' && Number.isInteger(row.uid) && row.uid >= -1 &&
    row.bundleName === '' && row.bundleVerified === false &&
    validAppTrafficRoutes(row.routes) && Array.isArray(row.recent) && row.recent.length <= 4);
}
