import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AppRuntime } from './AppRuntime';
import { VpnController, VpnStatus } from './VpnController';
import { AutoUpdater } from './AutoUpdater';
import { LiveViewKeeper } from './LiveViewKeeper';

const STOP_TIMEOUT_MS = 15000;

export namespace SmartModelRestart {
  let restarting: boolean = false;

  async function stopVpn(context: common.UIAbilityContext): Promise<void> {
    // No VPN session was entered on the first model setup path.
    if (VpnController.status === VpnStatus.Disconnected) {
      if (VpnController.getLastStopCompleted() === false) {
        throw new Error('上次停止 VPN 结果未知，请确认系统状态后重试模型重启');
      }
      return;
    }
    let timer: number = -1;
    const deadline = new Promise<boolean>((_resolve, reject) => {
      timer = setTimeout(() => {
        reject(new Error('停止 VPN 超时，请确认已断开后重试模型重启'));
      }, STOP_TIMEOUT_MS);
    });
    try {
      // A failed Controller probe can look like a stopped core. The session-
      // bound extension receipt and system stop result are the completion signal.
      if (await Promise.race([VpnController.stop(context), deadline]) !== true) {
        throw new Error('停止 VPN 结果未知，请确认系统状态后重试模型重启');
      }
    } finally {
      clearTimeout(timer);
    }
  }

  /** 应用级重启释放 VPN 扩展持有的 Go runtime；不依赖 onDestroy 回调。 */
  export async function restart(context: common.UIAbilityContext): Promise<void> {
    if (restarting) {
      throw new Error('模型重启正在进行，请稍候');
    }
    restarting = true;
    try {
      try {
        AppRuntime.cancelRestore();
      } catch (e) {
        throw new Error('取消自动恢复失败，请重试模型重启');
      }
      try {
        await stopVpn(context);
      } catch (e) {
        throw new Error('停止 VPN 失败或超时，请确认已断开后重试模型重启');
      }
      try {
        // Settings.save 不等待 flush；应用重启前单独等待本次会话标记落盘。
        // 不改变用户的自动恢复或其他偏好，也覆盖原本已断开的情况。
        const store = preferences.getPreferencesSync(context, { name: 'clashoh_settings' });
        store.putSync('vpnWasConnected', false);
        await store.flush();
      } catch (e) {
        throw new Error('保存断开状态失败，请重试模型重启');
      }
      try {
        AutoUpdater.stop();
        await LiveViewKeeper.stop(context);
      } catch (e) {
        throw new Error('停止后台任务失败，请重试模型重启');
      }
      try {
        // UIAbilityContext.restartApp 只重启 UI 进程，不能清除扩展中的模型缓存。
        context.getApplicationContext().restartApp({
          bundleName: context.applicationInfo.name,
          abilityName: 'EntryAbility'
        });
      } catch (e) {
        throw new Error('应用重启失败，请手动关闭应用后重新打开');
      }
    } finally {
      restarting = false;
    }
  }
}
