import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { GlobalMergeDraft } from '../lib/GlobalMergeDraft';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { MergeChange } from '../lib/CoreValidator';

@Component
export struct GlobalMergeEditor {
  @Consume('profileRevision') profileRevision: number;
  onClose: () => void = () => {};
  @State private editedText: string = '';
  @State globalEnabled: boolean = false;
  @State busy: boolean = false;
  @State loadFailed: boolean = false;
  @State summary: string = '';
  private dirty: boolean = false;

  aboutToAppear(): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const current = EffectiveVersions.globalContent(context);
      this.globalEnabled = current.length > 0;
      this.editedText = GlobalMergeDraft.read(context) ?? current;
      this.loadFailed = false;
    } catch (_) { this.loadFailed = true; }
  }

  aboutToDisappear(): void {
    if (this.dirty && !this.loadFailed) { this.saveDraft(); }
  }

  private toast(message: string): void { promptAction.showToast({ message: message, duration: 1800 }); }

  private saveDraft(): boolean {
    if (this.loadFailed) { return false; }
    try {
      GlobalMergeDraft.save(getContext(this) as common.UIAbilityContext, this.editedText);
      this.dirty = false;
      return true;
    } catch (_) { this.toast('草稿保存失败，内容仍在编辑器中'); return false; }
  }

  private changeText(value: string): void {
    this.editedText = value;
    this.dirty = true;
    this.summary = '';
  }

  private close(): void {
    if (!this.busy && (!this.dirty || this.saveDraft())) { this.onClose(); }
  }

  private async preview(): Promise<void> {
    if (this.busy || this.loadFailed || !this.saveDraft()) { return; }
    this.busy = true;
    this.summary = '';
    try {
      const result = await ProfileTransactions.previewGlobalMerge(
        getContext(this) as common.UIAbilityContext, this.editedText);
      this.summary = result.changes.map((change: MergeChange) =>
        `${change.section}: ${change.before} → ${change.after}`).join(' · ') || '配置内容无统计差异';
    } catch (e) { this.summary = (e as Error).message ?? '覆写预览失败'; }
    finally { this.busy = false; }
  }

  private async apply(): Promise<void> {
    if (this.busy || this.loadFailed || !this.saveDraft()) { return; }
    this.busy = true;
    try {
      const result = await ProfileTransactions.applyGlobalMerge(
        getContext(this) as common.UIAbilityContext, this.editedText);
      this.globalEnabled = this.editedText.length > 0;
      this.profileRevision++;
      this.toast(result === 'applied' ? '全局覆写已应用' : '全局覆写已保存，启动后生效');
      this.summary = '其他订阅会在启用或更新时重新校验并应用。';
    } catch (e) { this.summary = (e as Error).message ?? '应用失败，保留原有效配置'; }
    finally { this.busy = false; }
  }

  build() {
    Column({ space: 12 }) {
      Text('全局覆写').fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text(this.globalEnabled ? '已启用' : '未启用')
        .fontSize(13).fontColor(UI.accentText)
      Text('为所有订阅设置通用配置，单个订阅的覆写优先。')
        .fontSize(13).fontColor(UI.muted)
      Text('预览查看当前订阅的变化，应用后生效。清空内容并应用可停用。')
        .fontSize(13).fontColor(UI.muted)
      Text('填写规则或策略组列表时，会替换订阅中的对应列表。')
        .fontSize(13).fontColor(UI.muted)
      if (this.loadFailed) {
        Text('现有覆写或草稿读取失败，已阻止覆盖').fontSize(13).fontColor(UI.error)
      }
      TextArea({ text: $$this.editedText, placeholder: '输入 YAML 覆写配置' })
        .width('100%').layoutWeight(1).fontSize(14).fontFamily('HarmonyOS Sans Mono')
        .backgroundColor(UI.paper).borderRadius(12).padding(12)
        .enabled(!this.busy && !this.loadFailed).onChange((value: string) => this.changeText(value))
      if (this.summary.length > 0) { Text(this.summary).fontSize(13).fontColor(UI.muted).maxLines(4) }
      Row({ space: 8 }) {
        Button('关闭').layoutWeight(1).height(44).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy).onClick(() => this.close())
        Button('保存草稿').layoutWeight(1).height(44).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy && !this.loadFailed).onClick(() => { if (this.saveDraft()) { this.toast('草稿已保存'); } })
        Button('预览').layoutWeight(1).height(44).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.busy && !this.loadFailed).onClick(() => this.preview())
      }.width('100%')
      Button(this.busy ? '处理中' : '应用全局覆写').width('100%').height(48)
        .backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(!this.busy && !this.loadFailed).onClick(() => this.apply())
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
