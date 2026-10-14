/*
 * Settings.ets - 应用设置持久化（preferences KV）
 * 覆写类设置在下次 VPN 启动时由 CexingVpnAbility 合并进内核配置。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'settings';
const STORE = 'clashoh_settings';

export class AppSettings {
  keepAlive: boolean = true;
  ipv6: boolean = false;
  allowLan: boolean = false;
  logLevel: string = 'info';
  mixedPort: number = 7890;
  /** 按应用分流: all=全部走VPN, white=仅名单走(trusted), black=名单外走(blocked) */
  accessMode: string = 'all';
  accessList: string[] = [];
  /** 后台实况窗记忆的 Selector 名 */
  mainGroup: string = '';
  /** 内核运行模式 rule|global|direct；空串=未显式选择，沿用激活配置自带 mode */
  mode: string = '';
  /** 订阅自动更新开关 */
  autoUpdate: boolean = false;
  /** 自动更新间隔（小时） */
  autoUpdateIntervalHours: number = 24;
  /** 打开应用自动恢复：冷启动时若上次会话曾连接则自动重连（默认开） */
  autoRestore: boolean = true;
  /** 内部标记：上次会话是否曾成功连接（用户主动断开时清 false，不上设置页） */
  vpnWasConnected: boolean = false;
  /** 内核日志是否写入应用沙箱 mihomo.log（默认开；关闭后仅进系统 hilog，下次启动内核生效） */
  logToFile: boolean = true;
  /** Convert only url-test/load-balance groups in generated runtime versions. */
  smartAutoConvert: boolean = true;
}

export namespace Settings {
  let store: preferences.Preferences | null = null;
  let failedSnapshot: AppSettings | null = null;
  let lanWriteFailed: boolean = false;
  let lanRevokeFailed: boolean = false;

  function getStore(context: common.Context): preferences.Preferences {
    if (!store) {
      store = preferences.getPreferencesSync(context, { name: STORE });
    }
    return store;
  }

  export function load(context: common.Context): AppSettings {
    const p = getStore(context);
    const s = new AppSettings();
    try {
      s.keepAlive = p.getSync('keepAlive', true) as boolean;
      s.ipv6 = p.getSync('ipv6', false) as boolean;
      // Legacy true included the old default; it cannot establish consent.
      s.allowLan = lanRevokeFailed || (!lanWriteFailed &&
        p.getSync('allowLanConfirmed', false) === true && p.getSync('allowLan', false) === true);
      s.logLevel = p.getSync('logLevel', 'info') as string;
      s.mixedPort = p.getSync('mixedPort', 7890) as number;
      s.accessMode = p.getSync('accessMode', 'all') as string;
      s.accessList = p.getSync('accessList', [] as string[]) as string[];
      s.mainGroup = p.getSync('mainGroup', '') as string;
      s.mode = p.getSync('mode', '') as string;
      s.autoUpdate = p.getSync('autoUpdate', false) as boolean;
      s.autoUpdateIntervalHours = p.getSync('autoUpdateIntervalHours', 24) as number;
      s.autoRestore = p.getSync('autoRestore', true) as boolean;
      s.vpnWasConnected = p.getSync('vpnWasConnected', false) as boolean;
      s.logToFile = p.getSync('logToFile', true) as boolean;
      s.smartAutoConvert = p.getSync('smartAutoConvert', true) as boolean;
    } catch (e) {
      Logger.error(TAG, `load failed: ${JSON.stringify(e)}`);
    }
    if (failedSnapshot !== null) {
      const prior = JSON.parse(JSON.stringify(failedSnapshot)) as AppSettings;
      prior.allowLan = s.allowLan;
      return prior;
    }
    return s;
  }

  function write(p: preferences.Preferences, s: AppSettings): void {
    p.putSync('keepAlive', s.keepAlive);
    p.putSync('ipv6', s.ipv6);
    p.putSync('logLevel', s.logLevel);
    p.putSync('mixedPort', s.mixedPort);
    p.putSync('accessMode', s.accessMode);
    p.putSync('accessList', s.accessList);
    p.putSync('mainGroup', s.mainGroup);
    p.putSync('mode', s.mode);
    p.putSync('autoUpdate', s.autoUpdate);
    p.putSync('autoUpdateIntervalHours', s.autoUpdateIntervalHours);
    p.putSync('autoRestore', s.autoRestore);
    p.putSync('vpnWasConnected', s.vpnWasConnected);
    p.putSync('logToFile', s.logToFile);
  }

  /** Small preference batches complete durably before callers report success.
   * Synchronous flush also prevents a delayed old batch from overwriting a newer one.
   * LAN consent is deliberately absent from write().
   */
  export function save(context: common.Context, s: AppSettings): void {
    if (!Number.isInteger(s.mixedPort) || s.mixedPort < 1 || s.mixedPort > 65535 ||
      !Number.isFinite(s.autoUpdateIntervalHours) || s.autoUpdateIntervalHours < 1 ||
      !['all', 'white', 'black'].includes(s.accessMode) ||
      !['silent', 'error', 'warning', 'info', 'debug'].includes(s.logLevel)) {
      throw new Error('设置值无效');
    }
    const previous = load(context);
    const p = getStore(context);
    try {
      write(p, s);
      p.flushSync();
      failedSnapshot = null;
    } catch (_) {
      failedSnapshot = previous;
      // Preferences mutates its cache before flush. Restore it too, so load()
      // cannot present failed edits as saved values in this process.
      try { write(p, previous); p.flushSync(); }
      catch (_) { Logger.error(TAG, 'settings rollback failed'); }
      throw new Error('保存失败，请重试');
    }
  }

  /** Transaction callers need a visible persistence failure to avoid a false toggle result. */
  export function setSmartAutoConvert(context: common.Context, enabled: boolean): void {
    const p = getStore(context);
    p.putSync('smartAutoConvert', enabled);
    p.flushSync();
    if (failedSnapshot !== null) { failedSnapshot.smartAutoConvert = enabled; }
  }

  /** Called only after explicit LAN risk confirmation, or to disable sharing. */
  export function setAllowLan(context: common.Context, enabled: boolean): void {
    const p = getStore(context);
    if (!enabled) {
      const previouslyAllowed = load(context).allowLan;
      try {
        p.putSync('allowLanConfirmed', false);
        p.putSync('allowLan', false);
        p.flushSync();
        lanRevokeFailed = false;
        lanWriteFailed = false;
      } catch (_) {
        // The extension/new process can still read the old durable grant.
        // Keep the prior authorization visible until a retry durably revokes it.
        lanRevokeFailed = previouslyAllowed;
        throw new Error('LAN revocation could not be saved');
      }
      return;
    }
    lanWriteFailed = true;
    try {
      // Revoke first: a partial failure cannot turn a legacy true into consent.
      p.putSync('allowLanConfirmed', false);
      p.flushSync();
      p.putSync('allowLan', enabled);
      p.flushSync();
      p.putSync('allowLanConfirmed', enabled);
      p.flushSync();
      lanWriteFailed = false;
      lanRevokeFailed = false;
    } catch (_) {
      // putSync changes the Preferences cache before flushSync can fail.
      // Revoke that cached grant too; the process guard covers rollback failure.
      try {
        p.putSync('allowLanConfirmed', false);
        p.flushSync();
      } catch (_) {
        Logger.error(TAG, 'LAN consent rollback failed');
      }
      throw new Error('LAN consent could not be saved');
    }
  }
}
