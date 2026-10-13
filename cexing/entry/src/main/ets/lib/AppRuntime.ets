// 应用进程拥有后台任务和订阅调度；页面销毁不释放 VPN 运行资源。
import { common } from '@kit.AbilityKit';
import { VpnController, VpnStatus } from './VpnController';
import { LiveViewKeeper } from './LiveViewKeeper';
import { AutoUpdater } from './AutoUpdater';
import { Settings } from './Settings';
import { Logger } from './Logger';
import { ProfileTransactions } from './ProfileTransactions';

export namespace AppRuntime {
  let context: common.UIAbilityContext | null = null;
  let registered: boolean = false;
  let restoreTimer: number = -1;
  let servicesStarted: boolean = false;
  let restoreGeneration: number = 0;
  let lastStatus: VpnStatus = VpnController.status;

  export function initialize(ctx: common.UIAbilityContext): void {
    cancelRestore();
    const generation = restoreGeneration;
    context = ctx;
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
      sync(VpnController.status);
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
    });
  }

  function sync(status: VpnStatus): void {
    if (status !== lastStatus) {
      cancelRestore();
      lastStatus = status;
    }
    const ctx = context;
    if (ctx === null) {
      return;
    }
    if (status === VpnStatus.Connected && !servicesStarted) {
      servicesStarted = true;
      LiveViewKeeper.start(ctx).catch(() => Logger.warn('runtime', 'background task start failed'));
      AutoUpdater.start(ctx);
      AutoUpdater.checkAndRun(ctx).catch(() => Logger.warn('runtime', 'subscription check failed'));
    } else if (status === VpnStatus.Disconnected && servicesStarted) {
      servicesStarted = false;
      LiveViewKeeper.stop(ctx).catch(() => Logger.warn('runtime', 'background task stop failed'));
      AutoUpdater.stop();
    }
  }

  export function foreground(): void {
    if (context !== null) {
      LiveViewKeeper.ensure(context);
    }
  }

  export function abilityDestroyed(ctx: common.UIAbilityContext): void {
    // 旧 Ability 的迟到销毁不能撤销新 Ability 已安排的恢复。
    if (context === ctx) {
      cancelRestore();
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
