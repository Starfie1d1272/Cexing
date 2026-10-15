import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from './VpnController';
import { ProfileStore } from './ProfileStore';
import { ProfileRecovery } from './ProfileRecovery';

/** UI confirmation around the existing reconnect implementation. */
export namespace ProfileApplyRecovery {
  export async function reconnect(context: common.UIAbilityContext, current: () => boolean): Promise<boolean | null> {
    if (!current()) { return null; }
    const file = ProfileStore.getActiveFile(context);
    const session = VpnController.trafficSession();
    const epoch = VpnController.configurationEpoch();
    const stable = (): boolean => current() && ProfileStore.getActiveFile(context) === file;
    if (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop() || ProfileStore.isApplyUncertain(context)) {
      let index: number = -1;
      try {
      const answer = await promptAction.showDialog({
        title: context.resourceManager.getStringByNameSync('apply_feedback_reconnect_title'),
        message: context.resourceManager.getStringByNameSync('apply_feedback_reconnect_body'),
        buttons: [{ text: context.resourceManager.getStringByNameSync('proxy_editor_cancel'), color: $r('app.color.ui_muted') },
          { text: context.resourceManager.getStringByNameSync('apply_feedback_reconnect'), color: $r('app.color.ui_accent_text') }] });
      index = answer.index;
      } catch (_) { return null; }
      if (index !== 1 || !stable() || VpnController.trafficSession() !== session ||
        VpnController.configurationEpoch() !== epoch) { return null; }
    }
    return await ProfileRecovery.reconnect(context, stable);
  }
}
