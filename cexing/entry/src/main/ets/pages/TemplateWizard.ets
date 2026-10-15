import { RegionPlan, RegionPreview } from '../lib/EffectiveVersions';
import { UiText } from '../lib/UiText';
import { ProfileApplyFeedback } from '../lib/ProfileApplyFeedback';
import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { ProfileImportInput } from '../lib/ProfileImportInput';
import { createTemplateUpdateSource } from '../lib/TemplateUpdateSource';
import { TemplateUpdateReview } from './TemplateUpdateReview';
import { TemplateUpdateSource } from '../lib/TemplateUpdateHost';
import { EditorDraftHosts } from '../lib/EditorDraftHosts';
import { AiProbeStatus } from './AiProbeStatus';
import { AiProbeBinding } from '../lib/AiProbeBinding';
import { common } from '@kit.AbilityKit';
import { EditorDraftHost } from '../lib/ConfigEditor';
import { createTemplateWizardHost } from '../lib/TemplateHost';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { TemplateWizardHost, TemplateWizardModel, TemplateWizardView } from '../lib/TemplateWizardModel';

// ProfilePage's single owner supplies the transaction adapter and entry point.
@Component
export struct TemplateWizard {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @State private recovering: boolean = false;
  @State private recoveryMessage: string = '';
  private recoveryGeneration: number = 0;
  host?: TemplateWizardHost;
  editor?: EditorDraftHost;
  updateSource?: TemplateUpdateSource;
  private activeUpdateSource?: TemplateUpdateSource;
  private activeEditor?: EditorDraftHost;
  @State private reviewingUpdate: boolean = false;
  @State private updateAvailable: boolean = false;
  @Prop profileId: string = '';
  @Prop regionOnly: boolean = false;
  private regionInitialised: boolean = false;
  onClose: () => void = () => {};
  registerBackGuard: (guard: (() => boolean) | null) => void = () => {};
  private reviewBackGuard: (() => boolean) | null = null;
  @State private showRegionAdvanced: boolean = false;
  @State private regionMode: string = 'region';
  @State private regionAssignments: Record<string, string> = {};
  @State private regionPreview: RegionPreview | null = null;
  @State private regionBusy: boolean = false;
  @State private regionError: string = '';
  private regionGeneration: number = 0;
  @State private view: TemplateWizardView = { templateId: 'original', target: '', busy: false,
    ready: false, error: '', result: '', summary: '', hasPreview: false, groups: [], selectors: [] };
  @State private confirming: boolean = false;
  @State private showChanges: boolean = false;
  private confirmationGeneration: number = 0;
  @State private aiRevision: string = '';
  private aiBinding: AiProbeBinding = new AiProbeBinding();
  private model: TemplateWizardModel | null = null;
  private visible: boolean = false;

