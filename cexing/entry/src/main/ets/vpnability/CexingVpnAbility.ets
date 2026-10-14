import { ZashboardAssets } from '../lib/ZashboardAssets';
import { SmartModelAssets } from '../lib/SmartModelAssets';
/*
 * CexingVpnAbility.ets - VPN 扩展能力(独立进程 :vpn)
 *
 * M0: 打通系统 VPN 授权与 TUN 建立链路
 * M1: 拿到 tun fd 后交给 mihomo 内核（gVisor 用户态栈）:
 *   onCreate    创建 VpnConnection
 *   onConnect   建 TUN -> initCore(homeDir=filesDir) -> startTun(fd, 最小配置)
 *   onDisconnect stopCore -> 销毁 tun
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { rpc } from '@kit.IPCKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Logger } from '../lib/Logger';
import { ProfileStore } from '../lib/ProfileStore';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { CoreApi } from '../lib/CoreApi';
import { ConnectionFailures } from '../lib/ConnectionFailure';
import { NativeVpnPhase, NativeVpnPhases, VpnPhaseOutcome, VpnPhases } from '../lib/VpnPhases';

const TAG = 'vpn';
// 主进程（首页）读取的最近一次启动失败原因
const LAST_ERROR_FILE = 'last_start_error.txt';
// Shared sandbox receipt. Main process accepts it only for the matching start session.
const LAST_STOP_FILE = 'last_stop_result.json';
// 与 lib/VpnController.ets 的 VpnConfig.addresses 保持一致（系统 tun 接口地址）
const TUN_ADDR = '172.19.0.1';
const TUN_PREFIX = 30;

interface CoreTunConfig {
  stack: string;
  address: string;
  mtu: number;
  'dns-hijack': string[];
}

interface CoreDnsConfig {
  enable: boolean;
  listen: string;
  'enhanced-mode': string;
  'fake-ip-range': string;
  nameserver: string[];
  'default-nameserver': string[];
}

interface CoreConfig {
  'mixed-port': number;
  mode: string;
  'log-level': string;
  'external-controller': string;
  ipv6: boolean;
  'find-process-mode': string;
  dns: CoreDnsConfig;
  tun: CoreTunConfig;
}

/** 设置页用户覆写（键名与 Settings.ets 一致，Go 侧做驼峰->kebab 映射）；
 *  mode 为空串=用户未显式选择，Go 侧跳过，沿用订阅配置自带 mode */
interface UserOverrides {
  ipv6: boolean;
  mixedPort: number;
  logLevel: string;
  allowLan: boolean;
  mode: string;
  /** 内核日志是否落盘 mihomo.log（false=仅系统 hilog；wrapper 消费，不进 mihomo 配置） */
  logToFile: boolean;
}

interface StopResult {
  session: string;
  completed: boolean;
}

class CoreStatusRemote extends rpc.RemoteObject {
  private isReady: () => boolean;
  private getError: () => string;
  private getSession: () => string;
  private wasTunCreated: () => boolean;
  private stopSession: (session: string) => Promise<boolean>;
  private getDiagnostics: () => string;

  constructor(isReady: () => boolean, getError: () => string, getSession: () => string,
    wasTunCreated: () => boolean, stopSession: (session: string) => Promise<boolean>, getDiagnostics: () => string) {
    super('CEXING_VPN_ABILITY');
    this.isReady = isReady;
    this.getError = getError;
    this.getSession = getSession;
    this.wasTunCreated = wasTunCreated;
    this.stopSession = stopSession;
    this.getDiagnostics = getDiagnostics;
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
    options: rpc.MessageOption): boolean | Promise<boolean> {
    if (code === 3) { reply.writeString(this.getDiagnostics()); return true; }
    if (code === 2) {
      const session = data.readString();
      const request = data.readString();
      if (request.length === 0 || request.length > 128) { return false; }
      return this.stopSession(session).then((completed: boolean) => {
        reply.writeString(request);
        reply.writeBoolean(completed);
        return true;
      });
    }
    if (code !== 1) {
      return false;
    }
    reply.writeBoolean(this.isReady());
    reply.writeString(this.getError());
    reply.writeString(this.getSession());
    reply.writeBoolean(this.wasTunCreated());
    return true;
  }
}

