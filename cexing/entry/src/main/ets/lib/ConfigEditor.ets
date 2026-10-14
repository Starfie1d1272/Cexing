/* Private structured-editor reads on the existing C++ single worker. */
import { common } from '@kit.AbilityKit';
import core from 'libentry.so';

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
export interface EditIntent {
  schemaVersion: number;
  revision: string;
  sourceRevision: string;
  disabled?: boolean;
  operations: EditOperation[];
  smartGroups?: Record<string, boolean>;
}
export interface EditableItem {
  id: string;
  revision: string;
  type?: string;
  fields?: Record<string, string>;
}
export interface EditableSection { section: string; items: EditableItem[]; }
export interface EditableSnapshot { sourceRevision: string; sections: EditableSection[]; }
/** Sensitive; fetch only when the user explicitly opens a target for editing. */
export interface EditTarget { item: EditableItem; value: Object; name?: string; }
interface EditorReadRequest {
  op: string;
  original: string;
  overlay: string;
  expected: string;
  globalMerge?: string;
  updateGlobal: boolean;
  editSection?: string;
  editTarget?: string;
}
export namespace ConfigEditor {
  async function call(context: common.Context, request: EditorReadRequest): Promise<Record<string, Object>> {
    const raw = await core.versionAction(context.filesDir, JSON.stringify(request));
    const response = JSON.parse(raw) as Record<string, Object>;
    if (typeof response['error'] === 'string') { throw new Error(response['error'] as string); }
    return response;
  }

  /** expected is captured by the caller before starting asynchronous work. */
  export async function read(context: common.Context, original: string, overlay: string,
    expected: string, globalMerge?: string): Promise<EditableSnapshot> {
    const response = await call(context, { op: 'edit-read', original: original,
      overlay: overlay, expected: expected, globalMerge: globalMerge,
      updateGlobal: globalMerge !== undefined });
    const view = response['editable'] as EditableSnapshot;
    if (view === undefined || typeof view.sourceRevision !== 'string' || !Array.isArray(view.sections)) {
      throw new Error('EDIT_READ_FAILED');
    }
    return view;
  }

  export async function target(context: common.Context, original: string, overlay: string,
    expected: string, section: string, id: string, globalMerge?: string): Promise<EditTarget> {
    const response = await call(context, { op: 'edit-target', original: original,
      overlay: overlay, expected: expected, globalMerge: globalMerge,
      updateGlobal: globalMerge !== undefined, editSection: section, editTarget: id });
    const view = response['editTarget'] as EditTarget;
    if (view === undefined || view.item === undefined || view.item.id !== id) {
      throw new Error('EDIT_TARGET_FAILED');
    }
    return view;
  }
}
