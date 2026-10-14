/* User-confirmed reconnect. Call only after confirming the connection interruption.
 * Returns startup acceptance; Connected remains owned by VpnController callbacks.
 */
import { common } from '@kit.AbilityKit';
import { VpnController, VpnStatus } from './VpnController';
import { ProfileTransactions } from './ProfileTransactions';
import { Settings } from './Settings';
import { ProfileStore } from './ProfileStore';
import { AppRuntime } from './AppRuntime';

export namespace ProfileRecovery {
  let busy: boolean = false;
  export async function reconnect(context: common.UIAbilityContext, isCurrent: () => boolean): Promise<boolean> {
    if (!isCurrent()) { return false; }
    if (busy || ProfileTransactions.isBusy()) { throw new Error('请稍后重试'); }
    const epoch = VpnController.configurationEpoch();
    busy = true;
    AppRuntime.cancelRestore();
    try {
      await Settings.idle();
      if (!isCurrent() || epoch !== VpnController.configurationEpoch()) { return false; }
      if (ProfileTransactions.isBusy()) { throw new Error('请稍后重试'); }
      const unknown = ProfileStore.isApplyUncertain(context);
      if (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop() || unknown) {
        if (!(await VpnController.stop(context, false, unknown))) { throw new Error('断开未确认，请重试'); }
      }
      if (!isCurrent()) { return false; }
      await ProfileTransactions.ensureActiveSmartPolicy(context);
      if (!isCurrent()) { return false; }
      if (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop()) {
        throw new Error('连接已变化，请重试');
      }
      if (Settings.isLanPersistenceUncertain()) { throw new Error('共享设置未确认，请重试保存'); }
      return VpnController.start(context);
    } finally { busy = false; }
  }
}
