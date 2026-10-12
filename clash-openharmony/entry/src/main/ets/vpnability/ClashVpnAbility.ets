/*
 * ClashVpnAbility.ets - VPN 扩展能力(独立进程 :vpn)
 *
 * M0: 打通系统 VPN 授权与 TUN 建立链路
 * M1: 拿到 tun fd 后交给 mihomo 内核（gVisor 用户态栈）:
 *   onCreate    创建 VpnConnection
 *   onConnect   建 TUN -> initCore(homeDir=filesDir) -> startTun(fd, 最小配置)
 *   onDisconnect stopCore -> 销毁 tun
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { rpc } from '@kit.IPCKit';
import { Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Logger } from '../lib/Logger';
import { ProfileStore } from '../lib/ProfileStore';
import { Settings } from '../lib/Settings';
import { CoreApi } from '../lib/CoreApi';

const TAG = 'vpn';
// 主进程（首页）读取的最近一次启动失败原因
const LAST_ERROR_FILE = 'last_start_error.txt';
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
  mixedPort: number;
  logLevel: string;
  allowLan: boolean;
  mode: string;
  /** 内核日志是否落盘 mihomo.log（false=仅系统 hilog；wrapper 消费，不进 mihomo 配置） */
  logToFile: boolean;
}

class CoreStatusRemote extends rpc.RemoteObject {
  private isReady: () => boolean;
  private getError: () => string;

  constructor(isReady: () => boolean, getError: () => string) {
    super('CLASHOH_VPN_ABILITY');
    this.isReady = isReady;
    this.getError = getError;
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
    options: rpc.MessageOption): boolean {
    if (code !== 1) {
      return false;
    }
    reply.writeBoolean(this.isReady());
    reply.writeString(this.getError());
    return true;
  }
}

export default class ClashVpnAbility extends VpnExtensionAbility {
  private connection = new Object() as vpnExtension.VpnConnection;
  private coreStarted = false;
  private coreInitialized = false;
  private startupError = '';
  private starting: Promise<void> | null = null;
  private stopping = false;

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

  onCreate(): void {
    Logger.info(TAG, 'ClashVpnAbility.onCreate');
    CoreApi.bindContext(this.context);
    this.connection = vpnExtension.createVpnConnection(this.context);
  }

  onConnect(want: Want): rpc.RemoteObject {
    Logger.info(TAG, 'ClashVpnAbility.onConnect');
    if (this.stopping && this.starting !== null) {
      return new CoreStatusRemote(() => false, () => 'VPN 正在停止，请稍后重试');
    }
    if (this.starting !== null) {
      return new CoreStatusRemote(() => this.coreStarted && !this.stopping, () => this.startupError);
    }
    this.clearLastError();
    this.startupError = '';
    this.stopping = false;
    this.starting = this.startCore(want);
    return new CoreStatusRemote(() => this.coreStarted, () => this.startupError);
  }

  private async startCore(want: Want): Promise<void> {
    let fd = -1;
    try {
      const config = want.parameters?.['VPN_CONFIG'] as vpnExtension.VpnConfig;
      fd = await this.connection.create(config);
      Logger.info(TAG, `tun fd acquired: ${fd}`);
      await this.connection.protectProcessNet();
      Logger.info(TAG, 'protectProcessNet done, starting mihomo core...');

      const filesDir = this.context.filesDir;
      await this.seedGeoData(filesDir);
      const initErr: string = await core.initCore(filesDir);
      if (initErr) {
        Logger.error(TAG, 'initCore failed');
        throw new Error(`initCore failed: ${initErr}`);
      }
      Logger.info(TAG, `initCore ok, homeDir=${filesDir}`);
      this.coreInitialized = true;

      const cfg: string = await this.buildCoreConfig();
      // 用户覆写合并进内核配置：覆写项 > 订阅配置同名键（ipv6 只用于 VpnConfig，不传）
      const s = Settings.load(this.context);
      const overrides: UserOverrides = {
        mixedPort: s.mixedPort,
        logLevel: s.logLevel,
        allowLan: s.allowLan,
        mode: s.mode,
        logToFile: s.logToFile
      };
      Logger.info(TAG,
        `user overrides: mixedPort=${s.mixedPort} logLevel=${s.logLevel} allowLan=${s.allowLan} mode=${s.mode} logToFile=${s.logToFile}`);
      const startErr: string = await core.startTun(fd, cfg, JSON.stringify(overrides));
      if (startErr) {
        Logger.error(TAG, 'startTun failed');
        const hint = startErr.includes('parse configJson')
          ? `${startErr}\n提示：请到「配置」页重新导入订阅（UTF-8），或换一个配置激活后重启 VPN。`
          : startErr;
        throw new Error(hint);
      }
      this.coreStarted = true;
      Logger.info(TAG, 'mihomo core started, TUN handed over');
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      this.startupError = msg;
      Logger.error(TAG, `onConnect failed: ${msg}`);
      this.writeLastError(msg);
      if (this.coreInitialized) {
        try {
          await core.stopCore();
        } catch (e2) {
          Logger.error(TAG, `stopCore failed: ${JSON.stringify(e2)}`);
        }
        this.coreStarted = false;
        this.coreInitialized = false;
      }
      if (fd > 0) {
        try {
          await this.connection.destroy();
        } catch (e2) {
          Logger.error(TAG, `cleanup destroy failed: ${JSON.stringify(e2)}`);
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

  onDisconnect(): void {
    Logger.info(TAG, 'ClashVpnAbility.onDisconnect');
    if (this.stopping) {
      return;
    }
    this.stopping = true;
    this.cleanup().catch((e: Object) => {
      Logger.error(TAG, `cleanup failed: ${JSON.stringify(e)}`);
    });
  }

  private async cleanup(): Promise<void> {
    try {
      await this.connection.destroy();
    } catch (e) {
      Logger.error(TAG, `destroy failed: ${JSON.stringify(e)}`);
    }
    if (this.starting !== null) {
      await this.starting;
    }
    if (this.coreInitialized) {
      try {
        await core.stopCore();
        Logger.info(TAG, 'mihomo core stopped');
      } catch (e) {
        Logger.error(TAG, `stopCore failed: ${JSON.stringify(e)}`);
      }
      this.coreStarted = false;
      this.coreInitialized = false;
    }
    this.starting = null;
  }

  onDestroy(): void {
    Logger.info(TAG, 'ClashVpnAbility.onDestroy');
    if (!this.stopping) {
      this.onDisconnect();
    }
  }

  /**
   * 构建 mihomo 启动配置，三级回退：
   * 1. filesDir/profiles/ 中激活的订阅配置（配置 Tab 导入）
   * 2. rawfile 资源 override.yaml（内置空配置：全部直连）
   * 3. 最小硬编码 JSON（兜底）
   * 返回字符串直接作为 configJson 传给 startTun（Go 侧 yaml 解析，JSON/YAML 均兼容）。
   */
  private async buildCoreConfig(): Promise<string> {
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
