import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { RoutingModel, RoutingView } from '../lib/RoutingModel';
import { RoutingOutlet, RoutingPlan, RoutingRoute, RoutingService, EditorDraftHost } from '../lib/ConfigEditor';
import { createTemplateWizardHost } from '../lib/TemplateHost';
import { ProfileApplyFeedback } from '../lib/ProfileApplyFeedback';
import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { RuleDnsEditorBus } from './RuleDnsEditorPage';
import { ProxyMappingForm } from '../lib/ProxyMappingForm';
import { TemplateWizard } from './TemplateWizard';

@Component
export struct RoutingWizard {
  @Consume('nav') navStack: NavPathStack;
  @Prop profileId: string = '';
  editor?: EditorDraftHost;
  registerBackGuard: (guard: (() => boolean) | null) => void = () => {};
  onClose: () => void = () => {};
  @State private view: RoutingView = { plan: { templateId: 'original', version: 1 }, busy: false,
    ready: false, changed: false, message: '', preview: '', failure: '', dependencies: 0 };
  @State private showPreview: boolean = false;
  @State private confirming: boolean = false;
  @State private regionCreation: boolean = false;
  @State private legacy: boolean = false;
  @State private editing: boolean = false;
  @State private editingRoute: string = '';
  @State private services: string[] = [];
  @State private advanced: boolean = false;
  @State private corrections: boolean = false;
  @State private outlet: RoutingOutlet = { id: '', algorithm: 'smart', scope: { regions: [], excludeRegions: [], nodes: [], excludeNodes: [], providers: [], unknown: 'include' } };
  @State private assignments: Record<string, string> = {};
  @State private formError: string = '';
  @State private rawOptions: boolean = false;
  @State private rawText: string = '';
  private options: ProxyMappingForm = new ProxyMappingForm('proxy-groups');
  private model: RoutingModel | null = null;
  private visible: boolean = false;
  private generation: number = 0;
  private legacyGuard: (() => boolean) | null = null;
  private t(name: string): string { return (getContext(this) as common.UIAbilityContext).resourceManager.getStringByNameSync(name); }
  aboutToAppear(): void {
    this.visible = true;
    this.registerBackGuard(() => {
      if (this.legacy || this.regionCreation) { if (this.legacyGuard?.()) { return true; } this.legacy = false; this.regionCreation = false; this.load(); return true; }
      return this.view.busy || this.confirming || this.editing || this.model?.blocked() === true;
    });
    this.model = new RoutingModel(createTemplateWizardHost(getContext(this) as common.UIAbilityContext, this.profileId, this.editor), (view: RoutingView) => { this.view = view; });
    this.load();
  }
  aboutToDisappear(): void { this.visible = false; this.generation++; this.model?.close(); this.registerBackGuard(null); }
  private load(): void { this.model?.load(ProfileApplyFeedback.recovery(getContext(this) as common.UIAbilityContext)); }
  private displayMessage(message: string): string {
    const keys: Record<string, string> = {};
    keys['节点范围暂不可用，请检查订阅来源后重试'] = 'routing_scope_unavailable';
    keys['方案读取失败，请重试'] = 'template_read_failed';
    keys['没有可转换的自动组，可使用策星推荐'] = 'routing_no_smart';
    keys['请先在高级编辑中恢复已停用的个人修改'] = 'routing_restore_edits';
    keys['方案未通过校验，请检查范围、顺序和订阅资源'] = 'routing_validation_failed';
    keys['应用失败，请重新预览后重试'] = 'template_apply_failed';
    keys['方案已应用'] = 'template_applied'; keys['已保存，启用后生效'] = 'template_saved';
    return this.t(keys[message] ?? 'template_result_unknown');
  }
  private regionLabel(name: string): string { return name === '未知' ? this.t('routing_unknown') : name; }
  private managed(): boolean { return this.view.plan.routing?.mode === 'managed' || ['ai', 'automatic'].includes(this.view.plan.templateId); }
  private working(): boolean { return this.view.busy || this.confirming || this.model?.blocked() === true; }
  private routing(): RoutingPlan | undefined { return this.view.plan.routing === undefined ? undefined : JSON.parse(JSON.stringify(this.view.plan.routing)) as RoutingPlan; }
  private outletLabel(id: string): string {
    if (id === this.view.plan.routing?.defaultOutlet) { return this.t('routing_default_exit'); }
    const routes = this.view.plan.routing?.routes.filter(route => route.outlet === id) ?? [];
    return routes.length > 0 ? routes.map(route => this.routeLabel(route)).join(' / ') : this.scopeLabel(this.outletByID(id));
  }
  private outletByID(id: string): RoutingOutlet | undefined { return this.view.plan.routing?.outlets.find(value => value.id === id); }
  private algorithmLabel(id: string): string { return id === 'smart' ? 'Smart' : this.t(id === 'url-test' ? 'routing_urltest' : id === 'fallback' ? 'routing_fallback' : 'routing_select'); }
  private scopeLabel(outlet?: RoutingOutlet): string {
    if (outlet === undefined) { return ''; }
    const scope = outlet.scope;
    let text = scope.regions.length > 0 ? scope.regions.join('、') : scope.excludeRegions.length > 0 ? scope.excludeRegions.length === 1 && scope.excludeRegions[0] === '香港' ? this.t('routing_except_hk') : `${this.t('routing_except')} ${scope.excludeRegions.join('、')}` : this.t('routing_all_nodes');
    if (scope.nodes.length > 0) { text += ` · ${scope.nodes.length} ${this.t('routing_nodes')}`; }
    return `${text} · ${this.algorithmLabel(outlet.algorithm)}`;
  }
  private routeLabel(route: RoutingRoute): string {
    return route.services.map(id => this.view.catalogue?.services.find(service => service.id === id)?.name ?? id).join(' / ');
  }
  private async apply(smart: boolean = false, pause: boolean = false): Promise<void> {
    const model = this.model; if (model === null || this.working()) { return; }
    const epoch = ++this.generation; this.confirming = true;
    try {
      if (!await model.inspect(pause, smart) || !this.visible || this.generation !== epoch) { return; }
      if (this.managed() && !smart) {
        const answer = await promptAction.showDialog({ title: this.t('routing_apply_title'), message: this.t(this.view.needsReenable ? 'template_replace_reenable' : 'routing_replace_confirmation'), buttons: [
          { text: this.t('template_cancel'), color: $r('app.color.ui_muted') }, { text: this.t('template_apply'), color: $r('app.color.ui_accent_text') }] });
        if (!this.visible || this.generation !== epoch || answer.index !== 1) { return; }
      }
      await model.apply();
    } finally { if (this.visible && this.generation === epoch) { this.confirming = false; } }
  }
  private addService(id: string): void {
    const plan = this.routing(); if (plan === undefined || plan.routes.some(route => route.services.includes(id))) { return; }
    let index = 1; while (plan.routes.some(route => route.id === `service-${index}`)) { index++; }
    const ai = plan.routes.find(route => route.services.includes('category-ai-!cn'));
    const isAI = !['netflix', 'disney', 'spotify'].includes(id);
    plan.routes.push({ id: `service-${index}`, services: [id], outlet: isAI && ai !== undefined ? ai.outlet : plan.defaultOutlet ?? '' });
    this.model?.updateRouting(plan);
  }
  private removeRoute(id: string): void { const plan = this.routing(); if (plan === undefined) { return; } plan.routes = plan.routes.filter(route => route.id !== id); this.model?.updateRouting(plan); }
  private independent(routeID: string): void {
    if (routeID === '') { return; }
    const plan = this.routing(); if (plan === undefined) { return; }
    let index = 1; while (plan.outlets.some(item => item.id === `exit-${index}`)) { index++; }
    const next = JSON.parse(JSON.stringify(this.outlet)) as RoutingOutlet; next.id = `exit-${index}`; this.outlet = next;
  }
  private editOutlet(id: string): void {
    const outlet = this.outletByID(id); if (outlet === undefined || this.working()) { return; }
    this.editingRoute = ''; this.services = [];
    this.outlet = JSON.parse(JSON.stringify(outlet)) as RoutingOutlet;
    this.assignments = JSON.parse(JSON.stringify(this.view.plan.routing?.assignments ?? {})) as Record<string, string>;
    this.options = new ProxyMappingForm('proxy-groups');
    const defaults: Record<string, Object> = {}; defaults['url'] = 'https://www.gstatic.com/generate_204'; defaults['interval'] = 300; defaults['timeout'] = 5000; defaults['lazy'] = true; defaults['expected-status'] = '204'; defaults['max-failed-times'] = 5;
    if (outlet.algorithm === 'smart') { defaults['uselightgbm'] = true; defaults['collectdata'] = false; defaults['prefer-asn'] = false; }
    const saved: Record<string, Object> = JSON.parse(JSON.stringify(outlet.options ?? {})) as Record<string, Object>;
    const value: Record<string, Object> = defaults;
    for (const key of Object.keys(saved)) { value[key] = saved[key]; }
    value['name'] = outlet.id; value['type'] = outlet.algorithm; value['proxies'] = ['REJECT'];
    this.options.replaceAdvanced(JSON.stringify(value)); this.advanced = false; this.corrections = false; this.rawOptions = false; this.formError = ''; this.editing = true;
  }
  private editRoute(route: RoutingRoute): void { this.editOutlet(route.outlet); this.editingRoute = route.id; this.services = route.services.slice(); }
  private changeScope(key: string, value: string, included: boolean): void {
    const next = JSON.parse(JSON.stringify(this.outlet)) as RoutingOutlet;
    let values: string[] = [];
    if (key === 'regions') { values = next.scope.regions; }
    else if (key === 'excludeRegions') { values = next.scope.excludeRegions; }
    else if (key === 'nodes') { values = next.scope.nodes; }
    else if (key === 'excludeNodes') { values = next.scope.excludeNodes; }
    else { values = next.scope.providers; }
    const changed = included ? values.concat(values.includes(value) ? [] : [value]) : values.filter(item => item !== value);
    if (key === 'regions') { next.scope.regions = changed; }
    else if (key === 'excludeRegions') { next.scope.excludeRegions = changed; }
    else if (key === 'nodes') { next.scope.nodes = changed; }
    else if (key === 'excludeNodes') { next.scope.excludeNodes = changed; }
    else { next.scope.providers = changed; }
    this.outlet = next; this.refreshOrder();
  }
  private unknownCount(): number { return this.nodeNames().filter(name => (this.assignments[name] ?? this.view.catalogue?.nodes[name]) === '未知').length; }
  private nodeNames(): string[] { const empty: Record<string, string> = {}; return Object.keys(this.view.catalogue?.nodes ?? empty); }
  private candidates(): string[] {
    const plan = this.routing(); if (plan === undefined) { return []; } plan.assignments = this.assignments;
    return this.model?.selectedNodes(this.outlet, plan) ?? [];
  }
  private refreshOrder(): void {
    if (this.outlet.algorithm !== 'fallback') { return; }
    const candidates = this.candidates(); const previous = this.outlet.order ?? [];
    this.outlet = { id: this.outlet.id, algorithm: this.outlet.algorithm, scope: this.outlet.scope, options: this.outlet.options,
      order: previous.filter(name => candidates.includes(name)).concat(candidates.filter(name => !previous.includes(name))) };
  }
  private move(index: number, delta: number): void {
    const next = JSON.parse(JSON.stringify(this.outlet)) as RoutingOutlet; const values = next.order ?? [];
    const target = index + delta; if (target < 0 || target >= values.length) { return; }
    const temp = values[index]; values[index] = values[target]; values[target] = temp; next.order = values; this.outlet = next;
  }
  private async saveOutlet(): Promise<void> {
    const plan = this.routing(); if (plan === undefined) { return; }
    try {
      if (this.rawOptions) { this.options.replaceAdvanced(this.rawText); }
      this.options.setText('name', this.outlet.id); this.options.setText('type', this.outlet.algorithm); this.options.setList('proxies', ['REJECT']);
      const values = this.options.finish().value; const options: Record<string, Object> = {};
      for (const key of Object.keys(values)) { if (['name', 'type', 'proxies'].includes(key)) { continue; }
        if (this.outlet.algorithm !== 'smart' && ['policy-priority', 'uselightgbm', 'collectdata', 'sample-rate', 'prefer-asn'].includes(key)) { continue; } options[key] = values[key]; }
      this.outlet.options = options;
      if (this.outlet.algorithm !== 'fallback') { this.outlet.order = undefined; }
      plan.assignments = this.assignments;
      if (this.editingRoute !== '') { if (this.services.length === 0) { throw new Error('empty'); } plan.routes.forEach(route => { if (route.id === this.editingRoute) { route.services = this.services.slice(); route.outlet = this.outlet.id; } }); }
      if (plan.outlets.some(item => item.id === this.outlet.id)) { plan.outlets = plan.outlets.map(item => item.id === this.outlet.id ? this.outlet : item); } else { plan.outlets.push(this.outlet); }
      this.model?.updateRouting(plan);
      if (await this.model?.inspect()) { this.editing = false; promptAction.showToast({ message: this.t('routing_draft_saved'), duration: 1800 }); } else { this.formError = this.t('routing_invalid_options'); }
    } catch (_) { this.formError = this.t('routing_invalid_options'); }
  }
  private advancedRules(): void { RuleDnsEditorBus.file = this.profileId; RuleDnsEditorBus.section = 'rules'; this.navStack.pushPath({ name: 'ruleDnsEditor' }); }
  private async repair(): Promise<void> {
    if (this.confirming) { return; }
    if (this.view.failure === 'selection-required') { this.navStack.pushPath({ name: 'zashboard' }); return; }
    const epoch = ++this.generation; this.confirming = true;
    try { const accepted = await ProfileApplyRecovery.reconnect(getContext(this) as common.UIAbilityContext, () => this.visible && epoch === this.generation);
      if (accepted && this.visible && epoch === this.generation) { this.navStack.clear(); }
    } finally { if (this.visible && epoch === this.generation) { this.confirming = false; } }
  }