  aboutToAppear(): void {
    this.registerBackGuard(() => {
      if (this.reviewingUpdate) {
        if (this.reviewBackGuard?.() === true) { return true; }
        this.reviewingUpdate = false; this.load(); return true;
      }
      return this.view.busy || this.confirming || this.recovering || this.regionBusy;
    });
    this.regionGeneration++; this.regionBusy = false; this.showRegionAdvanced = false;
    this.recoveryGeneration++; this.recovering = false; this.recoveryMessage = '';
    this.regionInitialised = false;
    this.visible = true; this.confirmationGeneration++; this.confirming = false;
    this.reviewingUpdate = false;
    this.activeUpdateSource = this.updateSource ?? (this.profileId.length > 0 ?
      createTemplateUpdateSource(getContext(this) as common.UIAbilityContext, this.profileId) : undefined);
    this.activeEditor = this.editor ?? (this.profileId.length > 0 ?
      EditorDraftHosts.create(getContext(this) as common.UIAbilityContext, this.profileId) : undefined);
    const host = this.host ?? (this.profileId.length > 0 ?
      createTemplateWizardHost(getContext(this) as common.UIAbilityContext, this.profileId, this.activeEditor) : undefined);
    if (host === undefined) { return; }
    this.model = new TemplateWizardModel(host, () => {
      if (this.model !== null) {
        this.view = this.model.snapshot();
        if (this.regionOnly && this.view.ready && !this.regionInitialised) { this.regionInitialised = true; this.model.choose('region', ''); }
        this.aiRevision = this.view.ready && !this.view.busy && !this.model.needsRepair() && this.view.templateId === 'ai' ?
          this.aiBinding.revision(getContext(this) as common.UIAbilityContext, this.profileId, this.view.target) : '';
        this.updateAvailable = this.view.ready && !this.view.busy && !this.model.needsRepair() &&
          (this.activeUpdateSource?.available?.(this.view.templateId, this.view.target) ?? this.updateSource !== undefined);
      }
    });
    this.load();
  }
  aboutToDisappear(): void { this.regionGeneration++; this.registerBackGuard(null); this.visible = false; this.recoveryGeneration++; this.confirmationGeneration++; this.confirming = false; this.model?.close(); }
  private close(): void { this.visible = false; this.recoveryGeneration++; this.confirmationGeneration++; this.confirming = false; this.model?.close(); this.onClose(); }
  private load(): void {
    this.model?.setApplyFailure(ProfileApplyFeedback.recovery(getContext(this) as common.UIAbilityContext));
    this.model?.load();
  }
  private needsRecovery(): boolean {
    return this.view.applyFailure === 'unconfirmed' || this.view.applyFailure === 'committed-pending';
  }
  private async recoverApply(): Promise<void> {
    const model = this.model; const file = this.profileId;
    if (!this.visible || this.recovering || model === null || model.busy || !this.needsRecovery()) { return; }
    const epoch = ++this.recoveryGeneration;
    const current = (): boolean => this.visible && !this.reviewingUpdate && epoch === this.recoveryGeneration &&
      model === this.model && file === this.profileId;
    this.recovering = true; this.recoveryMessage = '';
    try {
      const accepted = await ProfileApplyRecovery.reconnect(getContext(this) as common.UIAbilityContext, current);
      if (!current() || accepted === null) { return; }
      if (accepted) {
        // Startup acceptance does not clear the persistent unknown fence. The
        // connection view owns subsequent runtime confirmation and feedback.
        promptAction.showToast({ message: UiText.get($r('app.string.apply_feedback_starting')), duration: 1800 });
        if (!ProfileImportInput.hasPending()) { this.tabJump = 0; }
        this.navStack.clear();
      } else { this.recoveryMessage = UiText.get($r('app.string.apply_feedback_recovery_failed')); }
    } catch (_) { if (current()) { this.recoveryMessage = UiText.get($r('app.string.apply_feedback_recovery_failed')); } }
    finally { if (current()) { this.recovering = false; } }
  }
  private repairSelection(): void {
    if (this.visible && !this.recovering && this.view.applyFailure === 'selection-required') {
      this.navStack.pushPath({ name: 'zashboard' });
    }
  }
  private failureMessage(): string {
    const kind = this.view.applyFailure;
    return kind !== undefined && kind !== '' ? (getContext(this) as common.UIAbilityContext)
      .resourceManager.getStringByNameSync(ProfileApplyFeedback.key(kind)) : '';
  }
  private async apply(): Promise<void> {
    const model = this.model;
    if (model === null || model.busy || this.confirming || !model.hasChanges()) { return; }
    const generation = this.confirmationGeneration;
    this.confirming = true;
    if (this.regionOnly && model.templateId === 'region') {
      try {
        const choice = await promptAction.showDialog({ title: UiText.get($r('app.string.profile_region_create')),
          message: UiText.get($r('app.string.routing_region_create_confirmation')),
          buttons: [{ text: UiText.get($r('app.string.template_cancel')), color: $r('app.color.ui_muted') },
            { text: UiText.get($r('app.string.profile_create_only')), color: $r('app.color.ui_accent_text') },
            { text: UiText.get($r('app.string.profile_create_enable')), color: $r('app.color.ui_accent_text') }] });
        if (!this.visible || generation !== this.confirmationGeneration || choice.index === 0) { return; }
        model.regionActivation(choice.index === 2);
      } catch (_) { return; }
      finally { if (generation === this.confirmationGeneration) { this.confirming = false; } }
      this.confirming = true;
    }
    if (model.preview === null) { await model.inspect(); }
    if (!this.visible || generation !== this.confirmationGeneration || this.model !== model) { return; }
    this.confirming = false;
    if (model.preview === null || model.needsRepair()) { return; }
    if (model.templateId === 'automatic' || model.preview.inactiveEdits === true) {
      const preview = model.preview;
      const automatic = model.templateId === 'automatic';
      const message = preview.inactiveEdits === true ? (automatic ?
        UiText.get($r('app.string.template_replace_reenable')) : UiText.get($r('app.string.template_reenable'))) :
        UiText.get($r('app.string.template_auto_scope'));
      const confirmation = ++this.confirmationGeneration;
      this.confirming = true;
      try {
        const answer = await promptAction.showDialog({ title: automatic ? UiText.get($r('app.string.template_replace_title')) : UiText.get($r('app.string.template_apply_title')),
          message: message,
          buttons: [{ text: UiText.get($r('app.string.template_cancel')), color: $r('app.color.ui_muted') }, { text: automatic ? UiText.get($r('app.string.template_replace_apply')) : UiText.get($r('app.string.template_apply')), color: $r('app.color.ui_accent_text') }] });
        if (!this.visible || answer.index !== 1 || this.model !== model || model.preview !== preview) { return; }
      } catch (_) { return; }
      finally { if (confirmation === this.confirmationGeneration) { this.confirming = false; } }
    }
    await model.apply(true);
  }
  private openRegionAdvanced(): void {
    if (this.regionBusy || this.view.busy || this.view.templateId !== 'region' || this.view.target === '' ||
      this.model === null || this.model.needsRepair()) { return; }
    const plan = this.model.regionPlan();
    this.regionMode = plan.mode; this.regionAssignments = plan.assignments;
    this.regionPreview = null; this.regionError = ''; this.showRegionAdvanced = true;
    this.refreshRegionPreview();
  }

