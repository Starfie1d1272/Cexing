import { common, Want } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from './VpnController';
import { ProfileStore } from './ProfileStore';
import { ProfileTransactions } from './ProfileTransactions';
import { AppRuntime } from './AppRuntime';
import { ConnectionCards } from './ConnectionCards';

export namespace ConnectionEntry {
  export let action: string = '';
  export let request: number = 0;
  export let revision: number = 0;
  export let ready: boolean = false;
  let context: common.UIAbilityContext | null = null;
  let registered: boolean = false;
  let consumed: number = 0;
  let running: boolean = false;
  let stopUnknown: boolean = false;

  function changed(): void {
    if (context !== null && ready) {
      stopUnknown = stopUnknown || VpnController.getLastStopCompleted() === false;
      if (VpnController.getLastStopCompleted() === true) { stopUnknown = false; }
      if (VpnController.status === VpnStatus.Connected && VpnController.getTunCreateObserved() &&
        VpnController.getKernelReadyReported()) { stopUnknown = false; }
      ConnectionCards.publish(context, label(), stopUnknown);
    }
    revision++;
    AppStorage.setOrCreate('connectionStateRevision', revision);
  }

  export function bind(ctx: common.UIAbilityContext): void {
    context = ctx;
    action = '';
    consumed = request;
    running = false;
    ready = false;
    stopUnknown = ConnectionCards.read(ctx).stopUnknown;
    if (!registered) {
      registered = true;
      VpnController.onChanged(changed);
    }
    changed();
  }

  export function recovered(ctx: common.UIAbilityContext): void {
    if (context !== ctx) { return; }
    ready = true;
    if (action.length > 0) { AppRuntime.cancelRestore(); }
    changed();
    executePending();
  }

  export function destroyed(ctx: common.UIAbilityContext): void {
    if (context !== ctx) { return; }
    ready = false;
    request++;
    running = false;
    changed();
  }

  // Explicit intents execute once after runtime recovery, without a second confirmation.
  export function receive(want: Want): void {
    let desired = want.parameters?.cexingConnectionAction;
    // postCardAction's router payload is serialized under Want.parameters.params;
    // static shortcut parameters are delivered directly on Want.parameters.
    if (desired === undefined && typeof want.parameters?.params === 'string') {
      try {
        const params = JSON.parse(want.parameters.params as string) as Record<string, Object>;
        desired = params.cexingConnectionAction;
      } catch (_) { return; }
    }
    if (desired !== 'connect' && desired !== 'disconnect') { return; }
    action = desired as string;
    if (ready) { AppRuntime.cancelRestore(); }
    request++;
    AppStorage.setOrCreate('connectionEntryRequest', request);
    executePending();
  }

  async function executePending(): Promise<void> {
    if (!ready || context === null || running || request === consumed) { return; }
    const ctx = context;
    const expected = request;
    running = true;
    let message = '';
    try { message = await execute(ctx, expected); }
    catch (_) { message = '操作未完成，请检查连接后重试'; }
    finally {
      if (context !== ctx) { return; }
      running = false;
      if (context === ctx && expected === request && message.length > 0) {
        promptAction.showToast({ message, duration: 3000 });
      }
      if (ready && request !== consumed) { executePending(); }
    }
  }

  export function label(): string {
    if (!ready) { return '正在核对连接'; }
    if (VpnController.status === VpnStatus.Disconnecting) { return '断开中'; }
    if (VpnController.status === VpnStatus.Connecting) { return '连接中'; }
    if (VpnController.status === VpnStatus.Connected) { return '已连接'; }
    if (stopUnknown || VpnController.getLastStopCompleted() === false) { return '断开未完成'; }
    if (VpnController.getLastStartFailure() !== null) { return '连接失败'; }
    return '未连接';
  }

  async function execute(ctx: common.UIAbilityContext, expected: number): Promise<string> {
    consumed = expected;
    AppRuntime.cancelRestore();
    if (action === 'disconnect') {
      if (VpnController.status === VpnStatus.Disconnected && !stopUnknown &&
        !VpnController.needsStop()) { return ''; }
      let completed = false;
      try { completed = await VpnController.stop(ctx); } catch (_) {}
      if (context !== ctx || request !== expected) { return ''; }
      stopUnknown = !completed;
      changed();
      return completed ? '' : '断开未确认，请检查系统 VPN 后重试';
    }
    if (VpnController.status === VpnStatus.Connected) {
      await VpnController.verify(ctx);
      if (context !== ctx || request !== expected || !ready) { return ''; }
    }
    if (VpnController.status === VpnStatus.Connected || VpnController.status === VpnStatus.Connecting) { return ''; }
    if (VpnController.status === VpnStatus.Disconnecting) { return '正在断开，请稍后连接'; }
    if (stopUnknown || VpnController.needsStop()) {
      return '请先重试断开，确认当前连接已结束';
    }
    if (ProfileStore.isApplyUncertain(ctx)) {
      return '请先确认当前配置';
    }
    if (ProfileTransactions.isBusy()) { return '配置正在更新，请稍后连接'; }
    const file = ProfileStore.getActiveFile(ctx);
    if (file.length === 0) { return '请先添加并启用订阅'; }
    const expectedRevision = revision;
    try { await ProfileTransactions.ensureActiveSmartPolicy(ctx); }
    catch (_) {
      if (context !== ctx || request !== expected) { return ''; }
      return '当前配置未能生成，请检查后重试';
    }
    if (context !== ctx || !ready || request !== expected || revision !== expectedRevision || action !== 'connect' ||
      VpnController.status !== VpnStatus.Disconnected || stopUnknown ||
      VpnController.needsStop() || ProfileTransactions.isBusy() ||
      ProfileStore.isApplyUncertain(ctx) || ProfileStore.getActiveFile(ctx) !== file) { return ''; }
    const started = VpnController.start(ctx);
    changed();
    if (!started) { return '连接未开始，请查看当前状态后重试'; }
    return '';
  }
}
