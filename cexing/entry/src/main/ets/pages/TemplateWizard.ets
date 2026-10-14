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
  @Prop profileId: string = '';
  onClose: () => void = () => {};
  @State private view: TemplateWizardView = { templateId: 'original', target: '', busy: false,
    ready: false, error: '', result: '', summary: '', hasPreview: false, groups: [], selectors: [] };
  private confirming: boolean = false;
  private confirmationGeneration: number = 0;
  private model: TemplateWizardModel | null = null;
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true; this.confirmationGeneration++; this.confirming = false;
    const host = this.host ?? (this.profileId.length > 0 ?
      createTemplateWizardHost(getContext(this) as common.UIAbilityContext, this.profileId, this.editor) : undefined);
    if (host === undefined) { return; }
    this.model = new TemplateWizardModel(host, () => {
      if (this.model !== null) { this.view = this.model.snapshot(); }
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
        '将替换订阅规则，并启用已停用的个人修改。' : '将同时启用已停用的个人修改。') :
        '本地网络直连，其余流量使用所选出口。';
      const confirmation = ++this.confirmationGeneration;
      this.confirming = true;
      try {
        const answer = await promptAction.showDialog({ title: automatic ? '替换订阅分流规则？' : '应用分流方案？',
          message: message,
          buttons: [{ text: '取消', color: $r('app.color.ui_muted') }, { text: automatic ? '替换并应用' : '应用', color: $r('app.color.ui_accent_text') }] });
        if (!this.visible || answer.index !== 1 || this.model !== model || model.preview !== preview) { return; }
      } catch (_) { return; }
      finally { if (confirmation === this.confirmationGeneration) { this.confirming = false; } }
    }
    await model.apply(true);
  }
  @Builder
  option(id: string, label: string) {
    Button(label).height(44).width('100%')
      .backgroundColor(this.view.templateId === id ? UI.action : UI.soft)
      .fontColor(this.view.templateId === id ? UI.onAccent : UI.ink)
      .enabled(this.view.ready === true && this.view.busy === false)
      .onClick(() => this.model?.choose(id, ''))
  }
  build() {
    Column({ space: 12 }) {
      Row() {
        Text('分流方案').fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
        Blank()
        Button('返回').backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.close())
      }.width('100%')
      this.option('original', '保持订阅原样')
      this.option('region', '按地区智能选择')
      this.option('ai', 'AI 专用出口')
      this.option('automatic', '自动分流')
      if (this.view.templateId !== 'original' && this.view.ready === true) {
        Text(this.view.templateId === 'region' ? '原策略组' : '出口').fontSize(14).fontColor(UI.muted)
        Select((this.view.templateId === 'region' ? this.view.selectors :
          this.view.groups).map((name: string): SelectOption => { return { value: name }; }))
          .value(this.view.target || '请选择').width('100%').enabled(this.view.busy === false)
          .onSelect((_index: number, value: string) => this.model?.choose(this.view.templateId, value))
      }
      if (this.view.templateId === 'ai') {
        Text('常用 AI 服务使用所选出口，其余流量沿用订阅。').fontSize(13).fontColor(UI.muted)
      }
      if (this.view.templateId === 'automatic') {
        Text('本地网络直连，其余流量使用所选出口。').fontSize(13).fontColor(UI.muted)
      }
      if (this.view.error.length > 0) {
        Text(this.view.error).fontSize(14).fontColor(UI.error)
      }
      if (this.view.result.length > 0) {
        Text(this.view.result).fontSize(14).fontColor(UI.accentText)
      }
      if (this.view.hasPreview) {
        Text(this.view.summary).fontSize(14).fontColor(UI.muted)
      }
      Blank()
      if (this.view.ready !== true && this.view.busy === false) {
        Button('重试').onClick(() => this.model?.load())
      }
      Button(this.view.busy ? '处理中' : this.view.hasPreview ? '应用方案' : '预览')
        .width('100%').height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(this.view.ready === true && this.view.busy === false)
        .onClick(() => { if (this.model?.preview) { this.apply(); } else { this.model?.inspect(); } })
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
