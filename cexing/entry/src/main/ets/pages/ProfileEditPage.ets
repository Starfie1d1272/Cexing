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
  static backGuard: (() => boolean) | null = null;
  static shouldBlockBack(): boolean { return ProfileEditBus.backGuard?.() ?? false; }
}

@Component
export struct ProfileEditPage {
  @Prop mergeOnly: boolean = false;
  @Consume('profileRevision') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @State text: string = '';
  // Only loading/discarding replaces the native editor's text. Keystrokes must
  // not feed the entire document back through ArkUI's reactive state.
  private editedText: string = '';
  private file: string = '';
  private draftTimer: number = -1;
  @State editorRevision: number = 0;
  @State dirty: boolean = false;
  @State draftPersisted: boolean = false;
  @State draftPending: boolean = false;
  @State loadFailed: boolean = false;
  @State showSaveAsSheet: boolean = false;
  @State saveAsInput: string = '';
  @State saving: boolean = false;
  @State showMergeSheet: boolean = false;
  @State mergeText: string = '';
  @State mergeBusy: boolean = false;
  @State mergeSummary: string = '';
  @State mergeLoadFailed: boolean = false;
  private persistedMergeText: string = '';
  private backGuard: (() => boolean) | null = null;

  aboutToAppear(): void {
    this.backGuard = () => !this.prepareToLeave();
    ProfileEditBus.backGuard = this.backGuard;
    this.file = ProfileEditBus.current;
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, this.file);
    if (content === null) {
      this.loadFailed = true;
      return;
    }
    this.loadFailed = false;
    try {
      this.mergeText = ProfileStore.getMergeDraft(context, this.file);
      this.persistedMergeText = this.mergeText;
      this.mergeLoadFailed = false;
    } catch (_) {
      this.mergeText = '';
      this.mergeLoadFailed = true;
    }
    try {
      const draft = ProfileStore.readDraft(context, this.file);
      this.text = draft === null ? content : draft;
      this.dirty = draft !== null;
      this.draftPersisted = draft !== null;
    } catch (_) {
      this.text = content;
      this.dirty = false;
      this.draftPersisted = false;
    }
    this.editedText = this.text;
    this.draftPending = false;
  }

  aboutToDisappear(): void {
    if (ProfileEditBus.backGuard === this.backGuard) { ProfileEditBus.backGuard = null; }
    this.flushDraft();
    this.persistMergeDraft();
  }

  private cancelDraftTimer(): void {
    if (this.draftTimer !== -1) {
      clearTimeout(this.draftTimer);
      this.draftTimer = -1;
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
    const file = this.file;
    if (file.length === 0) {
      this.toast('目标配置不存在');
      return;
    }
    this.flushDraft();
    const snapshot = this.editedText;
    this.saving = true;
    try {
      const result = await ProfileTransactions.edit(context, file, snapshot);
      this.dirty = this.editedText !== snapshot;
      if (!this.dirty) { this.draftPersisted = false; }
      this.profileRevision++;
      this.toast(result === 'applied' ? '已保存并应用' : '已保存，启用或启动后生效');
      if (!this.dirty) {
        this.cancelDraftTimer();
        this.draftPending = false;
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
    if (this.saving) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, this.file);
    if (content === null) { this.toast('无法读取已保存配置'); return; }
    try { ProfileStore.clearDraft(context, this.file); } catch (_) {
      this.toast('草稿删除失败'); return;
    }
    this.cancelDraftTimer();
    this.editedText = content;
    this.text = content;
    this.editorRevision++;
    this.dirty = false;
    this.draftPersisted = false;
    this.draftPending = false;
  }

  private onTextChanged(value: string): void {
    if (value === this.editedText) { return; }
    this.editedText = value;
    this.dirty = true;
    this.draftPersisted = false;
    this.draftPending = true;
    this.cancelDraftTimer();
    this.draftTimer = setTimeout(() => {
      this.draftTimer = -1;
      this.flushDraft();
    }, 600);
  }

  private flushDraft(): void {
    this.cancelDraftTimer();
    if (!this.dirty || (!this.draftPending && this.draftPersisted)) { return; }
    this.persistDraft(this.editedText);
  }

  private persistDraft(value: string): void {
    this.dirty = true;
    this.draftPending = false;
    try {
      ProfileStore.writeDraft(getContext(this) as common.UIAbilityContext, this.file, value);
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
      const file = ProfileStore.importContent(context, input, this.editedText);
      this.profileRevision++;
      this.toast(`已另存为 ${file}`);
    } catch (e) {
      this.toast(`另存失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  private prepareToLeave(): boolean {
    if (this.saving || this.mergeBusy) { return false; }
    this.flushDraft();
    const mergeSaved = this.persistMergeDraft();
    return mergeSaved && (!this.dirty || this.draftPersisted);
  }

  private persistMergeDraft(): boolean {
    if (this.loadFailed || this.mergeLoadFailed) { return true; }
    if (this.mergeText === this.persistedMergeText) { return true; }
    try {
      ProfileStore.saveMergeDraft(getContext(this) as common.UIAbilityContext, this.file, this.mergeText);
      this.persistedMergeText = this.mergeText;
      return true;
    } catch (_) { this.toast('覆写草稿未能保存，请重试'); return false; }
  }

  private closeMerge(): void {
    if (this.mergeBusy || !this.persistMergeDraft()) { return; }
    if (this.mergeOnly) { this.navStack.pop(); }
    else { this.showMergeSheet = false; }
  }

  private openOriginalDraft(): void {
    if (this.mergeBusy || !this.persistMergeDraft()) { return; }
    if (this.mergeOnly) {
      ProfileEditBus.current = this.file;
      this.navStack.replacePath({ name: 'profileEdit' });
    } else { this.showMergeSheet = false; }
  }

  private async previewMerge(): Promise<void> {
    if (this.mergeBusy) { return; }
    if (this.mergeLoadFailed) { this.toast('覆写草稿读取失败，请重试'); return; }
    if (this.dirty) { this.toast('请先保存原始配置，再预览覆写'); return; }
    this.mergeBusy = true;
    this.mergeSummary = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.saveMergeDraft(context, this.file, this.mergeText);
      this.mergeSummary = result.changes.map((change: MergeChange) =>
        `${change.section}: ${change.before} → ${change.after}`).join(' · ');
      if (this.mergeSummary.length === 0) { this.mergeSummary = '配置内容无统计差异'; }
      this.toast('草稿已保存');
    } catch (e) {
      this.toast(`覆写预览失败: ${(e as Error).message ?? '请检查内容'}`);
    } finally { this.mergeBusy = false; }
  }

  private async applyMerge(): Promise<void> {
    if (this.mergeBusy || this.mergeLoadFailed) { return; }
    if (this.dirty) { this.toast('请先保存原始配置，再应用覆写'); return; }
    this.mergeBusy = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.applyMerge(context, this.file, this.mergeText);
      this.toast(result === 'applied' ? '本订阅覆写已应用' : '本订阅覆写已保存，下次连接时生效');
      this.profileRevision++;
    } catch (e) {
      this.toast(`应用覆写失败: ${(e as Error).message ?? '请检查内容'}`);
    } finally { this.mergeBusy = false; }
  }

  @Builder
  MergeSheet() {
    Column({ space: 12 }) {
      Text('本订阅覆写').fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      Text('仅作用于当前订阅')
        .fontSize(13).fontColor(UI.muted).width('100%')
      Button('编辑帮助').fontSize(13).backgroundColor(Color.Transparent).fontColor(UI.accentText)
        .onClick(() => {
          AlertDialog.show({ title: '本订阅覆写',
            message: '优先于全局覆写。预览保存草稿，应用后生效。清空内容并应用可停用。规则和策略组列表会替换订阅中的对应列表。',
            confirm: { value: '知道了', action: () => {} } });
        })
      if (this.mergeLoadFailed) {
        Text('覆写草稿读取失败，请关闭后重试').fontSize(13).fontColor(UI.error)
      }
      if (this.dirty) {
        Text('原始配置有未保存修改').fontSize(13).fontColor(UI.accentText).width('100%')
        Button('继续编辑原文').height(44).width('100%').backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.mergeBusy).onClick(() => { this.openOriginalDraft(); })
      }
      TextArea({ text: $$this.mergeText, placeholder: '输入 YAML 覆写配置' })
        .width('100%').layoutWeight(1).fontSize(14).fontFamily('HarmonyOS Sans Mono')
        .enabled(!this.mergeBusy && !this.mergeLoadFailed)
        .backgroundColor(UI.paper).borderRadius(12).padding(12)
      if (this.mergeSummary.length > 0) {
        Text(this.mergeSummary).fontSize(13).fontColor(UI.muted)
      }
      Row({ space: 12 }) {
        Button('关闭').height(44).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.mergeBusy).onClick(() => { this.closeMerge(); })
        Button(this.mergeBusy ? '预览中' : '预览')
          .height(44).layoutWeight(1).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(!this.mergeBusy && !this.mergeLoadFailed && !this.dirty).onClick(() => { this.previewMerge(); })
      }.width('100%')
      Button(this.mergeBusy ? '处理中' : '应用本订阅覆写')
        .height(44).width('100%').backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(!this.mergeBusy && !this.mergeLoadFailed && !this.dirty)
        .onClick(() => { this.applyMerge(); })
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
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
    if (this.mergeOnly) {
      this.MergeSheet()
    } else {
    Column({ space: 8 }) {
      Column({ space: 6 }) {
        Text(this.file)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(UI.ink)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.dirty) {
          Text(this.draftPending ? '未保存 · 正在保留草稿' :
            (this.draftPersisted ? '未保存 · 草稿已保留' : '草稿保留失败，请先保存配置'))
            .fontSize(13).fontColor(UI.accentText).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 8 })
      Row({ space: 12 }) {
        Button('本订阅覆写')
          .fontSize(14).height(40).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.loadFailed).onClick(() => { this.showMergeSheet = true; })
        Button('另存为')
          .fontSize(14).height(40).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.loadFailed).onClick(() => { this.showSaveAsSheet = true; })
      }.width('100%')

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
        // Recreate only on explicit discard, even when the initial seed is unchanged.
        ForEach([this.editorRevision], (_revision: number) => {
          TextArea({ text: this.text })
            .width('100%')
            .layoutWeight(1)
            .fontSize(14)
            .fontFamily('HarmonyOS Sans Mono')
            .backgroundColor(UI.surface)
            .borderRadius(12)
            .padding(12)
            .onChange((v: string) => {
              this.onTextChanged(v);
            })
        }, (revision: number) => revision.toString())
      }

      Text('保存前校验配置，连接中同步应用。')
        .fontSize(13).fontColor(UI.muted).width('100%')
      Row({ space: 12 }) {
        if (this.dirty) {
          Button('放弃草稿').height(48).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.error)
            .enabled(!this.saving).onClick(() => this.discardDraft())
        }
        Button(this.saving ? '保存中' : '保存配置')
          .height(48).layoutWeight(2).backgroundColor(UI.action).fontColor(UI.onAccent)
          .enabled(!this.loadFailed && !this.saving).onClick(() => { this.save(); })
      }.width('100%').margin({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .bindSheet($$this.showSaveAsSheet, this.SaveAsSheet(), { height: SheetSize.MEDIUM })
    .bindSheet($$this.showMergeSheet, this.MergeSheet(), { height: SheetSize.LARGE })
    }
  }
}
