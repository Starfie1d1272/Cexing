import { ProfileApplyFeedback } from '../lib/ProfileApplyFeedback';
import { UiText } from '../lib/UiText';
import { NativeTheme as UI } from './NativeTheme';
/*
 * ProfileEditPage.ets - 配置编辑页（二级导航，路由名 'profileEdit'，NavDestination 标题 '编辑配置' 由集成注册）
 * 编辑当前配置文本；保存后立即生效（运行中热重载）；支持另存为新配置
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ProfileStore } from '../lib/ProfileStore';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { CoreValidator } from '../lib/CoreValidator';
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
  @State mergeCommittedPending: boolean = false;
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
      this.mergeCommittedPending = ProfileStore.getActiveFile(context) === this.file &&
        ProfileApplyFeedback.recovery(context) === 'committed-pending';
      if (this.mergeCommittedPending) { this.mergeSummary = UiText.get($r('app.string.merge_committed_recovery')); }
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
      this.toast(UiText.get($r('app.string.original_read_failed')));
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const file = this.file;
    if (file.length === 0) {
      this.toast(UiText.get($r('app.string.original_missing')));
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
      this.toast(result === 'applied' ? UiText.get($r('app.string.original_applied')) : UiText.get($r('app.string.original_saved')));
      if (!this.dirty) {
        this.cancelDraftTimer();
        this.draftPending = false;
        try { ProfileStore.clearDraft(context, file); } catch (_) { /* saved text remains authoritative */ }
      }
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `save failed: ${msg}`);
      this.toast(this.safeFailure(e, $r('app.string.original_save_failed')));
    } finally {
      this.saving = false;
    }
  }

  private discardDraft(): void {
    if (this.saving) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, this.file);
    if (content === null) { this.toast(UiText.get($r('app.string.original_saved_unreadable'))); return; }
    try { ProfileStore.clearDraft(context, this.file); } catch (_) {
      this.toast(UiText.get($r('app.string.original_draft_delete_failed'))); return;
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
      this.toast(UiText.get($r('app.string.original_draft_failed')));
    }
  }

  private safeFailure(error: Object, fallback: Resource): string {
    return CoreValidator.describeMergeFailure(error, fallback);
  }

  private saveHelp(): void {
    AlertDialog.show({ title: UiText.get($r('app.string.editor_help')),
      message: UiText.get($r('app.string.original_save_help')),
      primaryButton: { value: UiText.get($r('app.string.editor_got_it')), action: () => {} } });
  }

  private async saveAs(): Promise<void> {
    if (this.saving) { return; }
    const input = this.saveAsInput.trim();
    this.showSaveAsSheet = false;
    this.saveAsInput = '';
    if (input.length === 0) {
      this.toast(UiText.get($r('app.string.original_name_required')));
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.saving = true;
    const owner = this.backGuard;
    const current = (): boolean => ProfileEditBus.backGuard === owner;
    try {
      const file = await ProfileStore.importContentAsync(context, input, this.editedText, current);
      if (!current()) { return; }
      this.profileRevision++;
      this.toast(UiText.get($r('app.string.original_saved_as'), file));
    } catch (e) {
      if (current()) { this.toast(this.safeFailure(e, $r('app.string.original_save_as_failed'))); }
    } finally { this.saving = false; }
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
    } catch (_) { this.toast(UiText.get($r('app.string.original_merge_draft_failed'))); return false; }
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
    if (this.mergeBusy || this.mergeCommittedPending) { return; }
    if (this.mergeLoadFailed) { this.toast(UiText.get($r('app.string.original_merge_read_failed'))); return; }
    if (this.dirty) { this.toast(UiText.get($r('app.string.original_save_before_preview'))); return; }
    this.mergeBusy = true;
    this.mergeSummary = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.saveMergeDraft(context, this.file, this.mergeText);
      this.mergeSummary = CoreValidator.describeMergePreview(result);
      this.toast(UiText.get($r('app.string.editor_draft_saved')));
    } catch (e) {
      this.toast(this.safeFailure(e, $r('app.string.editor_preview_failed')));
    } finally { this.mergeBusy = false; }
  }

  private async applyMerge(): Promise<void> {
    if (this.mergeBusy || this.mergeLoadFailed || this.mergeCommittedPending) { return; }
    if (this.dirty) { this.toast(UiText.get($r('app.string.original_save_before_apply'))); return; }
    this.mergeBusy = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.applyMerge(context, this.file, this.mergeText);
      this.toast(result === 'applied' ? UiText.get($r('app.string.original_merge_applied')) : UiText.get($r('app.string.original_merge_saved')));
      this.profileRevision++;
    } catch (e) {
      this.mergeCommittedPending = ProfileApplyFeedback.classify((e as Error).message ?? '') === 'committed-pending';
      if (this.mergeCommittedPending) {
        this.profileRevision++;
        this.mergeSummary = this.safeFailure(e, $r('app.string.editor_apply_failed'));
      }
      this.toast(this.safeFailure(e, $r('app.string.editor_apply_failed')));
    } finally { this.mergeBusy = false; }
  }

  private recoverCommittedMerge(): void {
    if (this.mergeBusy || !this.mergeCommittedPending || !this.prepareToLeave()) { return; }
    this.showMergeSheet = false;
    AppStorage.setOrCreate('connectionEntryRequest', (AppStorage.get<number>('connectionEntryRequest') ?? 0) + 1);
  }

  @Builder
  MergeSheet() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.original_merge'))).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      Text(UiText.get($r('app.string.original_scope')))
        .fontSize(13).fontColor(UI.muted).width('100%')
      Button(UiText.get($r('app.string.editor_help'))).constraintSize({ minHeight: 48 }).fontSize(13).backgroundColor(Color.Transparent).fontColor(UI.accentText)
        .onClick(() => {
          AlertDialog.show({ title: UiText.get($r('app.string.original_merge')),
            message: UiText.get($r('app.string.original_merge_help')),
            confirm: { value: UiText.get($r('app.string.editor_got_it')), action: () => {} } });
        })
      if (this.mergeLoadFailed) {
        Text(UiText.get($r('app.string.original_merge_blocked'))).fontSize(13).fontColor(UI.error)
      }
      if (this.dirty) {
        Text(UiText.get($r('app.string.original_unsaved'))).fontSize(13).fontColor(UI.accentText).width('100%')
        Button(UiText.get($r('app.string.original_continue'))).constraintSize({ minHeight: 44 }).width('100%').backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.mergeBusy).onClick(() => { this.openOriginalDraft(); })
      }
      TextArea({ text: $$this.mergeText, placeholder: UiText.get($r('app.string.editor_yaml_placeholder')) })
        .width('100%').layoutWeight(1).fontSize(14).fontFamily('HarmonyOS Sans Mono')
        .enabled(!this.mergeBusy && !this.mergeLoadFailed && !this.mergeCommittedPending)
        .backgroundColor(UI.paper).borderRadius(12).padding(12)
      if (this.mergeSummary.length > 0) {
        Scroll() { Text(this.mergeSummary).fontSize(13).fontColor(UI.muted).width('100%') }
          .width('100%').constraintSize({ maxHeight: 120 }).scrollBar(BarState.Auto)
      }
      if (this.mergeCommittedPending) {
        Button(UiText.get($r('app.string.merge_open_connection'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).width('100%')
          .enabled(!this.mergeBusy).onClick(() => this.recoverCommittedMerge())
      }
      Row({ space: 12 }) {
        Button(this.mergeBusy ? UiText.get($r('app.string.original_previewing')) : UiText.get($r('app.string.editor_preview')))
          .constraintSize({ minHeight: 44 }).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.mergeBusy && !this.mergeLoadFailed && !this.dirty && !this.mergeCommittedPending).onClick(() => { this.previewMerge(); })
      }.width('100%')
      Button(this.mergeBusy ? UiText.get($r('app.string.editor_working')) : UiText.get($r('app.string.original_apply_merge')))
        .constraintSize({ minHeight: 44 }).width('100%').backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(!this.mergeBusy && !this.mergeLoadFailed && !this.dirty && !this.mergeCommittedPending)
        .onClick(() => { this.applyMerge(); })
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }

  @Builder
  SaveAsSheet() {
    Column({ space: 14 }) {
      Text(UiText.get($r('app.string.original_save_copy_title')))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: UiText.get($r('app.string.original_new_name')) })
        .width('100%')
        .onChange((v: string) => {
          this.saveAsInput = v;
        })
      Row({ space: 12 }) {
        Button(UiText.get($r('app.string.network_cancel')))
          .constraintSize({ minHeight: 48 })
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.showSaveAsSheet = false;
            this.saveAsInput = '';
          })
        Button(UiText.get($r('app.string.original_save_copy')))
          .constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
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
          Text(this.draftPending ? UiText.get($r('app.string.original_draft_pending')) :
            (this.draftPersisted ? UiText.get($r('app.string.original_draft_kept')) : UiText.get($r('app.string.original_draft_keep_failed'))))
            .fontSize(13).fontColor(UI.accentText).width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).margin({ top: 8 })
      Row({ space: 12 }) {
        Button(UiText.get($r('app.string.original_merge')))
          .fontSize(14).constraintSize({ minHeight: 40 }).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.loadFailed).onClick(() => { this.showMergeSheet = true; })
        Button(UiText.get($r('app.string.original_save_as')))
          .fontSize(14).constraintSize({ minHeight: 40 }).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.ink)
          .enabled(!this.loadFailed).onClick(() => { this.showSaveAsSheet = true; })
      }.width('100%')

      if (this.loadFailed) {
        Column({ space: 8 }) {
          Text(UiText.get($r('app.string.original_read_error')))
            .fontSize(15)
            .fontColor(UI.muted)
          Text(UiText.get($r('app.string.original_file_retry')))
            .fontSize(13)
            .fontColor(UI.muted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // Recreate only on explicit discard, even when the initial seed is unchanged.
        ForEach([this.editorRevision], (_revision: number) => {
          TextArea({ text: this.text }).accessibilityText(UiText.get($r('app.string.original_content')))
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

      Button(UiText.get($r('app.string.editor_help'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).onClick(() => this.saveHelp())
      Row({ space: 12 }) {
        if (this.dirty) {
          Button(UiText.get($r('app.string.original_discard'))).constraintSize({ minHeight: 48 }).layoutWeight(1).backgroundColor(UI.soft).fontColor(UI.error)
            .enabled(!this.saving).onClick(() => this.discardDraft())
        }
        Button(this.saving ? UiText.get($r('app.string.original_saving')) : UiText.get($r('app.string.original_save')))
          .constraintSize({ minHeight: 48 }).layoutWeight(2).backgroundColor(UI.action).fontColor(UI.onAccent)
          .accessibilityDescription(this.loadFailed ? UiText.get($r('app.string.original_read_error')) : (this.saving ? UiText.get($r('app.string.original_saving')) : '')).enabled(!this.loadFailed && !this.saving).onClick(() => { this.save(); })
      }.width('100%').margin({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .bindSheet($$this.showSaveAsSheet, this.SaveAsSheet(), { height: SheetSize.MEDIUM })
    .bindSheet($$this.showMergeSheet, this.MergeSheet(), { height: SheetSize.LARGE,
      shouldDismiss: (dismiss: SheetDismiss) => { if (!this.mergeBusy && this.persistMergeDraft()) { dismiss.dismiss(); } } })
    }
  }
}
