import { BackupJournal, BackupPreferences } from './BackupJournal';
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
  let committed: AppSettings | null = null;
  let tail: Promise<void> = Promise.resolve();
  let recoveryError: boolean = false;
  let recoveryChecked: boolean = false;
  let lanWriteFailed: boolean = false;
  let lanRevokeFailed: boolean = false;
  let lanNeedsRevocation: boolean = false;
  const SAVE_KEYS: string[] = ['keepAlive', 'ipv6', 'logLevel', 'mixedPort', 'accessMode',
    'accessList', 'mainGroup', 'mode', 'autoUpdate', 'autoUpdateIntervalHours', 'autoRestore',
    'vpnWasConnected', 'logToFile'];

  function getStore(context: common.Context): preferences.Preferences {
    if (store === null) { store = preferences.getPreferencesSync(context, { name: STORE }); }
    return store;
  }

  function readPreferences(context: common.Context): AppSettings {
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
    return s;
  }

  function copy(s: AppSettings): AppSettings { return JSON.parse(JSON.stringify(s)) as AppSettings; }
  function current(context: common.Context): AppSettings {
    if (committed === null) { committed = readPreferences(context); }
    if (!recoveryChecked && context.filesDir !== undefined) {
      recoveryChecked = true;
      if (BackupJournal.exists(context)) {
        const operation = tail.then(async () => {
          const result = await BackupJournal.call(context, JSON.stringify({ op: 'backup-recover' }));
          const next = applyPortable(current(context), result.preferences);
          const p = getStore(context); writeCache(p, next); await p.flush(); committed = next;
          await BackupJournal.acknowledge(context, result.token);
          recoveryError = false;
        });
        recoveryError = true;
        tail = operation.catch(() => { recoveryError = true; });
      } else {
        // A previous process may have ended after staging a preview or after ack.
        tail = tail.then(async () => {
          try { await BackupJournal.call(context, JSON.stringify({ op: 'backup-clean' })); } catch (_) {}
        });
      }
    }
    return committed;
  }
  export function load(context: common.Context): AppSettings {
    const result = copy(current(context));
    const p = getStore(context);
    result.allowLan = lanRevokeFailed || (!lanWriteFailed &&
      p.getSync('allowLanConfirmed', false) === true && p.getSync('allowLan', false) === true);
    return result;
  }

  function values(s: AppSettings): Record<string, Object> {
    const result: Record<string, Object> = { 'keepAlive': s.keepAlive, 'ipv6': s.ipv6, 'logLevel': s.logLevel, 'mixedPort': s.mixedPort,
      'accessMode': s.accessMode, 'accessList': s.accessList.slice(), 'mainGroup': s.mainGroup, 'mode': s.mode,
      'autoUpdate': s.autoUpdate, 'autoUpdateIntervalHours': s.autoUpdateIntervalHours,
      'autoRestore': s.autoRestore, 'vpnWasConnected': s.vpnWasConnected, 'logToFile': s.logToFile };
    return result;
  }
  function validate(s: AppSettings): void {
    if (!Number.isInteger(s.mixedPort) || s.mixedPort < 1 || s.mixedPort > 65535 ||
      !Number.isFinite(s.autoUpdateIntervalHours) || s.autoUpdateIntervalHours < 1 ||
      !['all', 'white', 'black'].includes(s.accessMode) ||
      !['silent', 'error', 'warning', 'info', 'debug'].includes(s.logLevel)) { throw new Error('设置值无效'); }
  }
  function writeCache(p: preferences.Preferences, s: AppSettings): void {
    const data = values(s);
    for (const key of SAVE_KEYS) { p.putSync(key, data[key] as preferences.ValueType); }
    p.putSync('smartAutoConvert', s.smartAutoConvert);
  }
  function enqueue(context: common.Context, action: (p: preferences.Preferences) => Promise<void>): Promise<void> {
    current(context);
    const operation = tail.then(async () => {
      if (recoveryError) { throw new Error('备份恢复未确认，请重新打开应用后重试'); }
      const p = getStore(context);
      // Normalize dirty cache left by any failed put/flush before another writer
      // can persist it. Consent has its own strict repair path below.
      writeCache(p, current(context));
      if (lanNeedsRevocation) {
        p.putSync('allowLanConfirmed', false); p.putSync('allowLan', false);
        await p.flush();
        lanNeedsRevocation = false; lanWriteFailed = false; lanRevokeFailed = false;
      }
      await action(p);
    });
    tail = operation.catch(() => {});
    return operation;
  }

  /** Callers capture only the fields they changed. Queued saves merge with the
   * latest durable snapshot, so unrelated edits and same-field retries are ordered.
   */
  export async function save(context: common.Context, settings: AppSettings, fields: string[]): Promise<void> {
    if (fields.length === 0 || fields.some((key: string) => !SAVE_KEYS.includes(key))) {
      throw new Error('无效的设置字段');
    }
    const desired = values(copy(settings));
    try { await enqueue(context, async (p: preferences.Preferences) => {
      const before = copy(current(context));
      const merged = values(before);
      for (const key of fields) { merged[key] = desired[key]; }
      const next = JSON.parse(JSON.stringify(merged)) as AppSettings;
      next.allowLan = before.allowLan; next.smartAutoConvert = before.smartAutoConvert;
      validate(next);
      try {
        writeCache(p, next);
        await p.flush();
        committed = next;
      } catch (_) {
        try { writeCache(p, before); await p.flush(); } catch (_) { Logger.error(TAG, 'settings rollback failed'); }
        throw new Error('保存失败，请重试');
      }
    }); } catch (_) { throw new Error('保存失败，请重试'); }
  }

  export function portable(s: AppSettings): BackupPreferences {
    return { keepAlive: s.keepAlive, ipv6: s.ipv6, logLevel: s.logLevel, mixedPort: s.mixedPort,
      accessMode: s.accessMode, accessList: s.accessList.slice(), mainGroup: s.mainGroup, mode: s.mode,
      autoUpdate: s.autoUpdate, autoUpdateIntervalHours: s.autoUpdateIntervalHours,
      autoRestore: s.autoRestore, logToFile: s.logToFile, smartAutoConvert: s.smartAutoConvert };
  }
  function applyPortable(before: AppSettings, value: BackupPreferences): AppSettings {
    const next = copy(before);
    next.keepAlive = value.keepAlive; next.ipv6 = value.ipv6; next.logLevel = value.logLevel;
    next.mixedPort = value.mixedPort; next.accessMode = value.accessMode; next.accessList = value.accessList.slice();
    next.mainGroup = value.mainGroup; next.mode = value.mode; next.autoUpdate = value.autoUpdate;
    next.autoUpdateIntervalHours = value.autoUpdateIntervalHours; next.autoRestore = value.autoRestore;
    next.logToFile = value.logToFile; next.smartAutoConvert = value.smartAutoConvert;
    validate(next); return next;
  }

  /** Keep all preference writers behind the journal and the single FileStore publication. */
  export async function restoreBackup(context: common.Context, value: BackupPreferences,
    arm: (old: BackupPreferences) => Promise<void>, commit: () => Promise<string>,
    recover: () => Promise<string>, finish: () => Promise<void>): Promise<void> {
    await enqueue(context, async (p: preferences.Preferences) => {
      const before = copy(current(context)); const next = applyPortable(before, value);
      await arm(portable(before));
      let outcome = 'prior';
      try { writeCache(p, next); await p.flush(); outcome = await commit(); }
      catch (_) { try { outcome = await recover(); } catch (_) { outcome = 'unknown'; } }
      if (outcome !== 'prior' && outcome !== 'committed') {
        recoveryError = true; throw new Error('备份恢复未确认，请重新打开应用后重试');
      }
      const selected = outcome === 'committed' ? next : before;
      try { writeCache(p, selected); await p.flush(); committed = selected; await finish(); }
      catch (_) { recoveryError = true; throw new Error('备份恢复未确认，请重新打开应用后重试'); }
      if (outcome !== 'committed') { throw new Error('恢复失败，原资料已保留'); }
    });
  }

  /** Await the already requested saves before preparing a connection. */
  export async function idle(): Promise<void> {
    let observed: Promise<void>;
    do { observed = tail; await observed; } while (observed !== tail);
    if (recoveryError) { throw new Error('备份恢复未确认，请重新打开应用后重试'); }
  }

  export function isLanPersistenceUncertain(): boolean { return lanNeedsRevocation; }

  export async function setSmartAutoConvert(context: common.Context, enabled: boolean): Promise<void> {
    await enqueue(context, async (p: preferences.Preferences) => {
      const before = current(context).smartAutoConvert;
      try { p.putSync('smartAutoConvert', enabled); await p.flush(); current(context).smartAutoConvert = enabled; }
      catch (_) {
        try { p.putSync('smartAutoConvert', before); await p.flush(); } catch (_) { Logger.error(TAG, 'smart setting rollback failed'); }
        throw new Error('保存失败，请重试');
      }
    });
  }

  /** Only after explicit LAN confirmation, or when revoking consent. All flushes
   * share the ordinary queue; an older async flush can never resurrect a grant.
   */
  export async function setAllowLan(context: common.Context, enabled: boolean): Promise<void> {
    await enqueue(context, async (p: preferences.Preferences) => {
      const previouslyAllowed = load(context).allowLan;
      if (!enabled) {
        lanRevokeFailed = previouslyAllowed;
        try {
          p.putSync('allowLanConfirmed', false); p.putSync('allowLan', false); await p.flush();
          lanRevokeFailed = false; lanWriteFailed = false; lanNeedsRevocation = false;
        } catch (_) {
          lanNeedsRevocation = true;
          throw new Error('LAN revocation could not be saved');
        }
        return;
      }
      if (previouslyAllowed) { return; }
      lanWriteFailed = true;
      try {
        p.putSync('allowLanConfirmed', false); await p.flush();
        p.putSync('allowLan', true); await p.flush();
        p.putSync('allowLanConfirmed', true); await p.flush();
        lanWriteFailed = false; lanRevokeFailed = false; lanNeedsRevocation = false;
      } catch (_) {
        lanNeedsRevocation = true;
        try {
          p.putSync('allowLanConfirmed', false); p.putSync('allowLan', false); await p.flush();
          lanNeedsRevocation = false; lanWriteFailed = false;
        } catch (_) { Logger.error(TAG, 'LAN consent rollback failed'); }
        throw new Error('LAN consent could not be saved');
      }
    });
  }
}
