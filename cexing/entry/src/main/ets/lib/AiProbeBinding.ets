import { common } from '@kit.AbilityKit';
import { EffectiveVersions } from './EffectiveVersions';

// Cache the private successful-template metadata per view/version. Draft changes
// never authorize probes, and each form target must match the committed choice.
export class AiProbeBinding {
  private version: string = '';
  private target: string = '';
  revision(context: common.Context, profileId: string, target: string): string {
    try {
      const current = EffectiveVersions.read(context)?.Current;
      if (current === null || current === undefined || current.ProfileID !== profileId) { return ''; }
      if (current.ID !== this.version) {
        this.version = ''; this.target = '';
        const intent = EffectiveVersions.editIntent(context, current);
        if (intent !== null && intent.disabled !== true && intent.template?.templateId === 'ai') {
          this.target = intent.template.targetGroup ?? '';
        }
        this.version = current.ID;
      }
      return target.length > 0 && target === this.target ? current.ID : '';
    } catch (_) { this.version = ''; this.target = ''; return ''; }
  }
}
