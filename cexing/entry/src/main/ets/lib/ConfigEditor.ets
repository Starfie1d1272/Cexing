/* Private structured-editor reads on the existing C++ single worker. */
import { common } from '@kit.AbilityKit';
import core from 'libentry.so';
import { MergePreview } from './CoreValidator';
import { RegionPlan } from './EffectiveVersions';
import { TemplateSnapshot } from './TemplateUpdates';

export interface EditOperation {
  id: string;
  kind: string;
  section: string;
  target?: string;
  expected?: string;
  preconditions?: Record<string, string>;
  value?: Object;
  patch?: Record<string, Object>;
  remove?: string[];
  before?: string;
  name?: string;
}
export interface TemplatePlan {
  templateId: string;
  version: number;
  targetGroup?: string;
  region?: RegionPlan;
  replaceRules?: boolean;
  baseline?: TemplateSnapshot;
  mine?: TemplateSnapshot;
}
export interface EditIntent {
  schemaVersion: number;
  revision: string;
  sourceRevision: string;
  disabled?: boolean;
  operations: EditOperation[];
  smartGroups?: Record<string, boolean>;
  template?: TemplatePlan;
}
export interface EditorProviderRef { id: string; name: string; type?: string; state: string; count?: number; }
export interface EditableItem {
  id: string;
  revision: string;
  type?: string;
  fields?: Record<string, string>;
  name?: string;
  sourceName?: string;
  disabled?: boolean;
  providers?: EditorProviderRef[];
}
export interface EditableSection { section: string; items: EditableItem[]; }
export interface EditableSnapshot { sourceRevision: string; missingFieldRevision: string; sections: EditableSection[]; }
/** Sensitive; fetch only when the user explicitly opens a target for editing. */
export interface EditTarget { item: EditableItem; missingFieldRevision: string; value: Object; name?: string; }
export interface SmartGroupChange { id: string; choiceId: string; before: string; after: string; override: boolean; }
export class EditIntentFailure extends Error {
  code: string;
  operation: number;
  constructor(code: string, operation: number) {
    super('EDIT_INTENT_FAILED'); this.code = code; this.operation = operation;
  }
}
interface EditorReadRequest {
  op: string;
  original: string;
  overlay: string;
  expected: string;
  globalMerge?: string;
  updateGlobal: boolean;
  editSection?: string;
  editTarget?: string;
  smartConversion?: boolean;
  editIntent?: EditIntent;
  regionPlan?: RegionPlan | null;
  overrides?: string;
}
export namespace ConfigEditor {
  /** ArkTS does not structurally assign the wizard's distinct TemplatePlan. */
  export function templatePlan(templateId: string, version: number, targetGroup?: string,
    region?: RegionPlan, replaceRules?: boolean): TemplatePlan {
    return { templateId: templateId, version: version, targetGroup: targetGroup,
      region: region, replaceRules: replaceRules };
  }

  /** Explicit editor list: private names/references, never a default preview. */
  export async function list(context: common.Context, original: string, overlay: string,
    expected: string, globalMerge?: string, intent?: EditIntent, regionPlan?: RegionPlan): Promise<EditableSnapshot> {
    const response = await call(context, { op: 'editor-list', original: original,
      overlay: overlay, expected: expected, globalMerge: globalMerge, editIntent: intent,
      regionPlan: regionPlan, updateGlobal: globalMerge !== undefined });
    const view = response['editable'] as EditableSnapshot;
    if (view === undefined || typeof view.missingFieldRevision !== 'string' || !Array.isArray(view.sections)) {
      throw new Error('EDIT_READ_FAILED');
    }
    return view;
  }

  export async function smartPreview(context: common.Context, original: string, overlay: string,
    expected: string, defaultEnabled: boolean, intent?: EditIntent, globalMerge?: string, regionPlan?: RegionPlan): Promise<SmartGroupChange[]> {
    const response = await call(context, { op: 'smart-preview', original: original, overlay: overlay,
      expected: expected, smartConversion: defaultEnabled, editIntent: intent, globalMerge: globalMerge, regionPlan: regionPlan,
      updateGlobal: globalMerge !== undefined });
    const view = response['smartPreview'] as SmartGroupChange[];
    if (!Array.isArray(view)) { throw new Error('SMART_PREVIEW_FAILED'); }
    return view;
  }

