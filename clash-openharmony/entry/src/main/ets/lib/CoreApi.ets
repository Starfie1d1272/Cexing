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

interface ConnectionsResp {
  downloadTotal: number;
  uploadTotal: number;
}

export interface TrafficMsg {
  up: number;
  down: number;
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


  async function request(method: http.RequestMethod, path: string, body?: string): Promise<string | null> {
    const access = getControllerAccess();
    if (access === null) {
      return null;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(BASE + path, {
        method: method,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${access.secret}` },
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
   * 单次 REST 取累计流量（LiveViewKeeper 差分采样用）。
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
      return t;
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

  /** 通用流订阅（/traffic /logs）：mihomo 流端点支持 WebSocket upgrade */
  export class StreamWatcher<T> {
    private ws: webSocket.WebSocket | null = null;
    private cb: (msg: T) => void = () => {};
    private path: string = '';
    private stopped: boolean = true;
    private gotFirst: boolean = false;
    private reconnectTimer: number = -1;
    private generation: number = 0;

    start(path: string, cb: (msg: T) => void): void {
      // Do not accept caller-supplied tokens/URLs which could enter logs or history.
      if (!/^\/(traffic|memory|connections|logs)(\?level=(debug|info|warning|error|silent))?$/.test(path)) {
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
            if (!this.gotFirst) {
              this.gotFirst = true;
              Logger.info(TAG, 'ws first message');
            }
            this.cb(JSON.parse(text) as T);
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
      ws.connect(access.wsBase + this.path, {
        header: { 'Authorization': `Bearer ${access.secret}` }
      }).catch(() => {
        reconnect();
      });
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

export function formatRate(bytesPerSec: number): string {
  if (bytesPerSec < 1024) {
    return `${bytesPerSec} B/s`;
  }
  if (bytesPerSec < 1024 * 1024) {
    return `${(bytesPerSec / 1024).toFixed(1)} KB/s`;
  }
  return `${(bytesPerSec / 1024 / 1024).toFixed(2)} MB/s`;
}
