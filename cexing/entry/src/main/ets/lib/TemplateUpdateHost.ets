import { EditorDraftHosts } from './EditorDraftHosts';
import { common } from '@kit.AbilityKit';
import { EditIntent, EditorDraftHost, EditorDraftSession, EditorDraftPreview } from './ConfigEditor';
import { TemplateConflict, TemplateSnapshot, TemplateUpdateHost, TemplateUpdatePreview,
  TemplateUpdateRequest, TemplateUpdates, TemplateConflictDetail } from './TemplateUpdates';

/** Compiler-owned private data conversion. These callbacks must use the common
 * template schema/aliases, never a list Merge or a second persistence service. */
export interface TemplateUpdateSource {
  available?: (templateId: string, target: string) => boolean;
  read: (session: EditorDraftSession) => Promise<TemplateUpdateRequest>;
  encode: (candidate: TemplateSnapshot, session: EditorDraftSession) => Promise<EditIntent>;
  label: (conflict: TemplateConflict) => string;
  detail?: (conflict: TemplateConflict) => TemplateConflictDetail;
}

/** Consume the shared draft transaction exactly once for a resolved upgrade.
 * Compiler bindings remain inside the worker; only inert intent reaches save. */
export function createTemplateUpdateHost(context: common.Context, profileId: string,
  suppliedEditor: EditorDraftHost | undefined, source: TemplateUpdateSource): TemplateUpdateHost {
  const editor = suppliedEditor ?? EditorDraftHosts.create(context, profileId);
  let session: EditorDraftSession | null = null;
  let request: TemplateUpdateRequest | null = null;
  let receipt: EditorDraftPreview | null = null;
  let offered: TemplateUpdatePreview | null = null;
  let fingerprint = '';
  let generation = 0;
  return {
    reset: (): void => { generation++; session = null; request = null; receipt = null; offered = null; },
    label: (conflict: TemplateConflict): string => source.label(conflict),
    detail: (conflict: TemplateConflict): TemplateConflictDetail => source.detail?.(conflict) ?? {
      title: source.label(conflict), mine: '我的修改', template: '新模板的修改' },
    preview: async (decisions: Record<string, string>): Promise<TemplateUpdatePreview> => {
      const epoch = ++generation; receipt = null; offered = null;
      try {
      if (session === null || request === null) {
        const loaded = await editor.load();
        if (epoch !== generation || loaded.profileId !== profileId || loaded.revision.length === 0) {
          throw new Error('TEMPLATE_UPDATE_SESSION');
        }
        const inputs = await source.read(loaded);
        if (epoch !== generation) { throw new Error('TEMPLATE_UPDATE_CANCELLED'); }
        session = loaded;
        request = JSON.parse(JSON.stringify(inputs)) as TemplateUpdateRequest;
      }
      const captured = session;
      const input = JSON.parse(JSON.stringify(request)) as TemplateUpdateRequest;
      input.decisions = JSON.parse(JSON.stringify(decisions)) as Record<string, string>;
      const comparison = await TemplateUpdates.preview(context, input);
      if (epoch !== generation) { throw new Error('TEMPLATE_UPDATE_CANCELLED'); }
      if (!comparison.ready) { return comparison; }
      if (comparison.conflicts.length !== 0 || comparison.candidate === undefined) {
        throw new Error('TEMPLATE_UPDATE_UNRESOLVED');
      }
      const intent = await source.encode(comparison.candidate, captured);
      if (epoch !== generation || intent.template?.templateId !== comparison.candidate.templateId ||
        intent.template?.version !== comparison.candidate.version ||
        intent.sourceRevision !== (captured.intent?.sourceRevision ?? captured.snapshot.sourceRevision) ||
        (intent.disabled === true) !== (captured.intent?.disabled === true) ||
        JSON.stringify(intent.smartGroups ?? {}) !== JSON.stringify(captured.intent?.smartGroups ?? {})) {
        throw new Error('TEMPLATE_UPDATE_PLAN');
      }
      const next = await editor.save(intent, captured.revision);
      if (epoch !== generation || next.profileId !== profileId) { throw new Error('TEMPLATE_UPDATE_SESSION'); }
      session = next;
      const checked = await editor.preview(next.revision);
      if (epoch !== generation || checked.revision !== next.revision || checked.digest.length === 0 ||
        checked.changes.digest !== checked.digest) { throw new Error('TEMPLATE_UPDATE_VALIDATION'); }
      const count = checked.changes.changes.length;
      comparison.validation = { revision: checked.revision, digest: checked.digest,
        summary: count > 0 ? `${count} 项配置变化` : '配置无变化' };
      receipt = checked; offered = comparison; fingerprint = JSON.stringify(comparison);
      return comparison;
      } catch (error) {
        if (epoch === generation) { session = null; request = null; receipt = null; offered = null; }
        throw error as Error;
      }
    },
    apply: async (preview: TemplateUpdatePreview): Promise<string> => {
      if (receipt === null || preview !== offered || JSON.stringify(preview) !== fingerprint) {
        throw new Error('TEMPLATE_UPDATE_STALE');
      }
      const checked = receipt;
      receipt = null; offered = null; session = null; request = null;
      // The transaction owns its atomic source/draft/settings/provider checks.
      // Passing the original object preserves its complete opaque receipt.
      const result = await editor.apply(checked);
      return result === 'applied' ? '更新已应用' : result === 'saved' ? '已保存，启用后生效' : result;
    }
  };
}
