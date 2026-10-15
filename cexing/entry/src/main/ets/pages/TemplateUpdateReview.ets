import { UiText } from '../lib/UiText';
import { createTemplateUpdateSource } from '../lib/TemplateUpdateSource';
import { common } from '@kit.AbilityKit';
import { EditorDraftHost } from '../lib/ConfigEditor';
import { createTemplateUpdateHost, TemplateUpdateSource } from '../lib/TemplateUpdateHost';
import { TemplateConflict, TemplateUpdateHost, TemplateUpdateModel, TemplateUpdatePreview } from '../lib/TemplateUpdates';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct TemplateUpdateReview {
  host?: TemplateUpdateHost;
  editor?: EditorDraftHost;
  source?: TemplateUpdateSource;
  @Prop profileId: string = '';
  private activeHost: TemplateUpdateHost | null = null;
  onClose: () => void = () => {};
  onRecovery: (selection: boolean) => Promise<void> = async () => {};
  @State private recoveryBusy: boolean = false;
  @State private conflicts: TemplateConflict[] = [];
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private summary: string = '';
  @State private message: string = '';
  @State private recoveryRequired: boolean = false;
  private model: TemplateUpdateModel | null = null;
  aboutToAppear(): void {
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
      this.recoveryRequired = model.recoveryRequired;
    });
    this.model.refresh();
  }
  aboutToDisappear(): void { this.model?.close(); }
  private close(): void { this.model?.close(); this.onClose(); }
  private recoveryMessage(): string { return this.message; }
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
      }.width('100%')
      }.width('100%').layoutWeight(1)
      if (this.needsRecovery() || this.needsSelection()) {
        Button(this.needsSelection() ? $r('app.string.apply_feedback_panel') : $r('app.string.apply_feedback_reconnect'))
          .constraintSize({ minHeight: 44 }).enabled(!this.recoveryBusy)
          .onClick(() => { this.recover(); })
      }
      Row({ space: 8 }) {
        Button(UiText.get($r('app.string.template_back'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.close())
        if (!this.recoveryRequired) { Button(UiText.get($r('app.string.template_repreview'))).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy).onClick(() => this.model?.reset())
        }
      }.width('100%')
      Button(this.busy ? UiText.get($r('app.string.template_working')) : UiText.get($r('app.string.template_apply_update'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy && this.ready)
        .onClick(() => this.model?.apply())
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
