// 应用进程拥有后台任务和订阅调度；页面销毁不释放 VPN 运行资源。
import { common } from '@kit.AbilityKit';
import { VpnController, VpnStatus } from './VpnController';
import { LiveViewKeeper } from './LiveViewKeeper';
import { AutoUpdater } from './AutoUpdater';
import { Settings } from './Settings';
import { Logger } from './Logger';

export namespace AppRuntime {
  let context: common.UIAbilityContext | null = null;
  let registered: boolean = false;
  let restoreTimer: number = -1;
  let servicesStarted: boolean = false;

  export function initialize(ctx: common.UIAbilityContext): void {
    context = ctx;
    if (!registered) {
      registered = true;
      VpnController.onChanged(sync);
    }
    VpnController.recover(() => {
      sync(VpnController.status);
      const settings = Settings.load(ctx);
      if (settings.autoRestore && settings.vpnWasConnected &&
        VpnController.status === VpnStatus.Disconnected) {
        cancelRestore();
        restoreTimer = setTimeout(() => {
          restoreTimer = -1;
          if (VpnController.status === VpnStatus.Disconnected) {
            VpnController.start(ctx);
          }
        }, 1200);
      }
    });
  }

  function sync(status: VpnStatus): void {
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

  export function cancelRestore(): void {
    if (restoreTimer >= 0) {
      clearTimeout(restoreTimer);
      restoreTimer = -1;
    }
  }
}
