import { common } from '@kit.AbilityKit';
import core from 'libentry.so';
import { EditIntent, EditorDraftSession } from './ConfigEditor';
import { TemplateUpdateSource } from './TemplateUpdateHost';
import { TemplateConflict, TemplateSnapshot, TemplateUpdateRequest } from './TemplateUpdates';
import { EffectiveVersions } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { Settings } from './Settings';
import { EditorSourceCandidate } from './EditorDraftHosts';
import { CoreValidator } from './CoreValidator';
import { ProfileTransactions, EditTicket } from './ProfileTransactions';

interface SourceInput {
  profileId: string; profileVersion: string; original: string; globalMerge: string;
  overlay: string; overrides: string; intent: EditIntent; action: string;
  stamp?: string; candidate?: TemplateSnapshot; resolvedDraft?: boolean;
}
interface SourceReply { request?: TemplateUpdateRequest; stamp?: string; intent?: EditIntent; error?: string; }

/** Actual private worker source. Successful provenance supplies Base; the worker
 * captures Mine through common aliases and regenerates Next from latest inputs.
 * No endpoint fetch, file publication, cached body or editable YAML on the page. */
export function createTemplateUpdateSource(context: common.Context, profileId: string, sourceOverride?: EditorSourceCandidate): TemplateUpdateSource {
  const candidateOriginal = sourceOverride?.original;
  let captured: SourceInput | null = null;
  let revision = '';
  let stamp = '';
  let generation = 0;
  let ticket: EditTicket | null = null;
  const check = (expected: EditTicket, epoch: number): void => {
    if (epoch !== generation) { throw new Error('TEMPLATE_UPDATE_SESSION'); }
    if (JSON.stringify(expected) !== JSON.stringify(ProfileTransactions.editTicket(context, profileId))) {
      throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED');
    }
  };
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
    cancel: (): void => { generation++; captured = null; ticket = null; revision = ''; stamp = ''; },
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
      captured = null; ticket = null; stamp = ''; revision = '';
      if (session.profileId !== profileId || session.intent?.template === undefined) {
        throw new Error('TEMPLATE_UPDATE_SESSION');
      }
      const expected = ProfileTransactions.editTicket(context, profileId);
      if (expected.draftRevision !== session.intent.revision) { throw new Error('TEMPLATE_UPDATE_SESSION'); }
      const restored = await ProfileTransactions.readEditSource(context, expected, () => epoch === generation);
      check(expected, epoch);
      const version = EffectiveVersions.read(context)?.Profiles[profileId];
      if (restored !== undefined && candidateOriginal !== undefined && candidateOriginal !== restored.original) {
        throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED');
      }
      const original = candidateOriginal ?? restored?.original ?? ProfileStore.getProfileContent(context, profileId);
      if (version === undefined || version.ID !== expected.profileVersion || original === null) { throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED'); }
      const input: SourceInput = { profileId: profileId, profileVersion: version.ID,
        original: ProfileStore.prepareContent(original), globalMerge: EffectiveVersions.globalContent(context),
        overlay: ProfileStore.getEnabledMerge(context, profileId), overrides: JSON.stringify(Settings.load(context)),
        intent: JSON.parse(JSON.stringify(session.intent)) as EditIntent, action: 'read',
        resolvedDraft: restored !== undefined && session.intent.revision === expected.draftRevision &&
          (candidateOriginal === undefined || candidateOriginal === restored.original) };
      await CoreValidator.prepareResources(context);
      check(expected, epoch);
      const reply = await call(input);
      check(expected, epoch);
      if (reply.request === undefined || typeof reply.stamp !== 'string' || reply.stamp.length !== 64) {
        throw new Error('TEMPLATE_UPDATE_SOURCE_CHANGED');
      }
      captured = input; ticket = expected; revision = session.revision; stamp = reply.stamp;
      return reply.request;
    },
    encode: async (candidate: TemplateSnapshot, session: EditorDraftSession): Promise<EditIntent> => {
      if (captured === null || ticket === null || session.revision !== revision || session.profileId !== profileId ||
        JSON.stringify(session.intent) !== JSON.stringify(captured.intent)) {
        throw new Error('TEMPLATE_UPDATE_SESSION');
      }
      const epoch = generation;
      const expected = ticket; check(expected, epoch);
      const input = JSON.parse(JSON.stringify(captured)) as SourceInput;
      input.action = 'encode'; input.stamp = stamp;
      input.candidate = JSON.parse(JSON.stringify(candidate)) as TemplateSnapshot;
      const reply = await call(input);
      check(expected, epoch);
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
