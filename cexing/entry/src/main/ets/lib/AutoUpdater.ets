/*
 * AutoUpdater.ets - 订阅自动更新（按设置周期拉取激活配置的来源 URL）
 * 仅对激活配置生效；本地导入（无来源 URL）自动跳过。
 * 周期检查由 AppRuntime 按 VPN 状态启动和停止；
 * 每订阅尝试和成功记录随稳定身份保存，重命名时迁移。
 */
import { common } from '@kit.AbilityKit';
import { Settings } from './Settings';
import { CoreApi } from './CoreApi';
import { ProfileStore } from './ProfileStore';
import { ProfileTransactions } from './ProfileTransactions';
import { Logger } from './Logger';

const TAG = 'autoUpdater';
/** 定时检查周期：每 60 分钟 */
const CHECK_INTERVAL_MS = 60 * 60 * 1000;

export namespace AutoUpdater {
  let timerId: number = -1;
  let currentContext: common.Context | null = null;
  let generation: number = 0;
  // 调度代次独立于 Context 重绑定：旧排队 tick 失效，新 tick 仍读取当前 Context。
  let scheduleGeneration: number = 0;
  let checking: boolean = false;

  export function rebindContext(context: common.Context): void {
    if (currentContext !== context) {
      generation++;
      currentContext = context;
    }
  }

  /** 启动周期检查（幂等：重复调用先 stop） */
  export function start(context: common.Context): void {
    stop();
    rebindContext(context);
    const schedule = scheduleGeneration;
    timerId = setInterval(() => {
      if (schedule !== scheduleGeneration || timerId < 0) {
        return;
      }
      const ctx = currentContext;
      if (ctx === null) {
        return;
      }
      checkAndRun(ctx).catch(() => {
        // fire-and-forget：单轮失败忽略，等下一轮
      });
    }, CHECK_INTERVAL_MS);
    Logger.info(TAG, 'auto updater started');
  }

  /** 停止周期检查 */
  export function stop(): void {
    generation++;
    scheduleGeneration++;
    if (timerId >= 0) {
      clearInterval(timerId);
      timerId = -1;
      Logger.info(TAG, 'auto updater stopped');
    }
  }

  /** 单轮检查：开关/内核/间隔/来源都满足才真正更新 */
  export async function checkAndRun(context: common.Context, force: boolean = false): Promise<void> {
    if (checking) {
      return;
    }
    checking = true;
    const attempt = generation;
    try {
      await runCheck(context, attempt, force);
    } finally {
      checking = false;
    }
  }

  async function runCheck(context: common.Context, attempt: number, force: boolean): Promise<void> {
    if (!Settings.load(context).autoUpdate) {
      return;
    }
    if (!(await CoreApi.isAlive())) {
      return;
    }
    if (attempt !== generation) {
      return;
    }
    const s = Settings.load(context);
    if (!s.autoUpdate) {
      return;
    }
    const active = ProfileStore.getActiveFile(context);
    if (active.length === 0 || ProfileStore.getOrigin(context, active).length === 0) { return; }
    const state = ProfileStore.updateState(context, active);
    const now = Date.now();
    const due = state.failedAt > state.succeededAt || state.attemptedAt > state.succeededAt ?
      state.retryAt : state.succeededAt + s.autoUpdateIntervalHours * 3600 * 1000;
    if (!force && state.attemptedAt !== 0 && now < due) { return; }
    state.attemptedAt = now;
    state.retryAt = now + CHECK_INTERVAL_MS;
    ProfileStore.saveUpdateState(context, active, state);
    const current = (): boolean => attempt === generation && Settings.load(context).autoUpdate &&
      ProfileStore.getActiveFile(context) === active && ProfileStore.updateState(context, active).id === state.id;
    try {
      await ProfileTransactions.update(context, active, current);
      if (!current()) { return; }
      state.succeededAt = Date.now();
      state.failedAt = 0;
      state.retryAt = 0;
      ProfileStore.saveUpdateState(context, active, state);
      Logger.info(TAG, 'auto update completed');
    } catch (_) {
      if (!current()) { return; }
      state.failedAt = Date.now();
      ProfileStore.saveUpdateState(context, active, state);
      Logger.warn(TAG, 'auto update did not complete; check transaction status before retry');
    }
  }

  /** Explicit retry still uses the same transaction, generation and concurrency gate. */
  export async function retry(context: common.Context): Promise<void> {
    if (checking) { return; }
    const active = ProfileStore.getActiveFile(context);
    if (active === '') { return; }
    await checkAndRun(context, true);
  }
}
