/* Template UI owns a draft only. The host must use ProfileTransactions and the
 * existing effective version; it never writes settings or publishes YAML here. */
import { TemplatePlan as EditorTemplatePlan } from './ConfigEditor';
import { templateApplyFailure } from './TemplateUpdates';

export type TemplatePlan = EditorTemplatePlan;
export interface TemplateInputs {
  groups: string[];
  selectors: string[];
  labels?: Record<string, string>;
  current: TemplatePlan;
}
export interface TemplatePreview {
  revision: string;
  digest: string;
  summary: string;
  inactiveEdits?: boolean;
}
export interface TemplateWizardHost {
  load: () => Promise<TemplateInputs>;
  preview: (plan: TemplatePlan) => Promise<TemplatePreview>;
  // Verify revision AND digest against the latest original, both Merge layers,
  // settings and provider snapshot inside the existing transaction gate.
  apply: (plan: TemplatePlan, preview: TemplatePreview, confirmed?: boolean) => Promise<string>;
}

export interface TemplateWizardView {
  templateId: string;
  target: string;
  busy: boolean;
  ready: boolean;
  error: string;
  result: string;
  summary: string;
  hasPreview: boolean;
  groups: string[];
  selectors: string[];
  labels?: Record<string, string>;
}

export class TemplateWizardModel {
  inputs: TemplateInputs = { groups: [], selectors: [], current: { templateId: 'original', version: 1 } };
  templateId: string = 'original';
  target: string = '';
  preview: TemplatePreview | null = null;
  busy: boolean = false;
  ready: boolean = false;
  error: string = '';
  result: string = '';
  private recoveryRequired: boolean = false;
  private epoch: number = 0;
  private open: boolean = true;
  private host: TemplateWizardHost;
  private changed: () => void;

  constructor(host: TemplateWizardHost, changed: () => void) { this.host = host; this.changed = changed; }

  snapshot(): TemplateWizardView {
    return { templateId: this.templateId, target: this.target, busy: this.busy,
      ready: this.ready, error: this.error, result: this.result,
      summary: this.preview?.summary ?? '', hasPreview: this.preview !== null,
      groups: this.inputs.groups, selectors: this.inputs.selectors, labels: this.inputs.labels };
  }

  close(): void { this.open = false; this.epoch++; }
  private emit(): void { if (this.open) { this.changed(); } }
  private current(epoch: number): boolean { return this.open && this.epoch === epoch; }

  async load(): Promise<void> {
    if (!this.open || this.busy || this.recoveryRequired) { return; }
    const epoch = ++this.epoch;
    this.busy = true;
    this.emit();
    try {
      const inputs = await this.host.load();
      if (!this.current(epoch)) { return; }
      if (inputs.current.version !== 1) { throw new Error('unsupported template version'); }
      this.inputs = inputs;
      this.templateId = inputs.current.templateId;
      this.target = inputs.current.region?.selector ?? inputs.current.targetGroup ?? '';
      this.ready = true;
      this.error = '';
    } catch (_) { if (this.current(epoch)) { this.error = '方案读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }

  choose(templateId: string, target: string): void {
    if (!this.open || !this.ready || this.busy) { return; }
    if (!['original', 'region', 'ai', 'automatic'].includes(templateId)) { return; }
    this.epoch++;
    this.templateId = templateId;
    this.target = target;
    this.preview = null;
    this.error = '';
    this.result = '';
    this.emit();
  }

  private plan(): TemplatePlan {
    if (this.templateId === 'region') {
      // Preserve existing per-node corrections when retaining the selector.
      const previous = this.inputs.current.region;
      const assignments: Record<string, string> = previous?.selector === this.target ? previous.assignments : {};
      return { templateId: 'region', version: 1, region: { mode: 'region', selector: this.target,
        enable: true, assignments: assignments } };
    }
    if (this.templateId === 'original') { return { templateId: 'original', version: 1 }; }
    return { templateId: this.templateId, version: 1, targetGroup: this.target,
      replaceRules: this.templateId === 'automatic' };
  }

  async inspect(): Promise<void> {
    if (!this.open || !this.ready || this.busy) { return; }
    if (this.templateId !== 'original' && this.target === '') { this.error = '请选择出口'; this.emit(); return; }
    const epoch = ++this.epoch;
    this.busy = true;
    this.preview = null;
    this.error = '';
    this.result = '';
    this.emit();
    try {
      const preview = await this.host.preview(this.plan());
      if (!this.current(epoch)) { return; }
      this.preview = preview;
    } catch (_) { if (this.current(epoch)) { this.error = '方案未通过校验，请检查出口和订阅资源'; } }
    finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }

  async apply(confirmed: boolean = false): Promise<void> {
    if (!this.open || !this.ready || this.busy || this.preview === null) { return; }
    if ((this.templateId === 'automatic' || this.preview.inactiveEdits === true) && !confirmed) { return; }
    const epoch = ++this.epoch;
    const preview = this.preview;
    const plan = this.plan();
    this.busy = true;
    this.error = '';
    this.emit();
    try {
      const result = await this.host.apply(plan, preview, confirmed);
      if (!this.current(epoch)) { return; }
      this.inputs.current = plan;
      this.result = result;
      this.preview = null;
    } catch (error) {
      if (this.current(epoch)) {
        const failure = templateApplyFailure(error as Error);
        this.error = failure.kind === 'saved-recovery' ? '' : failure.message;
        this.result = failure.kind === 'saved-recovery' ? failure.message : '';
        if (failure.kind === 'saved-recovery') { this.inputs.current = plan; }
        if (failure.kind === 'unconfirmed' || failure.kind === 'saved-recovery') {
          this.ready = false; this.recoveryRequired = true;
        }
        this.preview = null;
      }
    } finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
}
