import { NativeTheme as UI } from './NativeTheme';
/*
 * ProfileEditPage.ets - 配置编辑页（二级导航，路由名 'profileEdit'，NavDestination 标题 '编辑配置' 由集成注册）
 * 编辑当前配置文本；保存后立即生效（运行中热重载）；支持另存为新配置
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ProfileStore } from '../lib/ProfileStore';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { MergeChange } from '../lib/CoreValidator';
import { Logger } from '../lib/Logger';

const TAG = 'profileEdit';

/** 页面间传参总线：列表页 push 前写入，编辑页 aboutToAppear 读取 */
export class ProfileEditBus {
  static current: string = '';
}

@Component
export struct ProfileEditPage {
  @Consume('profileRevision') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @State text: string = '';
  @State dirty: boolean = false;
  @State draftPersisted: boolean = false;
  @State loadFailed: boolean = false;
  @State showSaveAsSheet: boolean = false;
  @State saveAsInput: string = '';
  @State saving: boolean = false;
  @State showMergeSheet: boolean = false;
  @State mergeText: string = '';
  @State mergeBusy: boolean = false;
  @State mergeSummary: string = '';
  @State mergeLoadFailed: boolean = false;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, ProfileEditBus.current);
    if (content === null) {
      this.loadFailed = true;
      return;
    }
    this.loadFailed = false;
    try {
      this.mergeText = ProfileStore.getMergeDraft(context, ProfileEditBus.current);
      this.mergeLoadFailed = false;
    } catch (_) {
      this.mergeText = '';
      this.mergeLoadFailed = true;
    }
    try {
      const draft = ProfileStore.readDraft(context, ProfileEditBus.current);
      this.text = draft === null ? content : draft;
      this.dirty = draft !== null;
      this.draftPersisted = draft !== null;
    } catch (_) {
      this.text = content;
      this.dirty = false;
      this.draftPersisted = false;
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private async save(): Promise<void> {
    if (this.saving) { return; }
    if (this.loadFailed) {
      this.toast('配置文件读取失败，无法保存');
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const file = ProfileEditBus.current;
    if (file.length === 0) {
      this.toast('目标配置不存在');
      return;
    }
    const snapshot = this.text;
    this.saving = true;
    try {
      const result = await ProfileTransactions.edit(context, file, snapshot);
      this.dirty = this.text !== snapshot;
      if (!this.dirty) { this.draftPersisted = false; }
      this.profileRevision++;
      this.toast(result === 'applied' ? '已保存并应用' : '已保存，启用或启动后生效');
      if (!this.dirty) {
        try { ProfileStore.clearDraft(context, file); } catch (_) { /* saved text remains authoritative */ }
      }
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `save failed: ${msg}`);
      this.toast(`保存失败: ${msg}`);
    } finally {
      this.saving = false;
    }
  }

  private discardDraft(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, ProfileEditBus.current);
    if (content === null) { this.toast('无法读取已保存配置'); return; }
    try { ProfileStore.clearDraft(context, ProfileEditBus.current); } catch (_) {
      this.toast('草稿删除失败'); return;
    }
    this.text = content;
    this.dirty = false;
    this.draftPersisted = false;
  }

  private persistDraft(value: string): void {
    this.dirty = true;
    try {
      ProfileStore.writeDraft(getContext(this) as common.UIAbilityContext, ProfileEditBus.current, value);
      this.draftPersisted = true;
    } catch (_) {
      this.draftPersisted = false;
      this.toast('草稿保存失败，请先保存配置');
    }
  }

  private saveAs(): void {
    const input = this.saveAsInput.trim();
    this.showSaveAsSheet = false;
    this.saveAsInput = '';
    if (input.length === 0) {
      this.toast('名称不能为空');
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const file = ProfileStore.importContent(context, input, this.text);
      this.profileRevision++;
      this.toast(`已另存为 ${file}`);
    } catch (e) {
      this.toast(`另存失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  private async previewMerge(): Promise<void> {
    if (this.mergeBusy) { return; }
    if (this.mergeLoadFailed) { this.toast('现有 Merge 草稿读取失败，未覆盖'); return; }
    if (this.dirty) { this.toast('请先保存原始配置，再预览 Merge'); return; }
    this.mergeBusy = true;
    this.mergeSummary = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.saveMergeDraft(context, ProfileEditBus.current, this.mergeText);
      this.mergeSummary = result.changes.map((change: MergeChange) =>
        `${change.section}: ${change.before} → ${change.after}`).join(' · ');
      if (this.mergeSummary.length === 0) { this.mergeSummary = '配置内容无统计差异'; }
      this.toast('Merge 草稿已保存');
    } catch (e) {
      this.toast(`Merge 预览失败: ${(e as Error).message ?? '请检查内容'}`);
    } finally { this.mergeBusy = false; }
  }

  @Builder
  MergeSheet() {
    Column({ space: 12 }) {
      Text('每订阅 Merge 草稿').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      Text('采用 Clash Verge 2.5.8 合并规则。预览仅显示字段数量；草稿目前不会改变运行配置。')
        .fontSize(13).fontColor(UI.muted)
      if (this.mergeLoadFailed) {
        Text('现有 Merge 草稿读取失败，已阻止覆盖').fontSize(13).fontColor(UI.error)
      }
      TextArea({ text: $$this.mergeText })
        .width('100%').height(250).fontSize(14).fontFamily('HarmonyOS Sans Mono')
        .enabled(!this.mergeBusy && !this.mergeLoadFailed)
        .backgroundColor(UI.paper).borderRadius(12).padding(12)
      if (this.mergeSummary.length > 0) {
        Text(this.mergeSummary).fontSize(13).fontColor(UI.muted)
      }
      Row({ space: 12 }) {
        Button('关闭').height(44).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .onClick(() => { this.showMergeSheet = false; })
        Button(this.mergeBusy ? '预览中' : '校验并保存草稿')
          .height(44).layoutWeight(1).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(!this.mergeBusy && !this.mergeLoadFailed).onClick(() => { this.previewMerge(); })
      }.width('100%')
    }.padding(20).backgroundColor(UI.surface).borderRadius(24)
  }

  @Builder
  HeaderButton(label: string, symbol: Resource, color: ResourceColor, enabled: boolean, onTap: () => void) {
    SymbolGlyph(symbol)
      .fontSize(22)
      .fontColor([color])
      .width(48).height(48)
      .accessibilityText(label)
      .enabled(enabled)
      .stateStyles({
        pressed: { .opacity(0.6) },
        normal: { .opacity(1.0) }
      })
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  SaveAsSheet() {
    Column({ space: 14 }) {
      Text('另存为新配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: '新配置名称（自动补 .yaml）' })
        .width('100%')
        .onChange((v: string) => {
          this.saveAsInput = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .height(48)
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.showSaveAsSheet = false;
            this.saveAsInput = '';
          })
        Button('保存副本')
          .height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
          .layoutWeight(1)
          .onClick(() => {
            this.saveAs();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 2 }) {
          Text(`编辑中：${ProfileEditBus.current}`)
            .fontSize(13)
            .fontColor(UI.muted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.dirty) {
            Text(this.draftPersisted ? '未保存 · 草稿已保留，返回后可继续编辑' : '未保存 · 草稿保留失败，请先保存配置')
              .fontSize(13)
              .fontColor(UI.accentText)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('Merge 预览')
          .fontSize(13).height(40).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.loadFailed).onClick(() => { this.showMergeSheet = true; })
        this.HeaderButton('另存为', $r('sys.symbol.doc_filled_on_doc'), UI.muted, !this.loadFailed, () => {
          this.showSaveAsSheet = true;
        })
        this.HeaderButton('保存', $r('sys.symbol.checkmark'), UI.accent, !this.loadFailed && !this.saving, () => {
          this.save();
        })
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.loadFailed) {
        Column({ space: 8 }) {
          Text('配置文件读取失败')
            .fontSize(15)
            .fontColor(UI.muted)
          Text('文件可能已被删除，请返回配置页重试')
            .fontSize(13)
            .fontColor(UI.muted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        TextArea({ text: $$this.text })
          .width('100%')
          .layoutWeight(1)
          .fontSize(14)
          .fontFamily('HarmonyOS Sans Mono')
          .backgroundColor(UI.surface)
          .borderRadius(12)
          .padding(12)
          .onChange((v: string) => {
            this.persistDraft(v);
          })
      }

      if (this.dirty) {
        Button('放弃草稿').height(44).backgroundColor(UI.soft).fontColor(UI.error)
          .onClick(() => this.discardDraft())
      }
      Text('保存会校验配置；运行中成功热加载后才覆盖原文件')
        .fontSize(13)
        .fontColor(UI.muted)
        .width('100%')
        .margin({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .bindSheet($$this.showSaveAsSheet, this.SaveAsSheet(), { height: SheetSize.MEDIUM })
    .bindSheet($$this.showMergeSheet, this.MergeSheet(), { height: SheetSize.LARGE })
  }
}
