import { common } from '@kit.AbilityKit';
import core from 'libentry.so';
import { TemplatePreview } from './TemplateWizardModel';
import { ProfileApplyFeedback, ProfileApplyFailureKind } from './ProfileApplyFeedback';

// Private compiler snapshots only, never log/support-export these values.
export interface TemplateEntity { id: string; section: string; value: Object; }
export interface TemplateSnapshot { templateId: string; version: number; entries: TemplateEntity[]; deleted?: string[]; }
export interface TemplateUpdateRequest {
  kind: string; base: TemplateSnapshot; mine: TemplateSnapshot; next: TemplateSnapshot;
  decisions?: Record<string, string>;
}
export interface TemplateConflict { id: string; entity: string; section: string; path?: string[]; kind: string; }
export interface TemplateUpdatePreview { ready: boolean; candidate?: TemplateSnapshot; conflicts: TemplateConflict[]; validation?: TemplatePreview; }

export namespace TemplateUpdates {
  /** Pure preview through the existing single worker, never a new save API. */
  export async function preview(context: common.Context, request: TemplateUpdateRequest): Promise<TemplateUpdatePreview> {
    const input = JSON.stringify({ op: 'template-update-preview', request: request });
    if (input.length > 4 * 1024 * 1024) { throw new Error('TEMPLATE_UPDATE_LIMIT'); }
    const raw = await core.versionAction(context.filesDir, input);
    const error = JSON.parse(raw) as Record<string, Object>;
    if (typeof error['error'] === 'string') { throw new Error('TEMPLATE_UPDATE_INVALID'); }
    const result = JSON.parse(raw) as TemplateUpdatePreview;
    if (typeof result.ready !== 'boolean' || !Array.isArray(result.conflicts) ||
      (result.ready && result.candidate === undefined) || (!result.ready && result.candidate !== undefined)) {
      throw new Error('TEMPLATE_UPDATE_INVALID');
    }
    return result;
  }
}

export interface TemplateUpdateHost {
  reset?: () => void;
  // Captures Base/Mine/Next and the existing source/draft/active ticket once.
  preview: (decisions: Record<string, string>) => Promise<TemplateUpdatePreview>;
  // Compile a delta over the latest template through the common EditIntent;
  // compare the captured ticket, then use ProfileTransactions. No list Merge.
  apply: (preview: TemplateUpdatePreview) => Promise<string>;
  label: (conflict: TemplateConflict) => string;
}

export class TemplateUpdateModel {
  applyFailure: ProfileApplyFailureKind | '' = '';
  preview: TemplateUpdatePreview | null = null;
  busy: boolean = false;
  error: string = '';
  result: string = '';
  private decisions: Record<string, string> = {};
  private generation: number = 0;
  private open: boolean = true;
  private host: TemplateUpdateHost;
  private changed: () => void;
  constructor(host: TemplateUpdateHost, changed: () => void) { this.host = host; this.changed = changed; }
  close(): void { this.open = false; this.generation++; this.host.reset?.(); }
  needsRepair(): boolean { return this.applyFailure !== '' && this.applyFailure !== 'failed'; }
  setApplyFailure(kind: ProfileApplyFailureKind | ''): void {
    this.generation++; this.busy = false; this.applyFailure = kind; this.preview = null;
    this.error = ''; this.result = ''; this.emit();
  }
  private current(generation: number): boolean { return this.open && this.generation === generation; }
  private emit(): void { if (this.open) { this.changed(); } }
  async refresh(): Promise<void> {
    if (!this.open || this.busy || this.needsRepair()) { return; }
    const generation = ++this.generation;
    this.busy = true; this.error = ''; this.result = ''; this.preview = null; this.emit();
    try {
      const decisions: Record<string, string> = {};
      for (const id of Object.keys(this.decisions)) { decisions[id] = this.decisions[id]; }
      const result = await this.host.preview(decisions);
      if (result.ready && (result.conflicts.length > 0 || result.validation === undefined || result.validation.digest.length === 0)) {
        throw new Error('TEMPLATE_VALIDATION_REQUIRED');
      }
      if (this.current(generation)) { this.preview = result; }
    } catch (error) { if (this.current(generation)) { this.error = (error as Error).message === 'TEMPLATE_UPDATE_PRECISION' ?
      '部分高级字段需通过高级编辑修改' : '无法比较，请重新预览'; } }
    finally { if (this.current(generation)) { this.busy = false; this.emit(); } }
  }
  async choose(id: string, choice: string): Promise<void> {
    if (this.busy || !this.open || this.preview === null || !['mine', 'template'].includes(choice) ||
      !this.preview.conflicts.some((c: TemplateConflict) => c.id === id)) { return; }
    this.decisions[id] = choice;
    await this.refresh();
  }
  async reset(): Promise<void> { if (this.busy || !this.open || this.needsRepair()) { return; } this.decisions = {}; this.host.reset?.(); await this.refresh(); }
  async apply(): Promise<void> {
    const preview = this.preview;
    if (!this.open || this.busy || this.needsRepair() || preview === null || !preview.ready || preview.conflicts.length > 0 || preview.candidate === undefined || preview.validation === undefined) { return; }
    const generation = ++this.generation;
    this.busy = true; this.error = ''; this.emit();
    try {
      const result = await this.host.apply(preview);
      if (this.current(generation)) { this.result = result; this.preview = null; }
    } catch (error) {
      if (this.current(generation)) {
        this.applyFailure = ProfileApplyFeedback.classify((error as Error)?.message ?? '');
        this.error = this.applyFailure === 'failed' ? '应用失败，请重新预览' : '';
        this.preview = null;
      }
    } finally { if (this.current(generation)) { this.busy = false; this.emit(); } }
  }
}