export default class CexingVpnAbility extends VpnExtensionAbility {
  private connection = new Object() as vpnExtension.VpnConnection;
  private coreStarted = false;
  private coreInitialized = false;
  private startupError = '';
  private starting: Promise<void> | null = null;
  private stopping = false;
  private cleanupPending: Promise<boolean> | null = null;
  private startupPhase: string = 'vpn';
  private startupDiagnosticStage: string = 'tun_create';
  private startupSession: string = '';
  private tunCreateObserved: boolean = false;
  private diagnosticEvents: NativeVpnPhase[] = [];
  private diagnosticSequence: number = 0;
  private diagnosticDropped: number = 0;
  private diagnosticStarted: Map<string, number> = new Map();

  private diagnostic(stage: string, outcome: VpnPhaseOutcome, code: string = ''): void {
    try {
      const now = Date.now();
      if (outcome === 'started') { this.diagnosticStarted.set(stage, now); }
      const durationMs = outcome === 'started' ? 0 : Math.max(0, now - (this.diagnosticStarted.get(stage) ?? now));
      this.diagnosticEvents.push({ sequence: ++this.diagnosticSequence, stage, outcome, code, durationMs });
      if (this.diagnosticEvents.length > 32) { this.diagnosticEvents.shift(); this.diagnosticDropped++; }
    } catch (_) {}
  }

  private diagnosticSnapshot(): string {
    try {
      const snapshot: NativeVpnPhases = { session: this.startupSession, dropped: this.diagnosticDropped, events: this.diagnosticEvents };
      return JSON.stringify(snapshot);
    }
    catch (_) { return ''; }
  }

