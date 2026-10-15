import { UiText } from '../lib/UiText';
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
  host?: TemplateWizardHost;
  editor?: EditorDraftHost;
  updateSource?: TemplateUpdateSource;
  private activeUpdateSource?: TemplateUpdateSource;
  private activeEditor?: EditorDraftHost;
  @State private reviewingUpdate: boolean = false;
  @State private updateAvailable: boolean = false;
  @Prop profileId: string = '';
  onClose: () => void = () => {};
  onRecovery: (selection: boolean) => Promise<void> = async () => {};
  @State private recoveryBusy: boolean = false;
  @State private view: TemplateWizardView = { templateId: 'original', target: '', busy: false,
    ready: false, error: '', result: '', summary: '', hasPreview: false, groups: [], selectors: [] };
  private confirming: boolean = false;
  private confirmationGeneration: number = 0;
  @State private aiRevision: string = '';
  private aiBinding: AiProbeBinding = new AiProbeBinding();
  private model: TemplateWizardModel | null = null;
  private visible: boolean = false;

  aboutToAppear(): void {
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
        this.aiRevision = this.view.ready && !this.view.busy && this.view.templateId === 'ai' ?
          this.aiBinding.revision(getContext(this) as common.UIAbilityContext, this.profileId, this.view.target) : '';
        this.updateAvailable = this.view.ready && !this.view.busy &&
          (this.activeUpdateSource?.available?.(this.view.templateId, this.view.target) ?? this.updateSource !== undefined);
      }
    });
    this.model.load();
  }
  aboutToDisappear(): void { this.visible = false; this.confirmationGeneration++; this.confirming = false; this.model?.close(); }
  private close(): void { this.visible = false; this.confirmationGeneration++; this.confirming = false; this.model?.close(); this.onClose(); }
  private async apply(): Promise<void> {
    const model = this.model;
    if (model === null || model.busy || model.preview === null) { return; }
    if (this.confirming) { return; }
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
  @Builder
  option(id: string, label: string) {
    Button(label).constraintSize({ minHeight: 44 }).width('100%')
      .accessibilitySelected(this.view.templateId === id).backgroundColor(this.view.templateId === id ? UI.action : UI.soft)
      .fontColor(this.view.templateId === id ? UI.onAccent : UI.ink)
      .enabled(this.view.ready === true && this.view.busy === false)
      .onClick(() => this.model?.choose(id, ''))
  }
  private recoveryMessage(): string { return this.view.error || this.view.result; }
  private needsRecovery(): boolean {
    const message = this.recoveryMessage();
    return message === '应用未确认，请返回连接页断开后重连恢复' || message === '配置已保存，地区选择待重连恢复';
  }
  private needsSelection(): boolean {
    return this.recoveryMessage() === '请先在代理面板选择可用选项，再关闭或切换地区策略';
  }
  private async recover(): Promise<void> {
    if (this.recoveryBusy || (!this.needsRecovery() && !this.needsSelection())) { return; }
    this.recoveryBusy = true;
    try { await this.onRecovery(this.needsSelection()); }
    finally { this.recoveryBusy = false; }
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
        onRecovery: this.onRecovery, onClose: () => { this.reviewingUpdate = false; this.model?.load(); } })
    } else {
    Column({ space: 12 }) {
      Row() {
        Text(UiText.get($r('app.string.template_title'))).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
        Blank()
        Button(UiText.get($r('app.string.template_back'))).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.close())
      }.width('100%')
      Scroll() {
      Column({ space: 12 }) {
      if (this.updateAvailable) {
        Button(UiText.get($r('app.string.template_update'))).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(this.view.ready && !this.view.busy).onClick(() => { this.reviewingUpdate = true; })
      }
      this.option('original', UiText.get($r('app.string.template_original')))
      this.option('region', UiText.get($r('app.string.template_region')))
      this.option('ai', UiText.get($r('app.string.template_ai')))
      this.option('automatic', UiText.get($r('app.string.template_automatic')))
      if (this.view.templateId !== 'original' && this.view.ready === true) {
        Text(this.view.templateId === 'region' ? UiText.get($r('app.string.template_selector')) : UiText.get($r('app.string.template_exit'))).fontSize(14).fontColor(UI.muted)
        Select((this.view.templateId === 'region' ? this.view.selectors :
          this.view.groups).map((name: string): SelectOption => { return { value: this.view.labels?.[name] ?? name }; }))
          .selected(Math.max(0, (this.view.templateId === 'region' ? this.view.selectors : this.view.groups).indexOf(this.view.target)))
          .accessibilityText(this.view.templateId === 'region' ? UiText.get($r('app.string.template_selector')) : UiText.get($r('app.string.template_exit'))).value(this.view.labels?.[this.view.target] ?? (this.view.target || UiText.get($r('app.string.template_choose')))).width('100%').enabled(this.view.busy === false)
          .onSelect((index: number) => this.model?.choose(this.view.templateId,
            (this.view.templateId === 'region' ? this.view.selectors : this.view.groups)[index] ?? ''))
      }
      if (this.view.templateId === 'ai') {
        Text(UiText.get($r('app.string.template_ai_scope'))).fontSize(13).fontColor(UI.muted)
      }
      if (this.view.templateId === 'ai' && this.view.ready) {
        AiProbeStatus({ revision: this.aiRevision })
      }
      if (this.view.templateId === 'automatic') {
        Text(UiText.get($r('app.string.template_auto_scope'))).fontSize(13).fontColor(UI.muted)
      }
      if (this.view.error.length > 0) {
        Text(this.displayMessage(this.view.error)).fontSize(14).fontColor(UI.error)
      }
      if (this.view.result.length > 0) {
        Text(this.displayMessage(this.view.result)).fontSize(14).fontColor(UI.accentText)
      }
      if (this.view.hasPreview) {
        Text(this.view.summary).fontSize(14).fontColor(UI.muted)
      }
      }.width('100%')
      }.width('100%').layoutWeight(1)
      if (this.needsRecovery() || this.needsSelection()) {
        Button(this.needsSelection() ? $r('app.string.apply_feedback_panel') : $r('app.string.apply_feedback_reconnect'))
          .constraintSize({ minHeight: 44 }).enabled(!this.recoveryBusy)
          .onClick(() => { this.recover(); })
      }
      if (this.view.ready !== true && this.view.busy === false && !this.needsRecovery()) {
        Button(UiText.get($r('app.string.template_retry'))).onClick(() => this.model?.load())
      }
      Button(this.view.busy ? UiText.get($r('app.string.template_working')) : this.view.hasPreview ? UiText.get($r('app.string.template_apply_plan')) : UiText.get($r('app.string.template_preview')))
        .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(this.view.ready === true && this.view.busy === false)
        .onClick(() => { if (this.model?.preview) { this.apply(); } else { this.model?.inspect(); } })
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
    }
  }
}
