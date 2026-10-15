/* Template UI owns a draft only. The host must use ProfileTransactions and the
 * existing effective version; it never writes settings or publishes YAML here. */
import { RegionPlan, RegionPreview } from './EffectiveVersions';
import { RoutingPlan, RoutingCatalogue, TemplatePlan as EditorTemplatePlan } from './ConfigEditor';
import { ProfileApplyFeedback, ProfileApplyFailureKind } from './ProfileApplyFeedback';

export type TemplatePlan = EditorTemplatePlan;
export interface TemplateInputs {
  groups: string[];
  selectors: string[];
  labels?: Record<string, string>;
  current: TemplatePlan;
  published?: TemplatePlan;
  regionDraft?: RegionPlan;
  hasLegacy?: boolean;
  managedDraft?: RoutingPlan;
}
export interface TemplatePreview {
  revision: string;
  digest: string;
  summary: string;
  inactiveEdits?: boolean;
  smartCount?: number;
}
export interface TemplateWizardHost {
  catalogue?: () => Promise<RoutingCatalogue>;
  smart?: () => Promise<TemplatePreview>;
  load: () => Promise<TemplateInputs>;
  regionPreview?: (plan: RegionPlan) => Promise<RegionPreview>;
  preview: (plan: TemplatePlan, pauseDependents?: boolean) => Promise<TemplatePreview>;
  // Verify revision AND digest against the latest original, both Merge layers,
  // settings and provider snapshot inside the existing transaction gate.
  apply: (plan: TemplatePlan, preview: TemplatePreview, confirmed?: boolean) => Promise<string>;
}

export interface TemplateWizardView {
  publishedId?: string;
  changed?: boolean;
  dependencies?: number;
  applyFailure?: ProfileApplyFailureKind | '';
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
  dependencies: number = 0;
  applyFailure: ProfileApplyFailureKind | '' = '';
  inputs: TemplateInputs = { groups: [], selectors: [], current: { templateId: 'original', version: 1 } };
  templateId: string = 'original';
  target: string = '';
  private region: RegionPlan = { mode: 'region', selector: '', enable: true, assignments: {} };
  preview: TemplatePreview | null = null;
  busy: boolean = false;
  ready: boolean = false;
  error: string = '';
  result: string = '';
  private epoch: number = 0;
  private open: boolean = true;
  private host: TemplateWizardHost;
  private changed: () => void;

  constructor(host: TemplateWizardHost, changed: () => void) { this.host = host; this.changed = changed; }

  snapshot(): TemplateWizardView {
    return { publishedId: (this.inputs.published ?? this.inputs.current).templateId, changed: this.hasChanges(), dependencies: this.dependencies, applyFailure: this.applyFailure, templateId: this.templateId, target: this.target, busy: this.busy,
      ready: this.ready, error: this.error, result: this.result,
      summary: this.preview?.summary ?? '', hasPreview: this.preview !== null,
      groups: this.inputs.groups, selectors: this.inputs.selectors, labels: this.inputs.labels };
  }

  close(): void { this.open = false; this.epoch++; }
  needsRepair(): boolean { return this.applyFailure !== '' && this.applyFailure !== 'failed'; }
  setApplyFailure(kind: ProfileApplyFailureKind | ''): void {
    this.epoch++; this.busy = false; this.applyFailure = kind; this.preview = null; this.error = ''; this.result = ''; this.emit();
  }
  private emit(): void { if (this.open) { this.changed(); } }
  private current(epoch: number): boolean { return this.open && this.epoch === epoch; }

