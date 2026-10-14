// 应用进程拥有后台任务和订阅调度；页面销毁不释放 VPN 运行资源。
import { common } from '@kit.AbilityKit';
import { VpnController, VpnStatus } from './VpnController';
import { LiveViewKeeper } from './LiveViewKeeper';
import { AutoUpdater } from './AutoUpdater';
import { Settings } from './Settings';
import { Logger } from './Logger';
import { ProfileTransactions } from './ProfileTransactions';
import { ConnectionCards } from './ConnectionCards';
import { DiagnosticsService, DiagnosticPhase } from './DiagnosticsService';
import { VpnPhase } from './VpnPhases';
import { TrafficStats } from './TrafficStats';

export namespace AppRuntime {
  let context: common.UIAbilityContext | null = null;
  let registered: boolean = false;
  let restoreTimer: number = -1;
  let servicesStarted: boolean = false;
  let restoreGeneration: number = 0;
  let recoveryGeneration: number = -1;
  let healthTimer: number = -1;
  let checking: boolean = false;
  let contextDestroyed: boolean = false;
  let diagnosticsObserverOff: (() => void) | null = null;
  let diagnosticsPhaseOff: (() => void) | null = null;
  let lastStatus: VpnStatus = VpnController.status;

  export function initialize(ctx: common.UIAbilityContext, onReady?: () => void): void {
    cancelRestore();
    const generation = restoreGeneration;
    recoveryGeneration = generation;
    releaseDiagnostics();
    context = ctx;
    contextDestroyed = false;
    // Invoke initialization before recovery; evidence I/O never gates VPN control.
    try { DiagnosticsService.initialize(ctx).catch(() => {}); } catch (_) {}
    try { diagnosticsObserverOff = DiagnosticsService.observe(ctx); } catch (_) {}
    diagnosticsPhaseOff = VpnController.onPhase((event: VpnPhase) => {
      const current = context;
      if (current !== null) {
        try {
          const request: DiagnosticPhase = { operation: event.operation, stage: event.stage,
            outcome: event.outcome, object: event.object, reason: event.reason, code: event.code,
            durationMs: event.durationMs };
          DiagnosticsService.record(current, request).catch(() => {});
        } catch (_) {}
      }
    });
    try { TrafficStats.initialize(ctx); } catch (_) {}
    LiveViewKeeper.rebindContext(ctx);
    AutoUpdater.rebindContext(ctx);
    if (!registered) {
      registered = true;
      VpnController.onChanged(sync);
    }
    VpnController.recover(() => {
      if (generation !== restoreGeneration) {
        return;
      }
      recoveryGeneration = -1;
      sync(VpnController.status);
      if (onReady !== undefined) { onReady(); }
      if (generation !== restoreGeneration) { return; }
      const settings = Settings.load(ctx);
      if (settings.autoRestore && settings.vpnWasConnected &&
        VpnController.status === VpnStatus.Disconnected) {
        restoreTimer = setTimeout(() => {
          if (generation !== restoreGeneration || context === null) {
            return;
          }
          restoreTimer = -1;
          const current = Settings.load(context);
          if (current.autoRestore && current.vpnWasConnected &&
            VpnController.status === VpnStatus.Disconnected) {
            const restoreContext = context;
            ProfileTransactions.ensureActiveSmartPolicy(restoreContext).then(() => {
              if (generation === restoreGeneration && context === restoreContext &&
                VpnController.status === VpnStatus.Disconnected) {
                VpnController.start(restoreContext);
              }
            }).catch(() => { Logger.warn('runtime', 'generated profile preparation failed'); });
          }
        }, 1200);
      }
    }, ctx);
  }

  function releaseDiagnostics(): void {
    try { diagnosticsObserverOff?.(); } catch (_) {}
    try { diagnosticsPhaseOff?.(); } catch (_) {}
    diagnosticsObserverOff = null; diagnosticsPhaseOff = null;
  }

  function sync(status: VpnStatus): void {
    if (status !== lastStatus) {
      if (status !== VpnStatus.Connected || recoveryGeneration !== restoreGeneration) { cancelRestore(); }
      lastStatus = status;
    }
    const ctx = context;
    if (ctx === null) {
      return;
    }
    if (status === VpnStatus.Connected && !servicesStarted) {
      servicesStarted = true;
      TrafficStats.sample().catch(() => {});
      healthTimer = setInterval(() => { checkSession(); }, 5000);
      ProfileTransactions.applyPendingRegionSelection(ctx)
        .catch(() => Logger.warn('runtime', 'explicit region selection pending'));
      LiveViewKeeper.start(ctx).catch(() => Logger.warn('runtime', 'background task start failed'));
      AutoUpdater.start(ctx);
      AutoUpdater.checkAndRun(ctx).catch(() => Logger.warn('runtime', 'subscription check failed'));
    } else if (status === VpnStatus.Disconnected && servicesStarted) {
      TrafficStats.invalidate();
      servicesStarted = false;
      clearInterval(healthTimer);
      healthTimer = -1;
      LiveViewKeeper.stop(ctx).catch(() => Logger.warn('runtime', 'background task stop failed'));
      AutoUpdater.stop();
    }
    if (contextDestroyed && status === VpnStatus.Disconnected && !VpnController.needsStop()) { releaseDiagnostics(); }
  }

  async function checkSession(): Promise<void> {
    const ctx = context;
    if (ctx === null || checking || VpnController.status !== VpnStatus.Connected) { return; }
    checking = true;
    try {
      await VpnController.verify(ctx);
      if (context === ctx && VpnController.status === VpnStatus.Connected) {
        TrafficStats.sample().catch(() => {});
        ConnectionCards.publish(ctx, '已连接', false);
      }
    } finally { checking = false; }
  }

  export function foreground(): void {
    if (context !== null) {
      try { TrafficStats.initialize(context); } catch (_) {}
      LiveViewKeeper.ensure(context);
      checkSession();
    }
  }

  export function abilityDestroyed(ctx: common.UIAbilityContext): void {
    // 旧 Ability 的迟到销毁不能撤销新 Ability 已安排的恢复。
    if (context === ctx) {
      contextDestroyed = true;
      cancelRestore();
      if (VpnController.status === VpnStatus.Disconnected && !VpnController.needsStop()) { releaseDiagnostics(); }
    }
  }

  export function cancelRestore(): void {
    restoreGeneration++;
    VpnController.cancelRecovery();
    if (restoreTimer >= 0) {
      clearTimeout(restoreTimer);
      restoreTimer = -1;
    }
  }
}