  /** 记录启动失败原因到 filesDir，主进程（首页）断开回调时读取并提示用户 */
  private writeLastError(msg: string): void {
    try {
      const p = `${this.context.filesDir}/${LAST_ERROR_FILE}`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, msg);
      fileIo.closeSync(f);
    } catch (e) {
      Logger.warn(TAG, `writeLastError failed: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  private clearLastError(): void {
    this.writeLastError('');
  }

  private writeStopResult(session: string, completed: boolean): void {
    try {
      const result: StopResult = { session, completed };
      const path = `${this.context.filesDir}/${LAST_STOP_FILE}`;
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(result));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_) {
      Logger.warn(TAG, 'stop completion record unavailable');
    }
  }

  onCreate(): void {
    Logger.info(TAG, 'CexingVpnAbility.onCreate');
    CoreApi.bindContext(this.context);
    this.connection = vpnExtension.createVpnConnection(this.context);
  }

  onConnect(want: Want): rpc.RemoteObject {
    Logger.info(TAG, 'CexingVpnAbility.onConnect');
    // A recovery bind only observes this process; it must never create a new TUN.
    if (want.parameters?.['RECOVER_ONLY'] === true) {
      return new CoreStatusRemote(() => this.coreStarted && !this.stopping,
        () => this.startupError, () => this.startupSession, () => this.tunCreateObserved, (session: string) => this.stopSession(session), () => this.diagnosticSnapshot());
    }
    if (this.stopping && this.starting !== null) {
      return new CoreStatusRemote(() => false, () => 'VPN 正在停止，请稍后重试',
        () => this.startupSession, () => this.tunCreateObserved, (session: string) => this.stopSession(session), () => this.diagnosticSnapshot());
    }
    if (this.starting !== null) {
      return new CoreStatusRemote(() => this.coreStarted && !this.stopping, () => this.startupError,
        () => this.startupSession, () => this.tunCreateObserved, (session: string) => this.stopSession(session), () => this.diagnosticSnapshot());
    }
    this.cleanupPending = null;
    this.diagnosticEvents = []; this.diagnosticSequence = 0; this.diagnosticDropped = 0; this.diagnosticStarted.clear();
    this.clearLastError();
    this.startupError = '';
    this.startupPhase = 'vpn';
    this.startupSession = want.parameters?.['SESSION_ID'] as string ?? '';
    this.tunCreateObserved = false;
    this.stopping = false;
    this.starting = this.startCore(want);
    return new CoreStatusRemote(() => this.coreStarted, () => this.startupError,
      () => this.startupSession, () => this.tunCreateObserved, (session: string) => this.stopSession(session), () => this.diagnosticSnapshot());
  }

  private async startCore(want: Want): Promise<void> {
    let fd = -1;
    try {
      const config = want.parameters?.['VPN_CONFIG'] as vpnExtension.VpnConfig;
      // Release SDK marks process protection as API 22. Never start unprotected.
      this.startupPhase = 'protect';
      this.startupDiagnosticStage = 'protect';
      if (deviceInfo.sdkApiVersion < 22 || typeof this.connection.protectProcessNet !== 'function') {
        throw new Error('process network protection unavailable');
      }
      const ipv6 = config.isIPv6Accepted === true;
      this.startupDiagnosticStage = 'tun_create';
      this.diagnostic('tun_create', 'started');
      fd = await this.connection.create(config);
      this.diagnostic('tun_create', 'success');
      this.tunCreateObserved = true;
      Logger.info(TAG, `tun fd acquired: ${fd}`);
      this.startupPhase = 'protect';
      this.startupDiagnosticStage = 'protect';
      this.diagnostic('protect', 'started');
      await this.connection.protectProcessNet();
      this.diagnostic('protect', 'success');
      Logger.info(TAG, 'protectProcessNet done, starting mihomo core...');

      const filesDir = this.context.filesDir;
      this.startupPhase = 'assets';
      this.startupDiagnosticStage = 'geodata_prepare';
      this.diagnostic('geodata_prepare', 'started');
      await this.seedGeoData(filesDir);
      this.diagnostic('geodata_prepare', 'success');
      // Install a verified offline model before the Go runtime first attempts to load it.
      // Failure is recoverable: Smart continues with its statistical weights.
      this.startupDiagnosticStage = 'smart_model_prepare';
      this.diagnostic('smart_model_prepare', 'started');
      const smartModel = await SmartModelAssets.prepare(this.context);
      this.diagnostic('smart_model_prepare', smartModel.state === 'ready' ? 'success' : 'skipped',
        smartModel.state === 'ready' ? '' : 'OPTIONAL_MODEL_UNAVAILABLE');
      if (smartModel.state !== 'ready') { Logger.warn(TAG, smartModel.message); }
      // Static resource failure is recoverable; Controller credentials still fail closed.
      this.startupDiagnosticStage = 'panel_assets_prepare';
      this.diagnostic('panel_assets_prepare', 'started');
      const panelAssets = await ZashboardAssets.prepare(this.context);
      this.diagnostic('panel_assets_prepare', panelAssets.directory.length > 0 ? 'success' : 'skipped',
        panelAssets.directory.length > 0 ? '' : 'OPTIONAL_PANEL_UNAVAILABLE');
      this.startupPhase = 'core-init';
      this.startupDiagnosticStage = 'core_initialize';
      this.diagnostic('core_initialize', 'started');
      const initErr: string = await core.initCore(filesDir);
      if (initErr) {
        Logger.error(TAG, 'initCore failed');
        throw new Error(`initCore failed: ${initErr}`);
      }
      Logger.info(TAG, `initCore ok, homeDir=${filesDir}`);
      this.coreInitialized = true;
      this.diagnostic('core_initialize', 'success');

      this.startupPhase = 'config';
      this.startupDiagnosticStage = 'configuration_prepare';
      this.diagnostic('configuration_prepare', 'started');
      const cfg: string = await this.buildCoreConfig();
      this.diagnostic('configuration_prepare', 'success');
      // 用户覆写合并进内核配置：覆写项 > 订阅配置同名键（IPv6 使用本次系统 TUN 快照）
      const hostSettings = want.parameters?.['HOST_SETTINGS'];
      if (typeof hostSettings !== 'string' || hostSettings.length > 4096) { throw new Error('启动设置未确认，请重新连接'); }
      const s = JSON.parse(hostSettings) as UserOverrides;
      if (!Number.isInteger(s.mixedPort) || s.mixedPort < 1 || s.mixedPort > 65535 ||
        !['silent', 'error', 'warning', 'info', 'debug'].includes(s.logLevel) ||
        typeof s.allowLan !== 'boolean' || typeof s.logToFile !== 'boolean' ||
        !['', 'rule', 'global', 'direct'].includes(s.mode)) { throw new Error('启动设置无效，请重新连接'); }
      const overrides: UserOverrides = {
        ipv6: ipv6,
        mixedPort: s.mixedPort,
        logLevel: s.logLevel,
        allowLan: s.allowLan,
        mode: s.mode,
        logToFile: s.logToFile
      };
      Logger.info(TAG,
        `user overrides: mixedPort=${s.mixedPort} logLevel=${s.logLevel} allowLan=${s.allowLan} mode=${s.mode} logToFile=${s.logToFile}`);
      this.startupPhase = 'core-start';
      this.startupDiagnosticStage = 'core_start';
      this.diagnostic('core_start', 'started');
      const startErr: string = await core.startTun(fd, cfg, JSON.stringify(overrides));
      if (startErr) {
        this.startupPhase = startErr.includes('parse configJson') ? 'config' : 'core-start';
        throw new Error(startErr);
      }
      this.coreStarted = true;
      this.diagnostic('core_start', 'success');
      Logger.info(TAG, 'mihomo core started, TUN handed over');
    } catch (e) {
      const stage = this.startupDiagnosticStage;
      this.diagnostic(stage, 'failed', VpnPhases.code(e, `${stage.toUpperCase()}_FAILED`));
      const msg = (e as Error).message ?? JSON.stringify(e);
      this.startupError = ConnectionFailures.encode(this.startupSession,
        ConnectionFailures.classify(this.startupPhase, msg));
      Logger.error(TAG, `onConnect failed: ${this.startupPhase}`);
      this.writeLastError(this.startupError);
      if (this.coreInitialized) {
        try {
          await core.stopCore();
          this.coreStarted = false;
          this.coreInitialized = false;
        } catch (e2) {
          Logger.error(TAG, 'stopCore failed during startup cleanup');
        }
      }
      if (fd > 0) {
        try {
          await this.connection.destroy();
        } catch (e2) {
          Logger.error(TAG, 'VPN destroy failed during startup cleanup');
        }
      }
    }
  }

  private async seedGeoData(filesDir: string): Promise<void> {
    const path = `${filesDir}/geoip.metadb`;
    if (fileIo.accessSync(path) && fileIo.statSync(path).size > 0) {
      return;
    }
    const bytes = await this.context.resourceManager.getRawFileContent('geodata/geoip.metadb');
    const temp = `${path}.tmp`;
    const file = fileIo.openSync(temp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, bytes.buffer);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temp, path);
    Logger.info(TAG, `seeded GeoIP database (${bytes.length} bytes)`);
  }

  private stopSession(session: string): Promise<boolean> {
    if (session !== this.startupSession) { return Promise.resolve(false); }
    if (this.cleanupPending !== null) { return this.cleanupPending; }
    this.stopping = true;
    this.cleanupPending = this.cleanup();
    const pending = this.cleanupPending;
    pending.then((completed: boolean) => {
      if (!completed && this.cleanupPending === pending) { this.cleanupPending = null; }
    });
    return pending;
  }

  onDisconnect(): void {
    Logger.info(TAG, 'CexingVpnAbility.onDisconnect');
    this.stopSession(this.startupSession);
  }

  private async cleanup(): Promise<boolean> {
    const session = this.startupSession;
    let completed = true;
    const pendingStartup = this.starting;
    const tunBeforeStop = this.tunCreateObserved;
    if (tunBeforeStop || pendingStartup !== null || this.coreInitialized) {
      this.diagnostic('tun_destroy', 'started');
      try { await this.connection.destroy(); this.diagnostic('tun_destroy', 'success'); }
      catch (e) { this.diagnostic('tun_destroy', 'failed', VpnPhases.code(e, 'TUN_DESTROY_FAILED')); completed = false; Logger.error(TAG, 'VPN destroy failed'); }
    }
    if (pendingStartup !== null) { await pendingStartup; }
    // A create already in flight may finish after the first destroy attempt.
    if (!tunBeforeStop && this.tunCreateObserved) {
      this.diagnostic('late_tun_destroy', 'started');
      try { await this.connection.destroy(); completed = true; this.diagnostic('late_tun_destroy', 'success'); }
      catch (e) { this.diagnostic('late_tun_destroy', 'failed', VpnPhases.code(e, 'TUN_DESTROY_FAILED')); completed = false; Logger.error(TAG, 'late VPN destroy failed'); }
    }
    if (this.coreInitialized) {
      try {
        this.diagnostic('core_stop', 'started');
        await core.stopCore();
        this.diagnostic('core_stop', 'success');
        Logger.info(TAG, 'mihomo core stopped');
        this.coreStarted = false;
        this.coreInitialized = false;
      } catch (e) {
        this.diagnostic('core_stop', 'failed', VpnPhases.code(e, 'CORE_STOP_FAILED'));
        completed = false;
        Logger.error(TAG, 'stopCore failed');
      }
    }
    this.starting = null;
    this.writeStopResult(session, completed);
    return completed;
  }

  onDestroy(): void {
    Logger.info(TAG, 'CexingVpnAbility.onDestroy');
    if (!this.stopping) {
      this.onDisconnect();
    }
  }

  /**
   * 优先读取原子发布的有效版本；其损坏时拒绝启动。
   * 尚未迁移的旧数据依次读取 active.txt、内置 override.yaml 和最小配置。
   * 返回字符串直接作为 configJson 传给 startTun（Go 侧 yaml 解析，JSON/YAML 均兼容）。
   */
  private async buildCoreConfig(): Promise<string> {
    const effective = EffectiveVersions.read(this.context);
    if (effective !== null && effective.Current !== null && effective.Current !== undefined) {
      const selected = ProfileStore.getActiveContent(this.context);
      if (selected === null || selected.length === 0) { throw new Error('有效配置版本不可读取'); }
      Logger.info(TAG, `config source: effective version, ${selected.length} bytes`);
      return selected;
    }
    try {
      const profile: string | null = ProfileStore.getActiveContent(this.context);
      if (profile !== null && profile.length > 0) {
        Logger.info(TAG, `config source: active profile, ${profile.length} bytes`);
        return profile;
      }
    } catch (e) {
      Logger.warn(TAG, `config source: active profile read failed: ${JSON.stringify(e)}`);
    }
    try {
      const buf: Uint8Array = await this.context.resourceManager.getRawFileContent('override.yaml');
      if (buf && buf.length > 0) {
        const text: string = util.TextDecoder.create('utf-8').decodeToString(buf);
        Logger.info(TAG, `config source: rawfile override.yaml, ${buf.length} bytes`);
        return text;
      }
    } catch (e) {
      Logger.warn(TAG, `config source: rawfile override.yaml read failed: ${JSON.stringify(e)}`);
    }
    const cfg: CoreConfig = {
      'mixed-port': 7890,
      mode: 'rule',
      'log-level': 'info',
      'external-controller': '127.0.0.1:9090',
      ipv6: false,
      'find-process-mode': 'off',
      dns: {
        enable: true,
        listen: '0.0.0.0:1053',
        'enhanced-mode': 'fake-ip',
        'fake-ip-range': '198.18.0.1/16',
        nameserver: ['223.5.5.5', '8.8.8.8'],
        'default-nameserver': ['223.5.5.5', '8.8.8.8']
      },
      tun: {
        stack: 'gvisor',
        address: `${TUN_ADDR}/${TUN_PREFIX}`,
        mtu: 9000,
        'dns-hijack': ['0.0.0.0:53']
      }
    };
    Logger.info(TAG, 'config source: hardcoded default');
    return JSON.stringify(cfg);
  }
}
