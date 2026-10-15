import { UiText } from '../lib/UiText';
import { ProfileApplyFeedback, ProfileApplyFailureKind } from '../lib/ProfileApplyFeedback';
import { ProfileApplyRecovery } from '../lib/ProfileApplyRecovery';
import { ProfileImportInput } from '../lib/ProfileImportInput';
import { promptAction } from '@kit.ArkUI';
import { createTemplateUpdateSource } from '../lib/TemplateUpdateSource';
import { common } from '@kit.AbilityKit';
import { EditorDraftHost } from '../lib/ConfigEditor';
import { createTemplateUpdateHost, TemplateUpdateSource } from '../lib/TemplateUpdateHost';
import { TemplateConflict, TemplateUpdateHost, TemplateUpdateModel, TemplateUpdatePreview } from '../lib/TemplateUpdates';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct TemplateUpdateReview {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @State private recovering: boolean = false;
  @State private recoveryMessage: string = '';
  @State private applyFailure: ProfileApplyFailureKind | '' = '';
  private visible: boolean = false;
  private recoveryGeneration: number = 0;
  host?: TemplateUpdateHost;
  editor?: EditorDraftHost;
  source?: TemplateUpdateSource;
  @Prop profileId: string = '';
  private activeHost: TemplateUpdateHost | null = null;
  onClose: () => void = () => {};
  @State private conflicts: TemplateConflict[] = [];
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private summary: string = '';
  @State private message: string = '';
  private model: TemplateUpdateModel | null = null;
  aboutToAppear(): void {
    this.visible = true; this.recoveryGeneration++; this.recovering = false; this.recoveryMessage = '';
    const source = this.source ?? (this.profileId.length > 0 ?
      createTemplateUpdateSource(getContext(this) as common.UIAbilityContext, this.profileId) : undefined);
    const host = this.host ?? (source !== undefined && this.profileId.length > 0 ?
      createTemplateUpdateHost(getContext(this) as common.UIAbilityContext, this.profileId, this.editor, source) : undefined);
    if (host === undefined) { return; }
    this.activeHost = host;
    this.model = new TemplateUpdateModel(host, () => {
      const model = this.model;
      if (model === null) { return; }
      this.conflicts = model.preview?.conflicts ?? [];
      this.ready = model.preview?.ready === true && model.preview?.validation !== undefined;
      this.summary = model.preview?.validation?.summary ?? '';
      this.busy = model.busy;
      this.message = model.error || model.result;
      this.applyFailure = model.applyFailure;
    });
    this.model.setApplyFailure(ProfileApplyFeedback.recovery(getContext(this) as common.UIAbilityContext));
    this.model.refresh();
  }
  aboutToDisappear(): void { this.visible = false; this.recoveryGeneration++; this.model?.close(); }
  private close(): void { this.visible = false; this.recoveryGeneration++; this.model?.close(); this.onClose(); }
  private needsRecovery(): boolean { return this.applyFailure === 'unconfirmed' || this.applyFailure === 'committed-pending'; }
  private failureMessage(): string {
    return this.applyFailure !== '' ? (getContext(this) as common.UIAbilityContext)
      .resourceManager.getStringByNameSync(ProfileApplyFeedback.key(this.applyFailure)) : '';
  }
  private async recoverApply(): Promise<void> {
    const model = this.model; const file = this.profileId;
    if (!this.visible || this.recovering || model === null || model.busy || !this.needsRecovery()) { return; }
    const epoch = ++this.recoveryGeneration;
    const current = (): boolean => this.visible && epoch === this.recoveryGeneration && model === this.model && file === this.profileId;
    this.recovering = true; this.recoveryMessage = '';
    try {
      const accepted = await ProfileApplyRecovery.reconnect(getContext(this) as common.UIAbilityContext, current);
      if (!current() || accepted === null) { return; }
      if (accepted) {
        promptAction.showToast({ message: UiText.get($r('app.string.apply_feedback_starting')), duration: 1800 });
        if (!ProfileImportInput.hasPending()) { this.tabJump = 0; }
        this.navStack.clear();
      } else { this.recoveryMessage = UiText.get($r('app.string.apply_feedback_recovery_failed')); }
    } catch (_) { if (current()) { this.recoveryMessage = UiText.get($r('app.string.apply_feedback_recovery_failed')); } }
    finally { if (current()) { this.recovering = false; } }
  }
  private repairSelection(): void {
    if (this.visible && !this.recovering && this.applyFailure === 'selection-required') { this.navStack.pushPath({ name: 'zashboard' }); }
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
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.template_update_title'))).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Scroll() {
      Column({ space: 12 }) {
      if (this.ready) { Text(UiText.get($r('app.string.template_pending'))).fontSize(14).fontColor(UI.muted) }
      if (this.summary.length > 0) { Text(this.summary).fontSize(14).fontColor(UI.muted) }
      ForEach(this.conflicts, (conflict: TemplateConflict) => {
        Column({ space: 8 }) {
          Text(this.activeHost?.label(conflict) ?? UiText.get($r('app.string.template_personal'))).fontSize(15).fontColor(UI.ink)
          Text(UiText.get($r('app.string.template_conflict_mine'), this.activeHost?.detail?.(conflict).mine ?? UiText.get($r('app.string.template_personal')))).fontSize(14).fontColor(UI.muted)
          Text(UiText.get($r('app.string.template_conflict_new'), this.activeHost?.detail?.(conflict).template ?? UiText.get($r('app.string.template_personal')))).fontSize(14).fontColor(UI.muted)
          Row({ space: 8 }) {
            Button(UiText.get($r('app.string.template_keep_mine'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
              .enabled(!this.busy).onClick(() => this.model?.choose(conflict.id, 'mine'))
            Button(UiText.get($r('app.string.template_use_new'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
              .enabled(!this.busy).onClick(() => this.model?.choose(conflict.id, 'template'))
          }.width('100%')
        }.width('100%')
      }, (conflict: TemplateConflict) => conflict.id)
      if (this.message.length > 0) { Text(this.displayMessage(this.message)).fontSize(14).fontColor(UI.muted) }
      if (this.applyFailure !== '' && this.applyFailure !== 'failed') { Text(this.failureMessage()).fontSize(14).fontColor(UI.error) }
      if (this.recoveryMessage.length > 0) { Text(this.recoveryMessage).fontSize(14).fontColor(UI.muted) }
      }.width('100%')
      }.width('100%').layoutWeight(1)
      Row({ space: 8 }) {
        Button(UiText.get($r('app.string.template_back'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.close())
        if (!this.model?.needsRepair()) { Button(UiText.get($r('app.string.template_repreview'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy).onClick(() => this.model?.reset())
        }
      }.width('100%')
      if (this.needsRecovery()) {
        Button(UiText.get($r('app.string.apply_feedback_reconnect'))).width('100%').constraintSize({ minHeight: 48 })
          .enabled(!this.recovering).onClick(() => this.recoverApply())
      } else if (this.applyFailure === 'selection-required') {
        Button(UiText.get($r('app.string.apply_feedback_panel'))).width('100%').constraintSize({ minHeight: 48 })
          .enabled(!this.recovering).onClick(() => this.repairSelection())
      }
      if (!this.model?.needsRepair()) { Button(this.busy ? UiText.get($r('app.string.template_working')) : UiText.get($r('app.string.template_apply_update'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy && this.ready)
        .onClick(() => this.model?.apply())
      }
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