  private async refreshRegionPreview(): Promise<void> {
    const model = this.model;
    if (model === null || this.regionBusy || !this.showRegionAdvanced) { return; }
    const generation = ++this.regionGeneration; this.regionBusy = true; this.regionError = '';
    const plan: RegionPlan = { mode: this.regionMode, selector: this.view.target,
      enable: false, assignments: this.regionAssignments };
    try {
      const preview = await model.previewRegion(plan);
      if (this.visible && this.showRegionAdvanced && generation === this.regionGeneration && this.model === model) {
        this.regionPreview = preview;
      }
    } catch (_) {
      if (this.visible && generation === this.regionGeneration) { this.regionError = UiText.get($r('app.string.profile_preview_failed')); }
    } finally { if (this.visible && generation === this.regionGeneration) { this.regionBusy = false; } }
  }

  private regionCanSave(): boolean {
    return !this.regionBusy && !this.view.busy && this.regionError === '' && this.regionPreview?.eligible === true &&
      (this.regionMode !== 'all' || Object.keys(this.regionPreview.nodes).length >= 2);
  }

  private async saveRegionDraft(): Promise<void> {
    const model = this.model;
    if (model === null || !this.regionCanSave()) { return; }
    const generation = ++this.regionGeneration; this.regionBusy = true;
    model.configureRegion(this.regionMode, this.regionAssignments);
    try {
      await model.inspect();
      if (!this.visible || generation !== this.regionGeneration || model !== this.model) { return; }
      if (model.preview !== null) { this.showRegionAdvanced = false; }
      else { this.regionError = this.displayMessage(model.error); }
    } finally { if (this.visible && generation === this.regionGeneration) { this.regionBusy = false; } }
  }

  private regionNames(): string[] {
    return this.regionPreview?.regions ?? ['香港', '台湾', '日本', '新加坡', '美国', '韩国', '英国', '德国', '未知'];
  }

  private regionLabel(name: string): string {
    // Region keys are persisted canonical data. Only their display labels are localized.
    if (name === '香港') { return UiText.get($r('app.string.profile_region_hk')); }
    if (name === '台湾') { return UiText.get($r('app.string.profile_region_tw')); }
    if (name === '日本') { return UiText.get($r('app.string.profile_region_jp')); }
    if (name === '新加坡') { return UiText.get($r('app.string.profile_region_sg')); }
    if (name === '美国') { return UiText.get($r('app.string.profile_region_us')); }
    if (name === '韩国') { return UiText.get($r('app.string.profile_region_kr')); }
    if (name === '英国') { return UiText.get($r('app.string.profile_region_uk')); }
    if (name === '德国') { return UiText.get($r('app.string.profile_region_de')); }
    return name === '未知' ? UiText.get($r('app.string.profile_other_region')) : name;
  }

