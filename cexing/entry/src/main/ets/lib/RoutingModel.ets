import { TemplatePlan, RoutingPlan, RoutingOutlet, RoutingCatalogue, RoutingScope } from './ConfigEditor';
import { TemplateWizardHost, TemplatePreview } from './TemplateWizardModel';
import { ProfileApplyFeedback, ProfileApplyFailureKind } from './ProfileApplyFeedback';

export interface RoutingView {
  needsReenable?: boolean;
  smartUnavailable?: boolean;
  hasLegacy?: boolean;
  plan: TemplatePlan; catalogue?: RoutingCatalogue; busy: boolean; ready: boolean; changed: boolean;
  message: string; preview: string; failure: ProfileApplyFailureKind | ''; dependencies: number;
}
function copyPlan(plan: TemplatePlan): TemplatePlan { return JSON.parse(JSON.stringify(plan)) as TemplatePlan; }
function key(plan: TemplatePlan): string {
  const clean = copyPlan(plan); clean.baseline = undefined; clean.mine = undefined;
  return JSON.stringify(clean);
}
export class RoutingModel {
  private host: TemplateWizardHost;
  private notify: (view: RoutingView) => void;
  private generation: number = 0;
  private open: boolean = true;
  private published: TemplatePlan = { templateId: 'original', version: 1 };
  private plan: TemplatePlan = { templateId: 'original', version: 1 };
  private catalogue?: RoutingCatalogue;
  private savedManaged?: RoutingPlan;
  private receipt: TemplatePreview | null = null;
  private busy: boolean = false;
  private ready: boolean = false;
  private smartUnavailable: boolean = false;
  private hasLegacy: boolean = false;
  private message: string = '';
  private failure: ProfileApplyFailureKind | '' = '';
  private dependencies: number = 0;
  constructor(host: TemplateWizardHost, notify: (view: RoutingView) => void) { this.host = host; this.notify = notify; }
  close(): void { this.open = false; this.generation++; this.host.cancel?.(); }
  private current(epoch: number): boolean { return this.open && this.generation === epoch; }
  blocked(): boolean { return this.failure !== '' && this.failure !== 'failed'; }
  private emit(): void {
    if (this.open) { this.notify({ needsReenable: this.receipt?.inactiveEdits === true, smartUnavailable: this.smartUnavailable, hasLegacy: this.hasLegacy, plan: copyPlan(this.plan), catalogue: this.catalogue, busy: this.busy, ready: this.ready,
      changed: key(this.plan) !== key(this.published), message: this.message, preview: this.receipt?.summary ?? '',
      failure: this.failure, dependencies: this.dependencies }); }
  }
  async load(failure: ProfileApplyFailureKind | '' = ''): Promise<void> {
    if (this.busy || !this.open) { return; }
    this.failure = failure; if (this.blocked()) { this.emit(); return; }
    const epoch = ++this.generation; this.busy = true; this.message = ''; this.receipt = null; this.catalogue = undefined; this.emit();
    try {
      const inputs = await this.host.load(); if (!this.current(epoch)) { return; }
      this.savedManaged = inputs.managedDraft === undefined ? undefined : JSON.parse(JSON.stringify(inputs.managedDraft)) as RoutingPlan;
      this.hasLegacy = inputs.hasLegacy === true; this.plan = copyPlan(inputs.current); this.published = copyPlan(inputs.published ?? inputs.current);
      this.ready = true;
      try { this.catalogue = await this.host.catalogue?.(); }
      catch (_) { if (this.current(epoch)) { this.message = '节点范围暂不可用，请检查订阅来源后重试'; } }
    } catch (_) { if (this.current(epoch)) { this.message = '方案读取失败，请重试'; } }
    finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
  set(plan: TemplatePlan): void {
    if (!this.ready || this.busy || this.blocked()) { return; }
    this.plan = copyPlan(plan); this.receipt = null; this.message = ''; this.dependencies = 0; this.generation++; this.emit();
  }
  subscription(): void { if (this.plan.routing !== undefined) { this.savedManaged = JSON.parse(JSON.stringify(this.plan.routing)) as RoutingPlan; } this.set({ templateId: 'original', version: 1 }); }
  manage(): void { if (this.savedManaged !== undefined) { this.set({ templateId: 'routing', version: 1, routing: this.savedManaged }); } else { this.recommend(); } }
  recommend(): void {
    if (this.catalogue === undefined) { return; }
    const scope: RoutingScope = { regions: [], excludeRegions: [], nodes: [], excludeNodes: [], providers: [], unknown: 'include' };
    const aiScope: RoutingScope = { regions: [], excludeRegions: ['香港'], nodes: [], excludeNodes: [], providers: [], unknown: 'exclude' };
    const plan: RoutingPlan = { version: 1, mode: 'managed', overlayRulesDigest: this.catalogue.overlayRulesDigest,
      defaultOutlet: 'default', assignments: {}, outlets: [
        { id: 'default', algorithm: 'smart', scope: scope }, { id: 'ai', algorithm: 'smart', scope: aiScope }],
      routes: [{ id: 'ai', services: ['category-ai-!cn'], outlet: 'ai' }] };
    this.set({ templateId: 'routing', version: 1, routing: plan });
  }
  updateRouting(routing: RoutingPlan): void { this.set({ templateId: 'routing', version: 1, routing: routing }); }
  /** Accept a Sheet proposal only after common validation and durable preparation. */
  async saveRouting(routing: RoutingPlan): Promise<boolean> {
    if (!this.open || !this.ready || this.busy || this.blocked()) { return false; }
    const epoch = ++this.generation; const candidate: TemplatePlan = { templateId: 'routing', version: 1,
      routing: JSON.parse(JSON.stringify(routing)) as RoutingPlan };
    if (this.catalogue !== undefined && candidate.routing !== undefined) { candidate.routing.overlayRulesDigest = this.catalogue.overlayRulesDigest; }
    this.busy = true; this.message = ''; this.receipt = null; this.emit();
    try {
      const preview = await this.host.preview(candidate);
      if (!this.current(epoch)) { return false; }
      this.plan = candidate; this.receipt = preview; this.dependencies = 0; return true;
    } catch (_) {
      if (this.current(epoch)) { this.message = '方案未通过校验，请检查范围、顺序和订阅资源'; }
      return false;
    } finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
  selectedNodes(outlet: RoutingOutlet, plan: RoutingPlan): string[] {
    const catalog = this.catalogue; if (catalog === undefined) { return []; }
    return Object.keys(catalog.nodes).filter(name => {
      const region = plan.assignments?.[name] ?? catalog.nodes[name]; const scope = outlet.scope;
      if (scope.providers.length > 0 && !scope.providers.some(provider => catalog.providerNodes?.[provider]?.includes(name))) { return false; }
      return !(region === '未知' && scope.unknown === 'exclude') && !scope.excludeRegions.includes(region) &&
        !scope.excludeNodes.includes(name) && (scope.regions.length === 0 || scope.regions.includes(region)) &&
        (scope.nodes.length === 0 || scope.nodes.includes(name));
    }).sort();
  }
  /** Preview is inert and always uses the common revision/digest receipt. */
  async inspect(pauseDependents: boolean = false, smart: boolean = false): Promise<boolean> {
    if (!this.open || !this.ready || this.busy || this.blocked()) { return false; }
    const epoch = ++this.generation; this.busy = true; this.receipt = null; this.message = ''; this.dependencies = 0; this.emit();
    try {
      if (!smart && this.plan.routing !== undefined && this.catalogue !== undefined) {
        // The managed apply confirmation acknowledges the current Merge rules.
        this.plan.routing.overlayRulesDigest = this.catalogue.overlayRulesDigest;
      }
      const receipt = smart ? await this.host.smart?.() : await this.host.preview(this.plan, pauseDependents);
      if (!this.current(epoch) || receipt === undefined) { return false; }
      this.receipt = receipt; return true;
    } catch (error) {
      if (this.current(epoch)) {
        const message = (error as Error).message ?? '';
        const dependency = /^TEMPLATE_DEPENDENCIES:([1-9][0-9]{0,2})$/.exec(message);
        if (dependency !== null) { this.dependencies = Number(dependency[1]); }
        else if (message === 'SMART_NO_COMPATIBLE_GROUP') { this.smartUnavailable = true; this.message = '没有可转换的自动组，可使用策星推荐'; }
        else if (message === 'SMART_EDITS_DISABLED') { this.message = '请先在高级编辑中恢复已停用的个人修改'; }
        else { this.message = '方案未通过校验，请检查范围、顺序和订阅资源'; }
      }
      return false;
    } finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
  async apply(): Promise<void> {
    if (!this.open || this.busy || this.blocked() || this.receipt === null) { return; }
    const epoch = ++this.generation; const receipt = this.receipt; const plan = copyPlan(this.plan);
    this.busy = true; this.emit();
    try {
      const result = await this.host.apply(plan, receipt, true);
      if (!this.current(epoch)) { return; }
      this.published = copyPlan(plan); this.message = result; this.receipt = null;
    } catch (error) {
      if (this.current(epoch)) { this.failure = ProfileApplyFeedback.classify((error as Error).message ?? '');
        this.message = this.failure === 'failed' ? '应用失败，请重新预览后重试' : ''; this.receipt = null; }
    } finally { if (this.current(epoch)) { this.busy = false; this.emit(); } }
  }
}
