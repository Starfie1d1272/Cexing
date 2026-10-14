import { common } from '@kit.AbilityKit';
import core from 'libentry.so';
import { EditIntent, EditorDraftSession } from './ConfigEditor';
import { TemplateUpdateSource } from './TemplateUpdateHost';
import { TemplateConflict, TemplateSnapshot, TemplateUpdateRequest } from './TemplateUpdates';
import { EffectiveVersions } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { Settings } from './Settings';
import { CoreValidator } from './CoreValidator';

interface SourceInput {
  profileId: string; profileVersion: string; original: string; globalMerge: string;
  overlay: string; overrides: string; intent: EditIntent; action: string;
  stamp?: string; candidate?: TemplateSnapshot;
}
interface SourceReply { request?: TemplateUpdateRequest; stamp?: string; intent?: EditIntent; error?: string; }

/** Actual private worker source. Successful provenance supplies Base; the worker
 * captures Mine through common aliases and regenerates Next from latest inputs.
 * No endpoint fetch, file publication, cached body or editable YAML on the page. */
export function createTemplateUpdateSource(context: common.Context, profileId: string): TemplateUpdateSource {
  let captured: SourceInput | null = null;
  let revision = '';
  let stamp = '';
  let generation = 0;
  const call = async (input: SourceInput): Promise<SourceReply> => {
    const text = JSON.stringify({ op: 'template-update-preview', source: input });
    if (text.length > 50 * 1024 * 1024) { throw new Error('TEMPLATE_UPDATE_LIMIT'); }
    const raw = await core.versionAction(context.filesDir, text);
    const reply = JSON.parse(raw) as SourceReply;
    if (reply.error === 'TEMPLATE_UPDATE_PRECISION') { throw new Error('TEMPLATE_UPDATE_PRECISION'); }
    if (reply.error !== undefined) { throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED'); }
    return reply;
  };
  return {
    available: (templateId: string, target: string): boolean => {
      try {
        const version = EffectiveVersions.read(context)?.Profiles[profileId];
        const saved = version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
        const plan = saved?.template;
        return saved?.disabled !== true && plan !== undefined && plan.templateId !== 'original' &&
          plan.templateId === templateId && (plan.region?.selector ?? plan.targetGroup ?? '') === target;
      } catch (_) { return false; }
    },
    read: async (session: EditorDraftSession): Promise<TemplateUpdateRequest> => {
      const epoch = ++generation;
      captured = null; stamp = ''; revision = '';
      if (session.profileId !== profileId || session.intent?.template === undefined) {
        throw new Error('TEMPLATE_UPDATE_SESSION');
      }
      const version = EffectiveVersions.read(context)?.Profiles[profileId];
      const original = ProfileStore.getProfileContent(context, profileId);
      if (version === undefined || original === null) { throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED'); }
      const input: SourceInput = { profileId: profileId, profileVersion: version.ID,
        original: ProfileStore.prepareContent(original), globalMerge: EffectiveVersions.globalContent(context),
        overlay: ProfileStore.getEnabledMerge(context, profileId), overrides: JSON.stringify(Settings.load(context)),
        intent: JSON.parse(JSON.stringify(session.intent)) as EditIntent, action: 'read' };
      await CoreValidator.prepareResources(context);
      if (epoch !== generation) { throw new Error('TEMPLATE_UPDATE_SESSION'); }
      const reply = await call(input);
      if (epoch !== generation) { throw new Error('TEMPLATE_UPDATE_SESSION'); }
      if (reply.request === undefined || typeof reply.stamp !== 'string' || reply.stamp.length !== 64) {
        throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED');
      }
      captured = input; revision = session.revision; stamp = reply.stamp;
      return reply.request;
    },
    encode: async (candidate: TemplateSnapshot, session: EditorDraftSession): Promise<EditIntent> => {
      if (captured === null || session.revision !== revision || session.profileId !== profileId ||
        JSON.stringify(session.intent) !== JSON.stringify(captured.intent)) {
        throw new Error('TEMPLATE_UPDATE_SESSION');
      }
      const epoch = generation;
      const input = JSON.parse(JSON.stringify(captured)) as SourceInput;
      input.action = 'encode'; input.stamp = stamp;
      input.candidate = JSON.parse(JSON.stringify(candidate)) as TemplateSnapshot;
      const reply = await call(input);
      if (epoch !== generation || reply.intent === undefined) { throw new Error('TEMPLATE_UPDATE_VALIDATION'); }
      return reply.intent;
    },
    label: (conflict: TemplateConflict): string => {
      const labels: Record<string, string> = { 'rules': '分流规则', 'proxy-groups': '策略组', 'proxies': '节点',
        'proxy-providers': '节点来源', 'rule-providers': '规则来源', 'dns': 'DNS', 'hosts': '域名映射' };
      return labels[conflict.section] ?? '个人修改';
    }
  };
}
