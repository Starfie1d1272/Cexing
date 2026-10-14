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
  @State private conflicts: TemplateConflict[] = [];
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private summary: string = '';
  @State private message: string = '';
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
    });
    this.model.refresh();
  }
  aboutToDisappear(): void { this.model?.close(); }
  private close(): void { this.model?.close(); this.onClose(); }
  build() {
    Column({ space: 12 }) {
      Text('更新分流方案').fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      if (this.ready) { Text('待应用').fontSize(14).fontColor(UI.muted) }
      if (this.summary.length > 0) { Text(this.summary).fontSize(14).fontColor(UI.muted) }
      ForEach(this.conflicts, (conflict: TemplateConflict) => {
        Column({ space: 8 }) {
          Text(this.activeHost?.label(conflict) ?? '个人修改').fontSize(15).fontColor(UI.ink)
          Row({ space: 8 }) {
            Button('保留我的修改').layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
              .enabled(!this.busy).onClick(() => this.model?.choose(conflict.id, 'mine'))
            Button('使用新模板').layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
              .enabled(!this.busy).onClick(() => this.model?.choose(conflict.id, 'template'))
          }.width('100%')
        }.width('100%')
      }, (conflict: TemplateConflict) => conflict.id)
      if (this.message.length > 0) { Text(this.message).fontSize(14).fontColor(UI.muted) }
      Blank()
      Row({ space: 8 }) {
        Button('返回').layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.close())
        Button('重新预览').layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy).onClick(() => this.model?.reset())
      }.width('100%')
      Button(this.busy ? '处理中' : '应用更新').width('100%').height(48)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy && this.ready)
        .onClick(() => this.model?.apply())
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
