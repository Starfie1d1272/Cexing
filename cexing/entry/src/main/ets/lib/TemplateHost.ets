import { EditorDraftHosts } from './EditorDraftHosts';
import { common } from '@kit.AbilityKit';
import { ConfigEditor, EditIntent, EditorDraftHost, EditorDraftSession, EditorDraftPreview } from './ConfigEditor';
import { EffectiveVersions, RegionPlan } from './EffectiveVersions';
import { TemplatePlan, TemplateInputs, TemplatePreview, TemplateWizardHost } from './TemplateWizardModel';
import { ProfileTransactions } from './ProfileTransactions';
import { CoreValidator } from './CoreValidator';

function cloneIntent(session: EditorDraftSession): EditIntent {
  return session.intent !== null ? JSON.parse(JSON.stringify(session.intent)) as EditIntent : {
    schemaVersion: 1, revision: session.revision, sourceRevision: session.snapshot.sourceRevision, operations: []
  };
}
/** Production adapter over the one shared EditorDraftHost. No file writes or
 * publish/activation implementation belongs here. profileId is fixed at entry. */
export function createTemplateWizardHost(context: common.Context, profileId: string,
  suppliedEditor?: EditorDraftHost): TemplateWizardHost {
  const editor = suppliedEditor ?? EditorDraftHosts.create(context, profileId);
  let session: EditorDraftSession | null = null;
  let receipt: EditorDraftPreview | null = null;
  let planned: string = '';
  let inactiveEdits: boolean = false;
  let generation = 0;
  const published = (): EditIntent | null => {
    const version = EffectiveVersions.read(context)?.Profiles[profileId];
    return version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
  };
  const loadSession = async (): Promise<EditorDraftSession> => {
    const loaded = await editor.load();
    if (loaded.profileId !== profileId || loaded.revision.length === 0) { throw new Error('TEMPLATE_PROFILE_CHANGED'); }
    return loaded;
  };
  return {
    regionPreview: (plan: RegionPlan) => ProfileTransactions.previewRegion(context, profileId, plan),
    load: async (): Promise<TemplateInputs> => {
      const epoch = ++generation; receipt = null;
      const loaded = await loadSession();
      if (epoch !== generation) { throw new Error('TEMPLATE_CANCELLED'); }
      session = loaded;
      const items = loaded.snapshot.sections.find(section => section.section === 'proxy-groups')?.items ?? [];
      // Template precedes personal operations. Only source-defined groups are
      // eligible; show the final name while retaining the pre-rename value.
      const groups = items.filter(item => typeof item.sourceName === 'string' && item.sourceName.length > 0);
      const labels: Record<string, string> = {};
      groups.forEach(item => { labels[item.sourceName ?? ''] = item.name ?? item.sourceName ?? ''; });
      const saved = published();
      const regionVersion = EffectiveVersions.read(context)?.Profiles[profileId];
      const legacy = regionVersion !== undefined ? EffectiveVersions.regionPlan(context, regionVersion) : null;
      let current: TemplatePlan = loaded.intent?.template ?? { templateId: 'original', version: 1 };
      if (loaded.intent?.disabled === true) { current = { templateId: 'original', version: 1 }; }
      else if (loaded.intent?.template === undefined && saved?.template === undefined && legacy !== null &&
        legacy.enable && legacy.disabled !== true) { current = { templateId: 'region', version: 1, region: legacy }; }
      let applied: TemplatePlan = saved?.disabled === true ? { templateId: 'original', version: 1 } :
        saved?.template ?? { templateId: 'original', version: 1 };
      if (saved?.template === undefined && saved?.disabled !== true && legacy !== null &&
        legacy.enable && legacy.disabled !== true) { applied = { templateId: 'region', version: 1, region: legacy }; }
      return { groups: groups.map(item => item.sourceName ?? ''), labels: labels,
        selectors: groups.filter(item => item.type === 'select').map(item => item.sourceName ?? ''), current: current, published: applied, regionDraft: loaded.intent?.template?.region ??
          loaded.intent?.templateArchives?.['region']?.region ?? saved?.templateArchives?.['region']?.region ?? legacy ?? undefined };
    },
    preview: async (plan: TemplatePlan, pauseDependents?: boolean): Promise<TemplatePreview> => {
      const epoch = ++generation; receipt = null;
      const captured = session ?? await loadSession();
      if (epoch !== generation) { throw new Error('TEMPLATE_CANCELLED'); }
      let intent = cloneIntent(captured);
      const saved = published();
      const overrides: Record<string, boolean> = intent.smartGroups ?? {};
      inactiveEdits = saved?.disabled === true &&
        (intent.operations.length > 0 || Object.keys(overrides).length > 0) && plan.templateId !== 'original';
      const nextPlan = ConfigEditor.templatePlan(plan.templateId, plan.version, plan.targetGroup,
        plan.region !== undefined ? JSON.parse(JSON.stringify(plan.region)) as RegionPlan : undefined, plan.replaceRules);
      const switched = await ConfigEditor.switchTemplate(context, intent, nextPlan, pauseDependents === true);
      if (epoch !== generation) { throw new Error('TEMPLATE_CANCELLED'); }
      if (switched.dependentCount > 0) { throw new Error(`TEMPLATE_DEPENDENCIES:${switched.dependentCount}`); }
      if (switched.intent === undefined) { throw new Error('TEMPLATE_SWITCH_INVALID'); }
      intent = switched.intent;
      // This is an inert draft. Declining the eventual confirmation never
      // enables either template or personal changes in the running version.
      const next = await editor.save(intent, captured.revision);
      if (epoch !== generation) { throw new Error('TEMPLATE_CANCELLED'); }
      session = next;
      const preview = await editor.preview(next.revision);
      if (epoch !== generation) { throw new Error('TEMPLATE_CANCELLED'); }
      if (preview.digest.length === 0 || preview.changes.digest !== preview.digest) { throw new Error('TEMPLATE_PREVIEW_INVALID'); }
      receipt = preview; planned = JSON.stringify(plan);
      return { revision: preview.revision, digest: preview.digest,
        summary: CoreValidator.describeMergePreview(preview.changes), inactiveEdits: inactiveEdits };
    },
    apply: async (plan: TemplatePlan, preview: TemplatePreview, confirmed?: boolean): Promise<string> => {
      const checked = receipt;
      if (checked === null || checked.revision !== preview.revision || checked.digest !== preview.digest ||
        JSON.stringify(plan) !== planned) { throw new Error('TEMPLATE_PREVIEW_STALE'); }
      if (inactiveEdits && confirmed !== true) { throw new Error('TEMPLATE_CONFIRMATION_REQUIRED'); }
      receipt = null;
      try {
        const result = await editor.apply(checked);
        return result === 'applied' ? '方案已应用' : result === 'saved' ? '已保存，启用后生效' : result;
      } finally { session = null; }
    }
  };
}