  @Builder
  Field(label: string, key: string, numeric: boolean = false) {
    Text(label).fontSize(13).fontColor(UI.muted).width('100%')
    TextInput({ text: this.options.text(key), placeholder: label }).constraintSize({ minHeight: 48 }).accessibilityText(label)
      .onChange((value: string) => { if (numeric) { this.options.setNumber(key, value); } else if (key === 'sample-rate') { this.options.setFraction(key, value); } else { this.options.setText(key, value); } })
  }
  @Builder
  Flag(label: string, key: string) {
    Row() { Text(label).fontSize(14).fontColor(UI.ink).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.options.flagOrDefault(key, key === 'uselightgbm' || key === 'lazy') }).accessibilityText(label).onChange((value: boolean) => this.options.setFlag(key, value))
    }.width('100%').constraintSize({ minHeight: 48 })
  }
  @Builder
  ScopeList(label: string, key: string, values: string[], selected: string[]) {
    Text(label).fontSize(14).fontColor(UI.muted).width('100%')
    ForEach(selected, (name: string) => {
      Button(`${name} ×`).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.changeScope(key, name, false))
    }, (name: string) => name)
    Select(values.filter(name => !selected.includes(name)).map((name: string): SelectOption => ({ value: name })))
      .value(this.t('routing_add')).accessibilityText(label).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
      .onSelect((_, name: string) => this.changeScope(key, name, true))
  }
  @Builder
  OutletEditor() {
    Column({ space: 12 }) {
      Scroll() { Column({ space: 12 }) {
        Text(this.t('routing_exit')).fontSize(22).fontColor(UI.ink).width('100%')
        if (this.editingRoute !== '') {
          ForEach((this.view.catalogue?.services ?? []).filter(service => !this.view.plan.routing?.routes.some(route => route.id !== this.editingRoute && route.services.includes(service.id))), (service: RoutingService) => {
            Row() { Text(service.name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
              Checkbox({ name: service.id }).select(this.services.includes(service.id)).accessibilityText(service.name)
                .onChange((checked: boolean) => { this.services = checked ? this.services.concat([service.id]) : this.services.filter(id => id !== service.id); })
            }.width('100%').constraintSize({ minHeight: 44 })
          }, (service: RoutingService) => service.id)
          Select((this.view.plan.routing?.outlets ?? []).map((outlet: RoutingOutlet): SelectOption => ({ value: this.outletLabel(outlet.id) })))
            .value(this.outletLabel(this.outlet.id)).constraintSize({ minHeight: 48 }).accessibilityText(this.t('routing_share_exit'))
            .onSelect((index: number) => { const value = this.view.plan.routing?.outlets[index]?.id; if (value === undefined) { return; } const routeID = this.editingRoute; const services = this.services.slice(); this.editOutlet(value); this.editingRoute = routeID; this.services = services; })
          Button(this.t('routing_separate')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.independent(this.editingRoute); })
          Button(this.t('proxy_form_remove')).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent).fontColor(UI.error).onClick(() => { this.removeRoute(this.editingRoute); this.editing = false; })
        }
        Text(this.t('routing_shared_hint')).fontSize(12).fontColor(UI.muted)
        Select(['smart', 'url-test', 'fallback', 'select'].map((value: string): SelectOption => ({ value: this.algorithmLabel(value) })))
          .value(this.algorithmLabel(this.outlet.algorithm)).accessibilityText(this.t('routing_algorithm')).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
          .onSelect((index: number) => { const next = JSON.parse(JSON.stringify(this.outlet)) as RoutingOutlet; next.algorithm = ['smart', 'url-test', 'fallback', 'select'][index]; this.outlet = next; this.refreshOrder(); })
        this.ScopeList(this.t('routing_countries'), 'regions', this.view.catalogue?.regions.filter(name => name !== '未知') ?? [], this.outlet.scope.regions)
        this.ScopeList(this.t('routing_exclude_countries'), 'excludeRegions', this.view.catalogue?.regions.filter(name => name !== '未知') ?? [], this.outlet.scope.excludeRegions)
        Row() {
          Text(`${this.t('routing_unknown')} (${this.unknownCount()})`).fontSize(14).fontColor(UI.ink).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.outlet.scope.unknown === 'include' }).accessibilityText(this.t('routing_unknown'))
            .onChange((value: boolean) => { const next = JSON.parse(JSON.stringify(this.outlet)) as RoutingOutlet; next.scope.unknown = value ? 'include' : 'exclude'; this.outlet = next; this.refreshOrder(); })
        }.constraintSize({ minHeight: 48 }).width('100%')
        Text(this.t('routing_region_hint')).fontSize(12).fontColor(UI.muted)
        if (this.outlet.algorithm === 'fallback') {
          Text(this.t('routing_order')).fontSize(14).fontColor(UI.muted).width('100%')
          ForEach(this.outlet.order ?? [], (name: string, index: number) => {
            Row({ space: 8 }) { Text(name).fontSize(14).fontColor(UI.ink).layoutWeight(1)
              Button('↑').constraintSize({ minHeight: 44, minWidth: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(index > 0).accessibilityText(`${this.t('proxy_form_move_up')} ${name}`).onClick(() => this.move(index, -1))
              Button('↓').constraintSize({ minHeight: 44, minWidth: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(index < (this.outlet.order?.length ?? 0) - 1).accessibilityText(`${this.t('proxy_form_move_down')} ${name}`).onClick(() => this.move(index, 1))
            }.width('100%')
          }, (name: string) => name)
        }
        Button(this.t('routing_advanced')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.advanced = !this.advanced; })
        if (this.advanced) {
          this.ScopeList(this.t('routing_node_scope'), 'nodes', this.nodeNames(), this.outlet.scope.nodes)
          this.ScopeList(this.t('routing_exclude_nodes'), 'excludeNodes', this.nodeNames(), this.outlet.scope.excludeNodes)
          this.ScopeList(this.t('routing_provider_scope'), 'providers', this.view.catalogue?.providers ?? [], this.outlet.scope.providers)
          Button(this.t('routing_correct_regions')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.corrections = !this.corrections; })
          if (this.corrections) {
            ForEach(this.nodeNames(), (name: string) => {
              Text(name).fontSize(13).fontColor(UI.ink).width('100%')
              Select((this.view.catalogue?.regions ?? []).map((region: string): SelectOption => ({ value: region === '未知' ? this.t('routing_unknown') : region })))
                .value(this.regionLabel(this.assignments[name] ?? this.view.catalogue?.nodes[name] ?? '未知')).constraintSize({ minHeight: 48 }).accessibilityText(name)
                .onSelect((index: number) => { const next = JSON.parse(JSON.stringify(this.assignments)) as Record<string, string>; next[name] = this.view.catalogue?.regions[index] ?? '未知'; this.assignments = next; this.refreshOrder(); })
            }, (name: string) => name)
          }
          if (this.outlet.algorithm !== 'select') {
            this.Field(this.t('proxy_form_check_url'), 'url')
            this.Field(this.t('proxy_form_check_interval'), 'interval', true)
            this.Field(this.t('proxy_form_timeout'), 'timeout', true)
            this.Field(this.t('routing_expected_status'), 'expected-status')
            this.Field(this.t('routing_max_failed'), 'max-failed-times', true)
            this.Flag(this.t('routing_lazy'), 'lazy')
          }
          if (this.outlet.algorithm === 'smart' || this.outlet.algorithm === 'url-test') { this.Field(this.t('routing_tolerance'), 'tolerance', true) }
          if (this.outlet.algorithm === 'smart') {
            this.Field(this.t('routing_policy_priority'), 'policy-priority')
            this.Flag(this.t('routing_lightgbm'), 'uselightgbm')
            this.Flag(this.t('routing_prefer_asn'), 'prefer-asn')
            this.Flag(this.t('routing_collectdata'), 'collectdata')
            this.Field(this.t('routing_sample_rate'), 'sample-rate')
          }
          Button(this.t('routing_raw_options')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.rawText = this.options.advancedText(); this.rawOptions = !this.rawOptions; })
          if (this.rawOptions) { TextArea({ text: this.rawText }).constraintSize({ minHeight: 240 }).accessibilityText(this.t('routing_raw_options')).onChange((value: string) => { this.rawText = value; }) }
        }
        if (this.formError !== '') { Text(this.formError).fontSize(14).fontColor(UI.error) }
      }.width('100%') }.width('100%').layoutWeight(1)
      Button(this.t('editor_save_draft')).constraintSize({ minHeight: 48 }).width('100%').backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.saveOutlet())
    }.padding(20).width('100%').height('100%').backgroundColor(UI.surface).enabled(!this.view.busy && !this.confirming)
  }

  build() {
    if (this.legacy || this.regionCreation) {
      TemplateWizard({ regionOnly: this.regionCreation, profileId: this.profileId, editor: this.editor, registerBackGuard: (guard: (() => boolean) | null) => { this.legacyGuard = guard; }, onClose: () => { this.legacy = false; this.regionCreation = false; this.load(); } })
    } else {
      Column({ space: 12 }) {
        Scroll() { Column({ space: 12 }) {
          Row({ space: 8 }) {
            Button(this.t('template_original')).layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(!this.managed() ? UI.action : UI.soft).fontColor(!this.managed() ? UI.onAccent : UI.ink)
              .accessibilitySelected(!this.managed()).enabled(this.view.ready && !this.working()).onClick(() => { if (this.managed()) { this.model?.subscription(); } })
            Button(this.t('routing_managed')).layoutWeight(1).constraintSize({ minHeight: 48 }).backgroundColor(this.managed() ? UI.action : UI.soft).fontColor(this.managed() ? UI.onAccent : UI.ink)
              .accessibilitySelected(this.managed()).enabled(this.view.ready && !this.working() && this.view.catalogue !== undefined).onClick(() => { if (!this.managed()) { this.model?.manage(); } })
          }.width('100%')
          if (this.view.plan.routing !== undefined) {
            Text(this.t('routing_default_exit')).fontSize(15).fontColor(UI.muted).width('100%')
            Button(this.scopeLabel(this.outletByID(this.view.plan.routing.defaultOutlet ?? ''))).constraintSize({ minHeight: 56 }).width('100%').backgroundColor(UI.paper).fontColor(UI.ink)
              .enabled(!this.working()).onClick(() => this.editOutlet(this.view.plan.routing?.defaultOutlet ?? ''))
            Text(this.t('routing_services')).fontSize(15).fontColor(UI.muted).width('100%')
            ForEach(this.view.plan.routing.routes, (route: RoutingRoute) => {
              Column({ space: 8 }) {
                Button({ type: ButtonType.Normal }) {
                  Column({ space: 4 }) {
                    Text(this.routeLabel(route)).fontSize(16).fontColor(UI.ink).maxLines(2).width('100%')
                    Text(this.scopeLabel(this.outletByID(route.outlet))).fontSize(13).fontColor(UI.muted).maxLines(2).width('100%')
                  }.width('100%').padding(16)
                }.constraintSize({ minHeight: 64 }).width('100%').backgroundColor(UI.paper).fontColor(UI.ink).enabled(!this.working()).onClick(() => this.editRoute(route))

              }.width('100%')
            }, (route: RoutingRoute) => route.id)
            Select((this.view.catalogue?.services ?? []).filter(service => !this.view.plan.routing?.routes.some(route => route.services.includes(service.id))).map((service: RoutingService): SelectOption => ({ value: service.name })))
              .value(this.t('routing_add_service')).constraintSize({ minHeight: 48 }).accessibilityText(this.t('routing_add_service')).width('100%').enabled(!this.working())
              .onSelect((_, name: string) => { const service = this.view.catalogue?.services.find(item => item.name === name); if (service !== undefined) { this.addService(service.id); } })
            Button(this.t('routing_custom_rules')).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.working() && !this.view.changed).onClick(() => this.advancedRules())
          } else {
            Button(this.t('routing_one_click_smart')).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(this.view.ready && !this.working() && !this.view.changed).onClick(() => this.apply(true))
            if (this.view.smartUnavailable) { Button(this.t('routing_create_smart')).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.working()).onClick(() => { this.regionCreation = true; }) }
            Button(this.t('routing_recommended')).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(this.view.ready && !this.working() && this.view.catalogue !== undefined).onClick(() => this.model?.recommend())
            if (this.view.plan.templateId !== 'original') {
              Text(this.t('routing_legacy_preserved')).fontSize(13).fontColor(UI.muted)

            }
          }
          if (this.view.hasLegacy && this.view.plan.routing === undefined) { Button(this.t('routing_legacy_edit')).constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent).fontColor(UI.accentText).enabled(!this.working()).onClick(() => { this.legacy = true; }) }
          if (this.view.dependencies > 0) { Text(this.t('routing_dependencies')).fontSize(14).fontColor(UI.muted)
            Button(this.t('template_pause_dependents')).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.working()).onClick(() => this.apply(false, true)) }
          if (this.view.message !== '') { Text(this.displayMessage(this.view.message)).fontSize(14).fontColor(UI.muted) }
          if (this.showPreview && this.view.preview !== '') { Text(this.view.preview).fontSize(13).fontColor(UI.muted) }
          if (this.view.failure !== '' && this.view.failure !== 'failed') { Text(this.t(ProfileApplyFeedback.key(this.view.failure))).fontSize(14).fontColor(UI.error)
            Button(this.t('apply_feedback_reconnect')).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.confirming).onClick(() => this.repair()) }
        }.width('100%') }.width('100%').layoutWeight(1)
        if (!this.view.ready || this.view.catalogue === undefined) { Button(this.t('template_retry')).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.working()).onClick(() => this.load()) }
        Button(this.t('template_view_changes')).width('100%').constraintSize({ minHeight: 44 }).backgroundColor(Color.Transparent).fontColor(UI.accentText).enabled(this.view.changed && !this.working()).onClick(() => { this.showPreview = true; this.model?.inspect(); })
        Button(this.t('template_apply')).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.view.changed && !this.working()).onClick(() => this.apply())
      }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
        .bindSheet($$this.editing, this.OutletEditor(), { height: SheetSize.LARGE, shouldDismiss: (dismiss: SheetDismiss) => { if (!this.view.busy && !this.confirming) { dismiss.dismiss(); } } })
    }
  }
}
