import { ProfileApplyFeedback } from '../lib/ProfileApplyFeedback';
import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { NativeTheme as UI } from './NativeTheme';
import { GlobalMergeDraft } from '../lib/GlobalMergeDraft';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { CoreValidator } from '../lib/CoreValidator';

@Component
export struct GlobalMergeEditor {
  @Consume('profileRevision') profileRevision: number;
  onClose: () => void = () => {};
  registerCloseGuard: (guard: (() => boolean) | null) => void = () => {};
  private prepareClose: (() => boolean) | null = null;
  @State private editedText: string = '';
  @State globalEnabled: boolean = false;
  @State busy: boolean = false;
  @State loadFailed: boolean = false;
  @State summary: string = '';
  @State committedPending: boolean = false;
  private dirty: boolean = false;

  aboutToAppear(): void {
    this.prepareClose = () => !this.busy && (!this.dirty || this.saveDraft());
    this.registerCloseGuard(this.prepareClose);
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const current = EffectiveVersions.globalContent(context);
      this.globalEnabled = current.length > 0;
      this.editedText = GlobalMergeDraft.read(context) ?? current;
      this.loadFailed = false;
      this.committedPending = ProfileApplyFeedback.recovery(context) === 'committed-pending';
      if (this.committedPending) { this.summary = UiText.get($r('app.string.merge_committed_recovery')); }
    } catch (_) { this.loadFailed = true; }
  }

  aboutToDisappear(): void {
    this.registerCloseGuard(null);
  }

  private toast(message: string): void { promptAction.showToast({ message: message, duration: 1800 }); }

  private saveDraft(): boolean {
    if (this.loadFailed) { return false; }
    try {
      GlobalMergeDraft.save(getContext(this) as common.UIAbilityContext, this.editedText);
      this.dirty = false;
      return true;
    } catch (_) { this.toast(UiText.get($r('app.string.editor_draft_failed'))); return false; }
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
    if (this.busy || this.loadFailed || this.committedPending || !this.saveDraft()) { return; }
    this.busy = true;
    this.summary = '';
    try {
      const result = await ProfileTransactions.previewGlobalMerge(
        getContext(this) as common.UIAbilityContext, this.editedText);
      this.summary = CoreValidator.describeMergePreview(result);
    } catch (e) { this.summary = this.safeFailure(e, $r('app.string.editor_preview_failed')); }
    finally { this.busy = false; }
  }

  private async apply(): Promise<void> {
    if (this.busy || this.loadFailed || this.committedPending || !this.saveDraft()) { return; }
    this.busy = true;
    try {
      const result = await ProfileTransactions.applyGlobalMerge(
        getContext(this) as common.UIAbilityContext, this.editedText);
      this.globalEnabled = this.editedText.length > 0;
      this.profileRevision++;
      this.toast(result === 'applied' ? UiText.get($r('app.string.editor_global_applied')) : UiText.get($r('app.string.editor_global_saved')));
      this.summary = UiText.get($r('app.string.editor_other_profiles'));
    } catch (e) {
      this.committedPending = ProfileApplyFeedback.classify((e as Error).message ?? '') === 'committed-pending';
      if (this.committedPending) { this.globalEnabled = this.editedText.length > 0; this.profileRevision++; }
      this.summary = this.safeFailure(e, $r('app.string.editor_apply_failed'));
    }
    finally { this.busy = false; }
  }

  private recoverCommitted(): void {
    if (this.busy || !this.committedPending || !this.saveDraft()) { return; }
    this.onClose();
    AppStorage.setOrCreate('connectionEntryRequest', (AppStorage.get<number>('connectionEntryRequest') ?? 0) + 1);
  }

  private safeFailure(error: Object, fallback: Resource): string {
    return CoreValidator.describeMergeFailure(error, fallback);
  }

  private help(): void {
    AlertDialog.show({ title: UiText.get($r('app.string.editor_global')),
      message: UiText.get($r('app.string.editor_global_scope')) + '\n' +
        UiText.get($r('app.string.editor_global_help')) + '\n' + UiText.get($r('app.string.editor_list_help')),
      primaryButton: { value: UiText.get($r('app.string.editor_got_it')), action: () => {} } });
  }

  build() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.editor_global'))).fontSize(22).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text(this.globalEnabled ? UiText.get($r('app.string.editor_enabled')) : UiText.get($r('app.string.editor_disabled')))
        .fontSize(13).fontColor(UI.accentText)
      Button(UiText.get($r('app.string.editor_help'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).onClick(() => this.help())
      if (this.loadFailed) {
        Text(UiText.get($r('app.string.editor_read_blocked'))).fontSize(13).fontColor(UI.error)
      }
      TextArea({ text: $$this.editedText, placeholder: UiText.get($r('app.string.editor_yaml_placeholder')) })
        .width('100%').layoutWeight(1).fontSize(14).fontFamily('HarmonyOS Sans Mono')
        .backgroundColor(UI.paper).borderRadius(12).padding(12).accessibilityText(UiText.get($r('app.string.editor_global')))
        .accessibilityDescription(this.loadFailed ? UiText.get($r('app.string.editor_read_blocked')) : (this.busy ? UiText.get($r('app.string.editor_working')) : '')).enabled(!this.busy && !this.loadFailed && !this.committedPending).onChange((value: string) => this.changeText(value))
      if (this.summary.length > 0) {
        Scroll() { Text(this.summary).fontSize(13).fontColor(UI.muted).width('100%') }
          .width('100%').constraintSize({ maxHeight: 120 }).scrollBar(BarState.Auto)
      }
      if (this.committedPending) {
        Button(UiText.get($r('app.string.merge_open_connection'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 }).width('100%')
          .enabled(!this.busy).onClick(() => this.recoverCommitted())
      }
      Row({ space: 8 }) {
        Button(UiText.get($r('app.string.editor_preview'))).layoutWeight(1).constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.ink)
          .accessibilityDescription(this.loadFailed ? UiText.get($r('app.string.editor_read_blocked')) : (this.busy ? UiText.get($r('app.string.editor_working')) : '')).enabled(!this.busy && !this.loadFailed && !this.committedPending).onClick(() => this.preview())
      }.width('100%')
      Button(this.busy ? UiText.get($r('app.string.editor_working')) : UiText.get($r('app.string.editor_apply_global'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.action).fontColor(UI.onAccent)
        .accessibilityDescription(this.loadFailed ? UiText.get($r('app.string.editor_read_blocked')) : (this.busy ? UiText.get($r('app.string.editor_working')) : '')).enabled(!this.busy && !this.loadFailed && !this.committedPending).onClick(() => this.apply())
    }.width('100%').height('100%').padding(20).backgroundColor(UI.surface)
  }
}
