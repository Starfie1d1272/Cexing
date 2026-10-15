import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { BackupResult } from '../lib/BackupJournal';
import { LocalBackup } from '../lib/LocalBackup';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct LocalBackupActions {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tab') @Watch('onVisibilityChanged') tab: number = 2;
  @Consume('rootVisible') @Watch('onVisibilityChanged') rootVisible: boolean = true;
  @State working: boolean = false;
  private exporting: number = -1;
  private restoring: number = -1;
  private pending: BackupResult | null = null;
  private active: boolean = false;
  private generation: number = 0;
  aboutToAppear(): void { this.active = true; }
  aboutToDisappear(): void {
    if (this.pending !== null && this.restoring !== this.generation) {
      const context = getContext(this) as common.UIAbilityContext;
      LocalBackup.cancel(context, this.pending).catch(() => {}); this.pending = null;
    }
    this.active = false; this.generation++; this.working = false; }
  private onVisibilityChanged(): void {
    if (this.pending !== null && this.restoring !== this.generation && (this.tab !== 2 || !this.rootVisible)) {
      LocalBackup.cancel(getContext(this) as common.UIAbilityContext, this.pending).catch(() => {}); this.pending = null;
    }
    this.generation++; this.working = false; this.active = this.tab === 2 && this.rootVisible;
  }
  private current(generation: number): boolean {
    return this.active && this.tab === 2 && this.rootVisible && generation === this.generation &&
      this.navStack.getAllPathName().length === 0;
  }
  private exportConfirm(): void {
    if (this.working) { return; }
    const generation = ++this.generation; this.working = true;
    AlertDialog.show({ title: UiText.get($r('app.string.backup_export')), message: UiText.get($r('app.string.backup_export_risk')),
      primaryButton: { value: UiText.get($r('app.string.backup_cancel')), action: () => { if (this.current(generation)) { this.generation++; this.working = false; } } },
      secondaryButton: { value: UiText.get($r('app.string.backup_choose_location')), action: () => { this.exportFile(generation); } },
      cancel: () => { if (this.current(generation)) { this.generation++; this.working = false; } } });
  }
  private async exportFile(generation: number): Promise<void> {
    if (!this.current(generation) || this.exporting === generation) { return; }
    this.exporting = generation;
    const context = getContext(this) as common.UIAbilityContext;
    const current = (): boolean => this.current(generation);
    try {
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['Cexing-backup.json']; options.fileSuffixChoices = [UiText.get($r('app.string.backup_file_type'))];
      const uris = await doc.save(options);
      if (!current() || uris.length === 0) { return; }
      await LocalBackup.exportTo(context, uris[0], current);
      if (current()) { promptAction.showToast({ message: UiText.get($r('app.string.backup_saved')) }); }
    } catch (_) { if (current()) { promptAction.showToast({ message: UiText.get($r('app.string.backup_export_failed')) }); } }
    finally { if (current()) { this.working = false; } }
  }
  private async importFile(): Promise<void> {
    if (this.working) { return; }
    const generation = ++this.generation; this.working = true;
    const context = getContext(this) as common.UIAbilityContext;
    const current = (): boolean => this.current(generation);
    let preview: BackupResult | null = null;
    try {
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1; options.fileSuffixFilters = ['.json'];
      const uris = await doc.select(options);
      if (!current()) { return; }
      if (uris.length === 0) { this.working = false; return; }
      preview = await LocalBackup.preview(context, uris[0], current);
      if (!current()) { await LocalBackup.cancel(context, preview); return; }
      this.pending = preview; this.confirmRestore(context, preview, generation);
    } catch (_) { if (current()) { this.working = false; promptAction.showToast({ message: UiText.get($r('app.string.backup_invalid')) }); } }
  }
  private confirmRestore(context: common.UIAbilityContext, preview: BackupResult, generation: number): void {
    const current = (): boolean => this.current(generation);
    const epoch = VpnController.configurationEpoch();
    const conflicts = preview.names.filter((name) => name.from !== name.to);
    const interrupt = VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop();
    const message = UiText.get($r('app.string.backup_restore_count'), preview.profiles) +
      (conflicts.length > 0 ? UiText.get($r('app.string.backup_conflicts'), conflicts.length) : '') +
      (preview.globalChanged ? UiText.get($r('app.string.backup_global_changed')) : '') + (interrupt ? UiText.get($r('app.string.backup_disconnect_risk')) : '');
    const cancel = (): void => {
      if (this.restoring === generation) { return; }
      if (this.pending === preview) { this.pending = null; }
      LocalBackup.cancel(context, preview).catch(() => {});
      if (current()) { this.generation++; this.working = false; }
    };
    AlertDialog.show({ title: UiText.get($r('app.string.backup_restore')), message: message,
      primaryButton: { value: UiText.get($r('app.string.backup_cancel')), action: cancel }, cancel: cancel,
      secondaryButton: { value: interrupt ? UiText.get($r('app.string.backup_disconnect_restore')) : UiText.get($r('app.string.backup_restore_action')), action: async () => {
        if (this.restoring === generation) { return; }
        if (!current() || epoch !== VpnController.configurationEpoch()) { cancel(); return; }
        this.restoring = generation;
        try {
          await LocalBackup.restore(context, preview, current, interrupt);
          if (current()) { promptAction.showToast({ message: UiText.get($r('app.string.backup_restored')) }); }
        } catch (error) {
          if (current()) { promptAction.showToast({ message: this.restoreFailure(error) }); }
          await LocalBackup.cancel(context, preview).catch(() => {});
        } finally { if (this.pending === preview) { this.pending = null; } if (current()) { this.working = false; } }
      } } });
  }
  private restoreFailure(error: Object): string {
    const message = (error as Error).message;
    if (message === '备份恢复未确认，请重新打开应用后重试') { return UiText.get($r('app.string.backup_restore_unknown')); }
    if (message === '恢复失败，原资料已保留') { return UiText.get($r('app.string.backup_restore_prior')); }
    if (message === '断开未确认，请重试' || message === '需要确认断开 VPN' || message === '请先确认断开 VPN') {
      return UiText.get($r('app.string.backup_stop_unconfirmed'));
    }
    return UiText.get($r('app.string.backup_restore_failed'));
  }
  build() {
    Column({ space: 8 }) {
      Button(UiText.get($r('app.string.backup_export'))).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.working).accessibilityDescription(this.working ? UiText.get($r('app.string.backup_working')) : '').onClick(() => this.exportConfirm())
      Button(UiText.get($r('app.string.backup_restore_local'))).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.working).accessibilityDescription(this.working ? UiText.get($r('app.string.backup_working')) : '').onClick(() => this.importFile())
    }.enabled(!this.working).width('100%').padding(14).backgroundColor(UI.surface).borderRadius(24)
  }
}