  /** Settings/provider identity must be rechecked by the transaction on apply. */
  export async function preview(context: common.Context, original: string, overlay: string,
    expected: string, overrides: string, defaultEnabled: boolean, intent: EditIntent,
    regionPlan: RegionPlan | null, globalMerge?: string): Promise<MergePreview> {
    const response = await call(context, { op: 'edit-preview', original: original, overlay: overlay,
      expected: expected, overrides: overrides, smartConversion: defaultEnabled, editIntent: intent,
      regionPlan: regionPlan, globalMerge: globalMerge, updateGlobal: globalMerge !== undefined });
    const view = response['mergePreview'] as MergePreview;
    if (view === undefined || typeof view.digest !== 'string' || !Array.isArray(view.changes)) {
      throw new Error('EDIT_PREVIEW_FAILED');
    }
    return view;
  }

  async function call(context: common.Context, request: EditorReadRequest): Promise<Record<string, Object>> {
    const raw = await core.versionAction(context.filesDir, JSON.stringify(request));
    const response = JSON.parse(raw) as Record<string, Object>;
    if (typeof response['error'] === 'string') {
      const failure = response['editError'] as Record<string, Object>;
      if (failure !== undefined && typeof failure['code'] === 'string' && typeof failure['operation'] === 'number') {
        throw new EditIntentFailure(failure['code'] as string, failure['operation'] as number);
      }
      throw new Error(response['error'] as string);
    }
    return response;
  }

  /** expected is captured by the caller before starting asynchronous work. */
  export async function read(context: common.Context, original: string, overlay: string,
    expected: string, globalMerge?: string, intent?: EditIntent, regionPlan?: RegionPlan): Promise<EditableSnapshot> {
    const response = await call(context, { op: 'edit-read', original: original,
      overlay: overlay, expected: expected, globalMerge: globalMerge, editIntent: intent, regionPlan: regionPlan,
      updateGlobal: globalMerge !== undefined });
    const view = response['editable'] as EditableSnapshot;
    if (view === undefined || typeof view.sourceRevision !== 'string' || !Array.isArray(view.sections)) {
      throw new Error('EDIT_READ_FAILED');
    }
    return view;
  }

  export async function target(context: common.Context, original: string, overlay: string,
    expected: string, section: string, id: string, globalMerge?: string, intent?: EditIntent, regionPlan?: RegionPlan): Promise<EditTarget> {
    const response = await call(context, { op: 'edit-target', original: original,
      overlay: overlay, expected: expected, globalMerge: globalMerge,
      updateGlobal: globalMerge !== undefined, editSection: section, editTarget: id, editIntent: intent, regionPlan: regionPlan });
    const view = response['editTarget'] as EditTarget;
    if (view === undefined || view.item === undefined || view.item.id !== id) {
      throw new Error('EDIT_TARGET_FAILED');
    }
    return view;
  }
}

/** Shared #146 host contract. The reliability group implements this inside the
 * existing transaction gate; UI components never create their own file store. */
export interface EditorDraftSession {
  profileId: string;
  revision: string;
  intent: EditIntent | null;
  snapshot: EditableSnapshot;
}
export interface EditorDraftPreview {
  revision: string;
  digest: string;
  changes: MergePreview;
}
export interface EditorDraftHost {
  load: () => Promise<EditorDraftSession>;
  target: (section: string, id: string, revision: string) => Promise<EditTarget>;
  save: (intent: EditIntent, expectedRevision: string) => Promise<EditorDraftSession>;
  preview: (expectedRevision: string) => Promise<EditorDraftPreview>;
  apply: (preview: EditorDraftPreview) => Promise<string>;
  undo: (expectedRevision: string) => Promise<EditorDraftSession>;
}
