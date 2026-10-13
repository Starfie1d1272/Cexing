import { common, Want } from '@kit.AbilityKit';
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
  let routed: number = 0;
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
    routed = request;
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
  }

  export function destroyed(ctx: common.UIAbilityContext): void {
    if (context !== ctx) { return; }
    ready = false;
    request++;
    routed = request;
    changed();
  }

  // A Want only opens a foreground confirmation. It never toggles the VPN.
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
  }

  export function takeNavigation(): boolean {
    if (request <= routed) { return false; }
    routed = request;
    return true;
  }

  export function label(): string {
    if (!ready) { return '正在核对本机状态…'; }
    if (VpnController.status === VpnStatus.Disconnecting) { return '断开中…'; }
    if (stopUnknown || VpnController.getLastStopCompleted() === false) { return '停止结果未知'; }
    if (VpnController.status === VpnStatus.Connecting) { return '连接中…'; }
    if (VpnController.status === VpnStatus.Connected) {
      return VpnController.getTunCreateObserved() && VpnController.getKernelReadyReported() ?
        '应用报告已连接' : '本机服务可用，VPN 待确认';
    }
    if (VpnController.getLastStartFailure() !== null) { return '连接失败，VPN 待确认'; }
    return VpnController.getLastStopCompleted() === true ? '已确认断开' : '未检测到本机服务';
  }

  export function canConfirm(): boolean {
    if (!ready || context === null || request === consumed || ProfileTransactions.isBusy()) { return false; }
    if (action === 'disconnect') {
      return VpnController.status === VpnStatus.Connected || VpnController.status === VpnStatus.Connecting;
    }
    return action === 'connect' && VpnController.status === VpnStatus.Disconnected &&
      !stopUnknown && VpnController.getLastStopCompleted() !== false &&
      !ProfileStore.isApplyUncertain(context) && ProfileStore.getActiveFile(context).length > 0;
  }

  export async function confirm(ctx: common.UIAbilityContext, expectedRequest: number,
    expectedRevision: number): Promise<string> {
    if (context !== ctx || request !== expectedRequest || revision !== expectedRevision || !canConfirm()) {
      return '状态或入口已变化，请查看当前连接状态';
    }
    consumed = request;
    AppRuntime.cancelRestore();
    // No asynchronous gap between the gate and the existing lifecycle call.
    if (action === 'connect') {
      VpnController.start(ctx);
      changed();
      return '已进入系统连接与授权流程';
    }
    let completed = false;
    try { completed = await VpnController.stop(ctx); } catch (_) {}
    if (context !== ctx || request !== expectedRequest) { return ''; }
    stopUnknown = !completed;
    changed();
    return completed ? '已确认断开' : '停止结果未知，请检查系统 VPN 状态';
  }
}
