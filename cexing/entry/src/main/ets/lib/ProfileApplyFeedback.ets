import { common } from '@kit.AbilityKit';
import { ProfileStore } from './ProfileStore';
import { EffectiveVersions } from './EffectiveVersions';
import { ProfileRegionChoices } from './ProfileRegionChoices';
import { VpnController, VpnStatus } from './VpnController';

export type ProfileApplyFailureKind = 'unconfirmed' | 'committed-pending' | 'selection-required' | 'failed';

/** Closed UI categories. Never return arbitrary backend text or config values. */
export namespace ProfileApplyFeedback {
  export function classify(message: string): ProfileApplyFailureKind {
    if (['应用未确认，请重连恢复', '应用结果未确认', '地区策略结果未确认', '切换结果未确认',
      '版本发布结果未知，请断开 VPN 后检查'].includes(message)) { return 'unconfirmed'; }
    if (message === '配置已保存，地区选择待重连恢复' || message === '地区策略已关闭，但原选项未恢复') { return 'committed-pending'; }
    if (message === '请先在代理面板选择可用节点，再关闭或切换地区策略') { return 'selection-required'; }
    return 'failed';
  }

  export function key(kind: ProfileApplyFailureKind): string {
    if (kind === 'unconfirmed') { return 'apply_feedback_unconfirmed'; }
    if (kind === 'committed-pending') { return 'apply_feedback_committed'; }
    if (kind === 'selection-required') { return 'apply_feedback_selection'; }
    return 'apply_feedback_failed';
  }

  /** The existing successful provenance and runtime record also survive reopening. */
  export function recovery(context: common.Context): ProfileApplyFailureKind | '' {
    try {
      if (ProfileStore.isApplyUncertain(context)) { return 'unconfirmed'; }
      const state = EffectiveVersions.read(context);
      const file = ProfileStore.getActiveFile(context);
      const version = state?.Profiles[file];
      if (version === undefined) { return ''; }
      const selector = ProfileRegionChoices.selector(EffectiveVersions.editIntent(context, version),
        EffectiveVersions.regionPlan(context, version));
      const choice = ProfileRegionChoices.read(context, file, version, selector);
      if (VpnController.status === VpnStatus.Connected &&
        (choice.pending !== '' || (choice.previous !== undefined && choice.previous.selector !== selector))) {
        return 'committed-pending';
      }
      return '';
    } catch (_) { return 'unconfirmed'; }
  }
}
