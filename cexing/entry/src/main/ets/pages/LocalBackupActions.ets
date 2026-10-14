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
    this.generation++; this.working = false; this.active = this.tab === 2 && this.rootVisible;
  }
  private current(generation: number): boolean {
    return this.active && this.tab === 2 && this.rootVisible && generation === this.generation &&
      this.navStack.getAllPathName().length === 0;
  }
  private exportConfirm(): void {
    if (this.working) { return; }
    const generation = ++this.generation; this.working = true;
    AlertDialog.show({ title: '导出本地备份', message: '备份含订阅地址和节点凭据，请妥善保管。',
      primaryButton: { value: '取消', action: () => { if (this.current(generation)) { this.working = false; } } },
      secondaryButton: { value: '选择保存位置', action: () => { this.exportFile(generation); } },
      cancel: () => { if (this.current(generation)) { this.working = false; } } });
  }
  private async exportFile(generation: number): Promise<void> {
    if (!this.current(generation)) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const current = (): boolean => this.current(generation);
    try {
      const doc = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['Cexing-backup.json']; options.fileSuffixChoices = ['备份|.json'];
      const uris = await doc.save(options);
      if (!current() || uris.length === 0) { return; }
      await LocalBackup.exportTo(context, uris[0], current);
      if (current()) { promptAction.showToast({ message: '备份已保存' }); }
    } catch (_) { if (current()) { promptAction.showToast({ message: '导出未完成，请重试' }); } }
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
      if (!current() || uris.length === 0) { this.working = false; return; }
      preview = await LocalBackup.preview(context, uris[0], current);
      if (!current()) { await LocalBackup.cancel(context, preview); return; }
      this.pending = preview; this.confirmRestore(context, preview, generation);
    } catch (_) { if (current()) { this.working = false; promptAction.showToast({ message: '备份无法读取或验证，请检查文件' }); } }
  }
  private confirmRestore(context: common.UIAbilityContext, preview: BackupResult, generation: number): void {
    const current = (): boolean => this.current(generation);
    const epoch = VpnController.configurationEpoch();
    const conflicts = preview.names.filter((name) => name.from !== name.to);
    const interrupt = VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop();
    const message = `导入 ${preview.profiles} 个订阅并恢复设置。` +
      (conflicts.length > 0 ? ` ${conflicts.length} 个同名订阅将另存为新名称。` : '') +
      (preview.globalChanged ? ' 全局覆写将更新。' : '') + (interrupt ? ' 将先断开 VPN。' : '');
    const cancel = (): void => {
      if (this.restoring === generation) { return; }
      this.pending = null;
      LocalBackup.cancel(context, preview).catch(() => {});
      if (current()) { this.working = false; }
    };
    AlertDialog.show({ title: '恢复备份', message: message,
      primaryButton: { value: '取消', action: cancel }, cancel: cancel,
      secondaryButton: { value: interrupt ? '断开并恢复' : '恢复', action: async () => {
        if (this.restoring === generation) { return; }
        if (!current() || epoch !== VpnController.configurationEpoch()) { cancel(); return; }
        this.restoring = generation;
        try {
          await LocalBackup.restore(context, preview, current, interrupt);
          if (current()) { promptAction.showToast({ message: '已恢复，下次连接生效' }); }
        } catch (error) {
          if (current()) { promptAction.showToast({ message: (error as Error).message }); }
          await LocalBackup.cancel(context, preview).catch(() => {});
        } finally { this.pending = null; if (current()) { this.working = false; } }
      } } });
  }
  build() {
    Column({ space: 8 }) {
      Button('导出本地备份').width('100%').height(48).onClick(() => this.exportConfirm())
      Button('恢复本地备份').width('100%').height(48).onClick(() => this.importFile())
    }.enabled(!this.working).width('100%').padding(14).backgroundColor(UI.surface).borderRadius(24)
  }
}