  async load(): Promise<void> {
    if (!this.open || this.busy || this.needsRepair()) { return; }
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
      this.region = this.copyRegion(inputs.current.region ?? inputs.regionDraft ?? inputs.published?.region ??
        { mode: 'region', selector: '', enable: true, assignments: {} });
      this.ready = true;
      this.error = '';
    } catch (_) { if (this.current(epoch)) { this.error = '方案读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }

  choose(templateId: string, target: string): void {
    if (!this.open || !this.ready || this.busy || this.needsRepair()) { return; }
    if (!['original', 'region', 'ai', 'automatic'].includes(templateId)) { return; }
    if (templateId === this.templateId && (target === '' || target === this.target)) { return; }
    this.epoch++;
    this.dependencies = 0;
    if (templateId === 'region') {
      target = target || this.region.selector;
      const saved = this.inputs.current.region;
      const previous = this.region.selector === target ? this.region : saved?.selector === target ? saved : undefined;
      this.region = this.copyRegion({ mode: previous?.mode ?? this.region.mode, selector: target,
        enable: true, assignments: previous?.assignments ?? {} });
    }
    this.templateId = templateId;
    this.target = target;
    this.preview = null;
    this.error = '';
    this.result = '';
    this.emit();
  }

  private copyRegion(plan: RegionPlan): RegionPlan {
    return JSON.parse(JSON.stringify(plan)) as RegionPlan;
  }

  regionPlan(): RegionPlan { return this.copyRegion(this.region); }

  configureRegion(mode: string, assignments: Record<string, string>): void {
    if (!this.open || !this.ready || this.busy || this.needsRepair() || this.templateId !== 'region' ||
      !['region', 'all'].includes(mode)) { return; }
    this.region = this.copyRegion({ mode: mode, selector: this.target, enable: true, assignments: assignments });
    this.preview = null; this.error = ''; this.result = ''; this.dependencies = 0; this.epoch++; this.emit();
  }

  regionActivation(enable: boolean): void {
    if (this.busy || this.needsRepair() || this.templateId !== 'region') { return; }
    this.region.enable = enable; this.preview = null; this.epoch++; this.emit();
  }

  async previewRegion(plan: RegionPlan): Promise<RegionPreview> {
    if (!this.open || !this.ready || this.busy || this.needsRepair() || this.host.regionPreview === undefined) {
      throw new Error('TEMPLATE_REGION_UNAVAILABLE');
    }
    return this.host.regionPreview(this.copyRegion(plan));
  }

  /** Compare all effective v1 authoring fields. Compiler baseline/Mine snapshots
   * are provenance, not another editable plan. Mapping insertion order is inert. */
  static planKey(plan: TemplatePlan): string {
    let effective: TemplatePlan;
    if (plan.templateId === 'region') {
      const region = plan.region;
      const assignments: Record<string, string> = {};
      const source: Record<string, string> = region?.assignments ?? {};
      for (const key of Object.keys(source).sort()) { assignments[key] = source[key]; }
      effective = { templateId: plan.templateId, version: plan.version,
        region: { mode: region?.mode ?? 'region', selector: region?.selector ?? '',
          enable: region?.enable !== false, disabled: region?.disabled === true, assignments: assignments } };
    } else if (plan.templateId === 'original') {
      effective = { templateId: plan.templateId, version: plan.version };
    } else {
      effective = { templateId: plan.templateId, version: plan.version,
        targetGroup: plan.targetGroup ?? '', replaceRules: plan.replaceRules === true };
    }
    return JSON.stringify(effective);
  }

  hasChanges(): boolean {
    return TemplateWizardModel.planKey(this.plan()) !== TemplateWizardModel.planKey(this.inputs.published ?? this.inputs.current);
  }

  private plan(): TemplatePlan {
    if (this.templateId === 'region') {
      return { templateId: 'region', version: 1, region: this.regionPlan() };
    }
    if (this.templateId === 'original') { return { templateId: 'original', version: 1 }; }
    return { templateId: this.templateId, version: 1, targetGroup: this.target,
      replaceRules: this.templateId === 'automatic' };
  }

  async inspect(pauseDependents: boolean = false): Promise<void> {
    if (!this.open || !this.ready || this.busy || this.needsRepair()) { return; }
    if (this.templateId !== 'original' && this.target === '') { this.error = '请选择出口'; this.emit(); return; }
    const epoch = ++this.epoch;
    this.busy = true;
    this.preview = null;
    this.error = '';
    this.result = '';
    this.emit();
    try {
      this.dependencies = 0;
      const preview = await this.host.preview(this.plan(), pauseDependents);
      if (!this.current(epoch)) { return; }
      this.preview = preview;
    } catch (error) {
      if (this.current(epoch)) {
        const match = /^TEMPLATE_DEPENDENCIES:([1-9][0-9]{0,2})$/.exec((error as Error).message ?? '');
        if (match !== null && Number(match[1]) <= 512) { this.dependencies = Number(match[1]); this.error = ''; }
        else { this.error = '方案未通过校验，请检查出口和订阅资源'; }
      }
    }
    finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }

  async apply(confirmed: boolean = false): Promise<void> {
    if (!this.open || !this.ready || this.busy || this.preview === null || !this.hasChanges() || this.needsRepair()) { return; }
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
      this.inputs.published = plan;
      this.result = result;
      this.preview = null;
    } catch (error) {
      if (this.current(epoch)) {
        this.applyFailure = ProfileApplyFeedback.classify((error as Error)?.message ?? '');
        this.error = this.applyFailure === 'failed' ? '应用失败，请重新预览后重试' : '';
        this.preview = null;
      }
    } finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
}