  @Builder
  RegionAdvanced() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.template_region_advanced'))).fontSize(20).fontColor(UI.ink).fontWeight(FontWeight.Bold)
      Text(UiText.get($r('app.string.profile_region_risk'))).fontSize(13).fontColor(UI.muted)
      Flex({ wrap: FlexWrap.Wrap }) {
        Button(UiText.get($r('app.string.profile_by_region'))).constraintSize({ minHeight: 48 }).margin({ right: 8, bottom: 8 })
          .backgroundColor(this.regionMode === 'region' ? UI.action : UI.soft).fontColor(this.regionMode === 'region' ? UI.onAccent : UI.ink)
          .accessibilitySelected(this.regionMode === 'region').enabled(!this.regionBusy)
          .onClick(() => { if (this.regionMode !== 'region') { this.regionMode = 'region'; this.refreshRegionPreview(); } })
        Button(UiText.get($r('app.string.profile_all_nodes'))).constraintSize({ minHeight: 48 })
          .backgroundColor(this.regionMode === 'all' ? UI.action : UI.soft).fontColor(this.regionMode === 'all' ? UI.onAccent : UI.ink)
          .accessibilitySelected(this.regionMode === 'all').enabled(!this.regionBusy)
          .onClick(() => { if (this.regionMode !== 'all') { this.regionMode = 'all'; this.refreshRegionPreview(); } })
      }.width('100%')
      if (this.regionPreview !== null) {
        Text(UiText.get($r('app.string.profile_region_count'), Object.keys(this.regionPreview.nodes).length, this.regionPreview.unknown))
          .fontSize(14).fontColor(UI.ink)
        if (this.regionPreview.providerPending) {
          Text(UiText.get($r('app.string.profile_provider_wait'))).fontSize(13).fontColor(UI.error)
        }
        Scroll() {
          Column({ space: 8 }) {
            ForEach(Object.keys(this.regionPreview.nodes), (node: string) => {
              Row({ space: 8 }) {
                Text(node).fontSize(14).fontColor(UI.ink).layoutWeight(1)
                Select(this.regionNames().map((name: string): SelectOption => ({ value: this.regionLabel(name) })))
                  .constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
                  .selected(this.regionNames().indexOf(this.regionPreview?.nodes[node] ?? '未知'))
                  .value(this.regionLabel(this.regionPreview?.nodes[node] ?? '未知'))
                  .accessibilityText(UiText.get($r('app.string.profile_node_region'), node)).enabled(!this.regionBusy)
                  .onSelect((index: number) => {
                    if (this.regionBusy) { return; }
                    const next: Record<string, string> = {};
                    for (const key of Object.keys(this.regionAssignments)) { next[key] = this.regionAssignments[key]; }
                    next[node] = this.regionNames()[index]; this.regionAssignments = next; this.refreshRegionPreview();
                  })
              }.width('100%')
            }, (node: string) => node)
          }.width('100%')
        }.width('100%').layoutWeight(1)
      } else { Blank().layoutWeight(1) }
      if (this.regionError !== '') { Text(this.regionError).fontSize(14).fontColor(UI.error) }
      Button(UiText.get($r('app.string.profile_refresh_preview'))).width('100%').constraintSize({ minHeight: 44 })
        .backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.regionBusy).onClick(() => this.refreshRegionPreview())
      Button(UiText.get($r('app.string.editor_save_draft'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.regionCanSave()).onClick(() => this.saveRegionDraft())
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }

  @Builder
  option(id: string, label: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Radio({ value: id, group: 'routing-plan' }).checked(this.view.templateId === id)
          .radioStyle({ checkedBackgroundColor: UI.action, uncheckedBorderColor: UI.muted,
            indicatorColor: UI.onAccent }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
        Text(label).fontSize(16).fontColor(UI.ink).layoutWeight(1)
        if (this.view.publishedId === id) {
          Text(UiText.get($r('app.string.template_published'))).fontSize(12).fontColor(UI.accentText)
        }
      }.width('100%').padding(16)
    }.fontColor(UI.ink).constraintSize({ minHeight: 56 }).width('100%').borderRadius(16).backgroundColor(UI.paper)
      .accessibilitySelected(this.view.templateId === id).accessibilityText(label)
      .enabled(this.view.ready && !this.view.busy && !this.confirming && !this.model?.needsRepair())
      .onClick(() => { if (this.view.templateId !== id) { this.showChanges = false; this.model?.choose(id, ''); } })
  }

  private displayMessage(message: string): string {
    if (message === '') { return ''; }
    if (message === '应用未确认，请返回连接页断开后重连恢复') { return UiText.get($r('app.string.apply_feedback_unconfirmed')); }
    if (message === '配置已保存，地区选择待重连恢复') { return UiText.get($r('app.string.apply_feedback_committed')); }
    if (message === '请先在代理面板选择可用选项，再关闭或切换地区策略') { return UiText.get($r('app.string.apply_feedback_selection')); }
    if (message === '方案读取失败，请重试') { return UiText.get($r('app.string.template_read_failed')); }
    if (message === '请选择出口') { return UiText.get($r('app.string.template_choose_exit')); }
    if (message === '方案未通过校验，请检查出口和订阅资源') { return UiText.get($r('app.string.template_validation_failed')); }
    if (message === '应用失败，请重新预览后重试') { return UiText.get($r('app.string.template_apply_failed')); }
    if (message === '无法比较，请重新预览') { return UiText.get($r('app.string.template_compare_failed')); }
    if (message === '应用失败，请重新预览') { return UiText.get($r('app.string.template_update_failed')); }
    if (message === '部分高级字段需通过高级编辑修改') { return UiText.get($r('app.string.template_advanced_required')); }
    if (message === '方案已应用') { return UiText.get($r('app.string.template_applied')); }
    if (message === '已保存，启用后生效') { return UiText.get($r('app.string.template_saved')); }
    if (message === '更新已应用') { return UiText.get($r('app.string.template_update_applied')); }
    return UiText.get($r('app.string.template_result_unknown'));
  }
  build() {
    if (this.reviewingUpdate) {
      TemplateUpdateReview({ profileId: this.profileId, editor: this.activeEditor, source: this.activeUpdateSource,
        registerBackGuard: (guard: (() => boolean) | null) => { this.reviewBackGuard = guard; },
        onClose: () => { this.reviewingUpdate = false; this.load(); } })
    } else {
    Column({ space: 12 }) {
      Scroll() {
      Column({ space: 12 }) {
      if (this.updateAvailable) {
        Button(UiText.get($r('app.string.template_update'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(this.view.ready && !this.view.busy).onClick(() => { this.reviewingUpdate = true; })
      }
      if (!this.regionOnly) { this.option('original', UiText.get($r('app.string.template_original'))) }
      this.option('region', UiText.get($r('app.string.template_region')))
      if (!this.regionOnly) {
        this.option('ai', UiText.get($r('app.string.template_ai')))
        this.option('automatic', UiText.get($r('app.string.template_automatic')))
      }
      if ((this.view.dependencies ?? 0) > 0) {
        Text(UiText.get($r('app.string.template_dependents'), this.view.dependencies ?? 0)).fontSize(14).fontColor(UI.muted)
        Row({ space: 8 }) {
          Button(UiText.get($r('app.string.template_edit_dependents'))).backgroundColor(UI.soft).fontColor(UI.ink).layoutWeight(1).constraintSize({ minHeight: 48 }).onClick(() => this.close())
          Button(UiText.get($r('app.string.template_pause_dependents'))).backgroundColor(UI.soft).fontColor(UI.ink).layoutWeight(1).constraintSize({ minHeight: 48 })
            .enabled(!this.view.busy).onClick(() => this.model?.inspect(true))
        }.width('100%')
      }
      if (this.view.templateId !== 'original' && this.view.ready === true) {
        Text(this.view.templateId === 'region' ? UiText.get($r('app.string.template_selector')) : UiText.get($r('app.string.template_exit'))).fontSize(14).fontColor(UI.muted)
        Select((this.view.templateId === 'region' ? this.view.selectors :
          this.view.groups).map((name: string): SelectOption => { return { value: this.view.labels?.[name] ?? name }; })).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
          .selected(Math.max(0, (this.view.templateId === 'region' ? this.view.selectors : this.view.groups).indexOf(this.view.target)))
          .accessibilityText(this.view.templateId === 'region' ? UiText.get($r('app.string.template_selector')) : UiText.get($r('app.string.template_exit'))).value(this.view.labels?.[this.view.target] ?? (this.view.target || UiText.get($r('app.string.template_choose')))).width('100%').enabled(this.view.busy === false && !this.confirming && !this.model?.needsRepair())
          .onSelect((index: number) => this.model?.choose(this.view.templateId,
            (this.view.templateId === 'region' ? this.view.selectors : this.view.groups)[index] ?? ''))
      }
      if (this.view.templateId === 'region') {
        Button(UiText.get($r('app.string.template_region_advanced'))).width('100%').constraintSize({ minHeight: 48 })
          .backgroundColor(UI.soft).fontColor(UI.ink).enabled(this.view.ready && !this.view.busy && !this.confirming && this.view.target !== '' && !this.model?.needsRepair())
          .onClick(() => this.openRegionAdvanced())
      }
      if (this.view.templateId === 'ai') {
        Text(UiText.get($r('app.string.template_ai_scope'))).fontSize(13).fontColor(UI.muted)
      }
      if (this.view.templateId === 'ai' && this.view.ready && !this.model?.needsRepair()) {
        AiProbeStatus({ revision: this.aiRevision })
      }
      if (this.view.templateId === 'automatic') {
        Text(UiText.get($r('app.string.template_auto_scope'))).fontSize(13).fontColor(UI.muted)
      }
      if (this.view.applyFailure !== undefined && this.view.applyFailure !== '' && this.view.applyFailure !== 'failed') {
        Text(this.failureMessage()).fontSize(14).fontColor(UI.error)
      }
      if (this.recoveryMessage.length > 0) { Text(this.recoveryMessage).fontSize(14).fontColor(UI.muted) }
      if (this.view.error.length > 0) {
        Text(this.displayMessage(this.view.error)).fontSize(14).fontColor(UI.error)
      }
      if (this.view.result.length > 0) {
        Text(this.displayMessage(this.view.result)).fontSize(14).fontColor(UI.accentText)
      }
      if (this.showChanges && this.view.hasPreview) {
        Text(this.view.summary).fontSize(14).fontColor(UI.muted)
      }
      }.width('100%')
      }.width('100%').layoutWeight(1)
      if (this.needsRecovery()) {
        Button(UiText.get($r('app.string.apply_feedback_reconnect'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 48 }).width('100%')
          .enabled(!this.recovering).onClick(() => this.recoverApply())
      } else if (this.view.applyFailure === 'selection-required') {
        Button(UiText.get($r('app.string.apply_feedback_panel'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 48 }).width('100%')
          .enabled(!this.recovering).onClick(() => this.repairSelection())
      }
      if (this.view.ready !== true && this.view.busy === false && !this.confirming && !this.model?.needsRepair()) {
        Button(UiText.get($r('app.string.template_retry'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.load())
      }
      if (!this.model?.needsRepair()) {
        Button(UiText.get($r('app.string.template_view_changes'))).width('100%').constraintSize({ minHeight: 44 })
          .backgroundColor(Color.Transparent).fontColor(UI.accentText)
          .enabled(this.view.ready && !this.view.busy && !this.confirming && this.view.changed === true)
          .onClick(() => { this.showChanges = true; this.model?.inspect(); })
        Button(this.view.busy || this.confirming ? UiText.get($r('app.string.template_working')) : UiText.get($r('app.string.template_apply')))
          .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(this.view.ready && !this.view.busy && !this.confirming && this.view.changed === true)
          .onClick(() => this.apply())
      }
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
      .bindSheet($$this.showRegionAdvanced, this.RegionAdvanced(), { height: SheetSize.LARGE,
        shouldDismiss: (dismiss: SheetDismiss) => { if (!this.regionBusy && !this.view.busy) { this.regionGeneration++; dismiss.dismiss(); } } })
    }
  }
}
