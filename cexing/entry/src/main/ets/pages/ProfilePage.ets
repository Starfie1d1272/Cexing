import { UiText } from '../lib/UiText';
import { NativeTheme as UI } from './NativeTheme';
/*
 * Profile 列表（激活/更新/编辑/重命名/导出/删除）+ 订阅导入（URL/文件/剪贴板，入口在右上 ＋ 半屏菜单）
 * 激活=写入 active 标记；若内核运行中则 PUT /configs 热切换，无需重启 VPN
 */
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ConnectionFailures } from '../lib/ConnectionFailure';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { ProfileImportInput, ProfileImportCandidate } from '../lib/ProfileImportInput';
import { BoundedFileReader } from '../lib/BoundedFileReader';
import { ProfileRecovery } from '../lib/ProfileRecovery';
import { AutoUpdater } from '../lib/AutoUpdater';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { ProfileStore, ProfileMeta, ProfileMetaExt } from '../lib/ProfileStore';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { EffectiveVersions, RegionPlan, RegionPreview } from '../lib/EffectiveVersions';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi } from '../lib/CoreApi';
import { AppRuntime } from '../lib/AppRuntime';
import { Logger } from '../lib/Logger';
import { ProfileEditBus } from './ProfileEditPage';
import { RuleDnsEditorBus } from './RuleDnsEditorPage';
import { ProfileProxyEditorBus } from './ProfileProxyEditorPage';
import { ProfileTemplateBus } from './ProfileTemplatePage';
import { ProfileUpdateBus } from './ProfileUpdatePage';
import { GlobalMergeEditor } from './GlobalMergeEditor';

const TAG = 'profile';

/** 半屏 sheet 内容切换 */
const SHEET_NONE = 0;
const SHEET_IMPORT = 1;
const SHEET_URL = 2;
const SHEET_RENAME = 3;
const SHEET_READY = 4;
const SHEET_PASTE = 5;
const SHEET_REGION = 6;
const SHEET_GLOBAL = 7;
const SHEET_SHARED_FILE = 8;
const REGION_NAMES: string[] = ['香港', '台湾', '日本', '新加坡', '美国', '韩国', '英国', '德国', '未知'];

class RegionSelectOption {
  value: string;
  constructor(value: string) { this.value = value; }
}

export class ProfileDetailBus {
  static current: string = '';
}

@Component
export struct ProfilePage {
  @StorageLink('profileImportRequest') @Watch('acceptExternalImport') importRequest: number = 0;
  @Prop detailFile: string = '';
  @Consume('profileRevision') @Watch('refresh') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @Consume('rootVisible') @Watch('onRootVisible') rootVisible: boolean;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @State profiles: ProfileMeta[] = [];
  @State metas: Record<string, ProfileMetaExt> = {};
  @State importing: boolean = false;
  @State activating: boolean = false;
  @State scanning: boolean = false;
  @State moreActions: boolean = false;
  @State exporting: boolean = false;
  private exportGeneration: number = 0;
  @State recoveryNeeded: boolean = false;
  @State recovering: boolean = false;
  @State updateFeedback: Record<string, string> = {};
  private sharedFileUri: string = '';
  private externalImport: ProfileImportCandidate | null = null;
  private importGeneration: number = 0;
  @State updatingFile: string = '';
  @State refreshing: boolean = false;
  @State showSheet: boolean = false;
  @State sheetMode: number = SHEET_NONE;
  @State inputUrl: string = '';
  @State renameTarget: string = '';
  @State renameInput: string = '';
  @State selectedFile: string = '';
  @State importedFile: string = '';
  @State inputPaste: string = '';
  @State importError: string = '';
  @State regionPreview: RegionPreview | null = null;
  @State regionSelector: string = '';
  @State regionMode: string = 'region';
  @State regionAssignments: Record<string, string> = {};
  @State regionBusy: boolean = false;
  @State regionFromImport: boolean = false;
  private pageVisible: boolean = false;
  private pageGeneration: number = 0;
  private removeIdleListener: (() => void) | null = null;
  private activationRequest: number = 0;

  private openTemplate(file: string): void {
    const paths = this.navStack.getAllPathName();
    if (paths[paths.length - 1] === 'profileTemplate') { return; }
    ProfileTemplateBus.file = file;
    this.navStack.pushPath({ name: 'profileTemplate' });
  }

  private openProxyEditor(file: string): void {
    const paths = this.navStack.getAllPathName();
    if (paths[paths.length - 1] === 'profileProxyEditor') { return; }
    ProfileProxyEditorBus.file = file;
    this.navStack.pushPath({ name: 'profileProxyEditor' });
  }

  private openRuleDns(file: string): void {
    const paths = this.navStack.getAllPathName();
    if (paths[paths.length - 1] === 'ruleDnsEditor') { return; }
    RuleDnsEditorBus.file = file;
    RuleDnsEditorBus.section = 'rules';
    this.navStack.pushPath({ name: 'ruleDnsEditor' });
  }

  private detailOnTop(): boolean {
    const paths = this.navStack.getAllPathName();
    return this.pageVisible && this.detailFile.length > 0 &&
      paths.length > 0 && paths[paths.length - 1] === 'profileDetail' &&
      ProfileDetailBus.current === this.detailFile;
  }

  private samePath(paths: string[]): boolean {
    const current = this.navStack.getAllPathName();
    return paths.length === current.length && paths.every((name: string, index: number) => name === current[index]);
  }

  private activationPageCurrent(request: number, page: number, tab: number, paths: string[]): boolean {
    return this.pageVisible && request === this.activationRequest && page === this.pageGeneration &&
      tab === this.currentVisibleTab && this.samePath(paths) &&
      (this.detailFile.length === 0 || this.detailOnTop());
  }

  // Called only after a definite activation success. #51's transaction result is
  // 'applied' or 'saved'; rejection and unknown outcomes must not enter here.
  private finishActivationNavigation(request: number, page: number, tab: number, paths: string[]): void {
    this.profileRevision++;
    if (!this.activationPageCurrent(request, page, tab, paths) || this.showSheet || ProfileImportInput.hasPending()) { return; }
    this.refresh();
    if (this.detailOnTop()) { this.navStack.pop(); }
    this.tabJump = 0;
  }

  private onTabVisible(): void {
    if (this.detailFile.length === 0 && this.currentVisibleTab !== 1) { this.cancelExport(); this.activationRequest++; this.importGeneration++; }
    if (this.currentVisibleTab === 1) { this.refresh(); this.acceptExternalImport(); }
  }

  private onRootVisible(): void {
    if (this.rootVisible) { this.acceptExternalImport(); }
    if (this.detailFile.length === 0 && !this.rootVisible) { this.cancelExport(); this.activationRequest++; this.importGeneration++; }
  }

  private changed(): void {
    this.profileRevision++;
    this.refresh();
  }

  private finishImport(file: string): void {
    this.releaseExternalImport();
    this.changed();
    this.importedFile = file;
    this.importError = '';
    this.sheetMode = SHEET_READY;
    this.showSheet = true;
  }

  private async refreshRegionPreview(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const plan: RegionPlan = { mode: this.regionMode, selector: this.regionSelector,
      enable: false, assignments: this.regionAssignments };
    this.regionPreview = await ProfileTransactions.previewRegion(context, this.importedFile, plan);
  }

  private async saveRegion(enable: boolean): Promise<void> {
    if (this.regionBusy || this.regionPreview?.eligible !== true ||
      (this.regionMode === 'all' && Object.keys(this.regionPreview.nodes).length < 2)) { return; }
    this.regionBusy = true;
    const activateImported = enable && this.regionFromImport;
    const request = activateImported ? ++this.activationRequest : this.activationRequest;
    const page = this.pageGeneration;
    const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const plan: RegionPlan = { mode: this.regionMode, selector: this.regionSelector,
        enable: enable, assignments: this.regionAssignments };
      const result = await ProfileTransactions.setRegionPlan(context, this.importedFile, plan,
        activateImported);
      if (result !== 'applied' && result !== 'saved') { throw new Error(UiText.get($r('app.string.profile_region_unknown'))); }
      this.showSheet = false;
      this.sheetMode = SHEET_NONE;
      if (activateImported) { this.finishActivationNavigation(request, page, tab, paths); }
      else { this.changed(); }
      const pending = ProfileStore.pendingRegionSelection(context, this.importedFile) !== '';
      this.toast(enable ? (pending ? UiText.get($r('app.string.profile_region_created_later')) : UiText.get($r('app.string.profile_region_selected'))) :
        UiText.get($r('app.string.profile_region_created')));
    } catch (e) { this.importError = this.regionFailure(e as Error); }
    finally { this.regionBusy = false; this.acceptExternalImport(); }
  }

  private regionCanCreate(): boolean {
    if (this.regionBusy || this.regionPreview?.eligible !== true) { return false; }
    return this.regionMode !== 'all' || Object.keys(this.regionPreview.nodes).length >= 2;
  }

  private savedRegion(file: string): RegionPlan | null {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const version = EffectiveVersions.read(context)?.Profiles[file];
      return version !== undefined ? EffectiveVersions.regionPlan(context, version) : null;
    } catch (_) { return null; }
  }

  private async editRegion(file: string): Promise<void> {
    if (this.regionBusy || this.showSheet || this.sheetMode !== SHEET_NONE) { return; }
    const page = this.pageGeneration; const request = ++this.importGeneration;
    const tab = this.currentVisibleTab; const paths = this.navStack.getAllPathName();
    const current = (): boolean => this.pageVisible && page === this.pageGeneration &&
      request === this.importGeneration && tab === this.currentVisibleTab && this.samePath(paths);
    this.regionBusy = true;
    const existing = this.savedRegion(file);
    const mode = existing?.mode ?? 'region';
    const assignments: Record<string, string> = existing?.assignments ?? {};
    let selector = existing?.selector ?? '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (selector === '') {
        const probe: RegionPlan = { mode: 'region', selector: '', enable: false, assignments: {} };
        const first = await ProfileTransactions.previewRegion(context, file, probe);
        if (!current()) { return; }
        selector = first.selectors[0] ?? '';
      }
      const preview = await ProfileTransactions.previewRegion(context, file,
        { mode: mode, selector: selector, enable: false, assignments: assignments });
      if (!current()) { return; }
      this.regionFromImport = false; this.importedFile = file; this.importError = '';
      this.regionMode = mode; this.regionAssignments = assignments; this.regionSelector = selector;
      this.regionPreview = preview; this.sheetMode = SHEET_REGION; this.showSheet = true;
    } catch (_) { if (current()) { this.toast(UiText.get($r('app.string.profile_region_unavailable'))); } }
    finally { this.regionBusy = false; this.acceptExternalImport(); }
  }

  private async toggleRegion(file: string): Promise<void> {
    try {
      const saved = this.savedRegion(file);
      if (saved === null) { return; }
      const context = getContext(this) as common.UIAbilityContext;
      await ProfileTransactions.setRegionPlan(context, file, { mode: saved.mode,
        selector: saved.selector, assignments: saved.assignments,
        enable: !saved.enable, disabled: saved.enable });
      this.changed();
      this.toast(saved.enable ? UiText.get($r('app.string.profile_region_restored')) :
        UiText.get($r('app.string.profile_region_waiting')));
    } catch (e) {
      // A committed disable may still report a failed Controller selection restore.
      this.changed();
      this.toast(this.regionFailure(e as Error));
    }
  }

  private regionFailure(error: Error): string {
    const message = error?.message ?? '';
    if (message === '应用未确认，请重连恢复' || message === '版本发布结果未知，请断开 VPN 后检查') {
      return UiText.get($r('app.string.profile_recover_required'));
    }
    if (message === '配置已保存，地区选择待重连恢复') {
      return UiText.get($r('app.string.profile_region_saved_recovery'));
    }
    if (message === 'REGION_PREVIOUS_UNAVAILABLE' ||
      message === '请先在代理面板选择可用节点，再关闭或切换地区策略' ||
      message === '原手动选项已失效，请先手动选择可用节点再关闭地区策略') {
      return UiText.get($r('app.string.profile_region_manual_repair'));
    }
    return UiText.get($r('app.string.profile_region_failed'));
  }

  private confirmDelete(p: ProfileMeta): void {
    AlertDialog.show({
      title: UiText.get($r('app.string.profile_delete_title')),
      message: p.name,
      primaryButton: { value: UiText.get($r('app.string.profile_keep')), action: () => {} },
      secondaryButton: { value: UiText.get($r('app.string.profile_delete')), fontColor: UI.error, action: async () => {
        const context = getContext(this) as common.UIAbilityContext;
        if (ProfileStore.getActiveFile(context) === p.file &&
          VpnController.status !== VpnStatus.Disconnected) {
          this.toast(UiText.get($r('app.string.profile_disconnect_delete')));
          return;
        }
        try {
          await ProfileTransactions.remove(context, p.file);
          this.changed();
          this.toast(UiText.get($r('app.string.profile_deleted')));
        } catch (_) {
          this.refresh();
          this.toast(UiText.get($r('app.string.profile_delete_failed')));
        }
      } }
    });
  }

  aboutToAppear(): void {
    this.pageVisible = true;
    this.pageGeneration++;
    this.selectedFile = this.detailFile;
    this.removeIdleListener?.();
    this.removeIdleListener = ProfileTransactions.onIdle(() => { this.acceptExternalImport(); });
    this.refresh();
    this.acceptExternalImport();
  }

  aboutToDisappear(): void {
    this.removeIdleListener?.(); this.removeIdleListener = null;
    this.cancelExport();
    this.releaseExternalImport();
    this.pageVisible = false;
    this.importGeneration++;
    this.pageGeneration++;
    this.activationRequest++;
  }

  private refresh(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.profiles = ProfileStore.list(context);
    this.metas = ProfileStore.getMeta(context);
    this.recoveryNeeded = ProfileStore.isApplyUncertain(context);
    const feedback: Record<string, string> = {};
    for (const p of this.profiles) {
      if (!this.isUrlProfile(p.file)) { continue; }
      try {
        const state = ProfileStore.updateState(context, p.file);
        if (state.failedAt > state.succeededAt) { feedback[p.file] = UiText.get($r('app.string.profile_auto_failed')); }
      } catch (_) { feedback[p.file] = UiText.get($r('app.string.profile_update_unavailable')); }
    }
    this.updateFeedback = feedback;
    if (this.selectedFile.length > 0 && !this.profiles.some((p: ProfileMeta) => p.file === this.selectedFile)) {
      this.selectedFile = '';
      if (this.detailOnTop()) { this.navStack.pop(); }
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private metaStamp(file: string): number {
    const m = this.metas[file];
    return m !== undefined ? m.updatedAt : 0;
  }

  private detailKey(p: ProfileMeta): string {
    return `${p.file}|${p.active ? '1' : '0'}|${this.metaStamp(p.file)}|${this.profileRevision}`;
  }

  private isUrlProfile(file: string): boolean {
    const context = getContext(this) as common.UIAbilityContext;
    return ProfileStore.getOrigin(context, file).length > 0;
  }

  /** 流量格式化：GB 一位小数，否则 MB 一位小数 */
  private fmtTraffic(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private daysLeft(expire: number): number {
    return Math.max(0, Math.ceil((expire - Date.now() / 1000) / 86400));
  }

  private subText(p: ProfileMeta): string {
    const m = this.metas[p.file];
    if (m !== undefined && (m.sub.expire > 0 || m.sub.total > 0)) {
      const used = m.sub.upload + m.sub.download;
      if (m.sub.total > 0) {
        if (m.sub.expire > 0) {
          return UiText.get($r('app.string.profile_traffic_expiry'), this.fmtTraffic(used), this.fmtTraffic(m.sub.total), this.daysLeft(m.sub.expire));
        }
        return UiText.get($r('app.string.profile_traffic_total'), this.fmtTraffic(used), this.fmtTraffic(m.sub.total));
      }
      if (m.sub.expire > 0) {
        return UiText.get($r('app.string.profile_traffic_days'), this.fmtTraffic(used), this.daysLeft(m.sub.expire));
      }
      return UiText.get($r('app.string.profile_traffic_used'), this.fmtTraffic(used));
    }
    return `${(p.size / 1024).toFixed(1)} KB · ${new Date(p.mtime * 1000).toLocaleDateString()}`;
  }

  private activationError(error: Error): string {
    const message = error.message ?? '';
    if (/provider|来源资源/i.test(message)) { return UiText.get($r('app.string.profile_provider_missing')); }
    if (/资源|RESOURCE/.test(message)) { return UiText.get($r('app.string.profile_resource_missing')); }
    if (/空节点|没有节点/.test(message)) { return UiText.get($r('app.string.profile_nodes_missing')); }
    if (/引用|reference|循环/i.test(message)) { return UiText.get($r('app.string.profile_invalid_reference')); }
    if (/校验|解析|validate|parse/i.test(message)) { return UiText.get($r('app.string.profile_invalid_config')); }
    if (/未知|未确认/.test(message)) { return UiText.get($r('app.string.profile_apply_unknown')); }
    return UiText.get($r('app.string.profile_enable_failed'));
  }

  private async activateAndConnect(): Promise<void> {
    if (this.activating || this.importing) { return; }
    if (VpnController.status !== VpnStatus.Disconnected && VpnController.status !== VpnStatus.Connected) {
      this.importError = UiText.get($r('app.string.profile_connection_busy')); return;
    }
    if (VpnController.needsStop()) {
      this.importError = UiText.get($r('app.string.profile_connection_unconfirmed')); return;
    }
    const file = this.importedFile;
    if (!this.profiles.some((p: ProfileMeta) => p.file === file)) {
      this.importError = UiText.get($r('app.string.profile_missing')); return;
    }
    const request = ++this.activationRequest;
    const page = this.pageGeneration;
    const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    const context = getContext(this) as common.UIAbilityContext;
    this.activating = true;
    this.importError = '';
    AppRuntime.cancelRestore();
    try {
      const result = await ProfileTransactions.activate(context, file);
      if (result !== 'applied' && result !== 'saved') { throw new Error(UiText.get($r('app.string.profile_apply_unconfirmed'))); }
      this.profileRevision++;
      if (!this.activationPageCurrent(request, page, tab, paths) || !this.showSheet ||
        this.sheetMode !== SHEET_READY) { return; }
      if (VpnController.status === VpnStatus.Disconnected) {
        await ProfileTransactions.ensureActiveSmartPolicy(context);
        if (!this.activationPageCurrent(request, page, tab, paths) || !this.showSheet ||
          this.sheetMode !== SHEET_READY || ProfileStore.getActiveFile(context) !== file) { return; }
        if (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop()) {
          this.importError = UiText.get($r('app.string.profile_connection_changed')); return;
        }
        if (!VpnController.start(context)) {
          this.importError = UiText.get($r('app.string.profile_start_failed')); return;
        }
      }
      this.showSheet = false;
      this.sheetMode = SHEET_NONE;
      this.finishActivationNavigation(request, page, tab, paths);
    } catch (error) {
      if (this.activationPageCurrent(request, page, tab, paths) && this.showSheet) {
        this.importError = this.activationError(error as Error);
      }
    } finally { this.activating = false; this.acceptExternalImport(); }
  }

  private async activate(p: ProfileMeta): Promise<void> {
    if (this.activating) { return; }
    this.activating = true;
    const request = ++this.activationRequest;
    const page = this.pageGeneration;
    const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const result = await ProfileTransactions.activate(context, p.file);
      if (result !== 'applied' && result !== 'saved') { throw new Error(UiText.get($r('app.string.profile_switch_unknown'))); }
      if (this.activationPageCurrent(request, page, tab, paths)) {
        this.toast(result === 'applied' ? UiText.get($r('app.string.profile_switched'), p.name) : UiText.get($r('app.string.profile_selected'), p.name));
      }
      this.finishActivationNavigation(request, page, tab, paths);
    } catch (e) {
      if (this.activationPageCurrent(request, page, tab, paths)) {
        this.refresh();
        this.toast(this.recoveryNeeded ? UiText.get($r('app.string.profile_recover_required')) : this.activationError(e as Error));
      }
    } finally { this.activating = false; this.acceptExternalImport(); }
  }

  private confirmRecovery(): void {
    if (this.recovering) { return; }
    const page = this.pageGeneration;
    const request = ++this.activationRequest;
    const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    const context = getContext(this) as common.UIAbilityContext;
    const session = VpnController.trafficSession();
    const file = ProfileStore.getActiveFile(context);
    let consumed = false;
    AlertDialog.show({ title: UiText.get($r('app.string.profile_reconnect_title')), message: UiText.get($r('app.string.profile_reconnect_risk')),
      primaryButton: { value: UiText.get($r('app.string.profile_cancel')), action: () => { consumed = true; } },
      secondaryButton: { value: UiText.get($r('app.string.profile_reconnect')), action: () => {
        if (consumed || !this.activationPageCurrent(request, page, tab, paths) ||
          VpnController.trafficSession() !== session || ProfileStore.getActiveFile(context) !== file) { return; }
        consumed = true;
        this.recoverProfile(page, request, tab, paths);
      } } });
  }

  private async recoverProfile(page: number, request: number, tab: number, paths: string[]): Promise<void> {
    if (this.recovering || !this.activationPageCurrent(request, page, tab, paths)) { return; }
    const current = (): boolean => this.activationPageCurrent(request, page, tab, paths);
    this.recovering = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const accepted = await ProfileRecovery.reconnect(context, current);
      if (!current()) { return; }
      this.refresh();
      if (accepted) { this.finishActivationNavigation(request, page, tab, paths); }
      else { this.toast(UiText.get($r('app.string.profile_not_started'))); }
    } catch (_) {
      if (current()) { this.refresh(); this.toast(UiText.get($r('app.string.profile_recovery_failed'))); }
    } finally { this.recovering = false; this.acceptExternalImport(); }
  }

  private async retryAutomatic(p: ProfileMeta): Promise<void> {
    if (this.updatingFile.length > 0 || !p.active) { return; }
    const page = this.pageGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    const paths = this.navStack.getAllPathName();
    this.updatingFile = p.file;
    try {
      const before = ProfileStore.updateState(context, p.file);
      await AutoUpdater.retry(context);
      if (!this.pageVisible || page !== this.pageGeneration || !this.samePath(paths) ||
        ProfileStore.getActiveFile(context) !== p.file) { return; }
      this.changed();
      const after = ProfileStore.updateState(context, p.file);
      if (after.id === before.id && after.succeededAt > before.succeededAt && after.failedAt === 0) {
        this.toast(UiText.get($r('app.string.profile_updated')));
      } else { this.toast(UiText.get($r('app.string.profile_auto_retry_failed'))); }
    } catch (_) {
      if (this.pageVisible && page === this.pageGeneration && this.samePath(paths)) {
        this.refresh(); this.toast(UiText.get($r('app.string.profile_update_incomplete')));
      }
    } finally { this.updatingFile = ''; this.acceptExternalImport(); }
  }

  private async updateProfile(p: ProfileMeta): Promise<void> { await this.updateFile(p.file); }

  private async updateFile(file: string): Promise<void> {
    if (this.updatingFile.length > 0) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const page = this.pageGeneration; const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    const current = (): boolean => this.pageVisible && page === this.pageGeneration &&
      tab === this.currentVisibleTab && this.samePath(paths) &&
      (this.detailFile.length === 0 ? this.rootVisible : this.detailOnTop());
    this.updatingFile = file;
    try {
      const version = EffectiveVersions.read(context)?.Profiles[file];
      const intent = version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
      if (intent?.disabled !== true && intent?.template !== undefined && intent.template.templateId !== 'original') {
        const ticket = ProfileTransactions.editTicket(context, file);
        const downloaded = await ProfileStore.downloadFromOrigin(context, file);
        if (!current()) { return; }
        if (this.showSheet) { this.toast(context.resourceManager.getStringByNameSync('profile_update_close_editor')); return; }
        if (JSON.stringify(ticket) !== JSON.stringify(ProfileTransactions.editTicket(context, file))) {
          this.toast('配置已变化，请重新更新'); return;
        }
        ProfileUpdateBus.request = { file: file, ticket: ticket,
          source: { original: downloaded.content, metadata: downloaded.meta } };
        try { this.navStack.pushPath({ name: 'profileTemplateUpdate' }); }
        catch (_) { ProfileUpdateBus.request = null; throw new Error('UPDATE_ROUTE_FAILED'); }
        return;
      }
      const result = await ProfileTransactions.update(context, file);
      if (current()) {
        this.toast(result === 'applied' ? '已更新并应用' : '已更新，启用或启动后生效'); this.changed();
      }
    } catch (_) {
      if (current()) {
        this.refresh(); this.toast(this.recoveryNeeded ? '应用未确认，请重连恢复' : '更新失败，请检查网络后重试');
      }
    } finally {
      this.updatingFile = '';
      if (this.samePath(paths)) { this.acceptExternalImport(); }
    }
  }

  private async copyOrigin(context: common.UIAbilityContext, file: string): Promise<void> {
    const origin = ProfileStore.getOrigin(context, file);
    if (origin.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, origin);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast(UiText.get($r('app.string.profile_url_copied')));
    } catch (e) {
      Logger.warn(TAG, `copyOrigin: ${JSON.stringify(e)}`);
      this.toast(UiText.get($r('app.string.profile_copy_failed')));
    }
  }

  private async doRename(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const target = this.renameTarget;
    const input = this.renameInput.trim();
    this.showSheet = false;
    this.sheetMode = SHEET_NONE;
    this.renameTarget = '';
    this.renameInput = '';
    if (target.length === 0 || input.length === 0) {
      return;
    }
    try {
      const renamed = await ProfileTransactions.rename(context, target, input);
      if (this.selectedFile === target) { this.selectedFile = renamed; }
      this.toast(UiText.get($r('app.string.profile_renamed'), renamed.replace(/\.(yaml|yml)$/, '')));
      this.changed();
    } catch (e) {
      this.toast(UiText.get($r('app.string.profile_rename_failed')));
    } finally { this.acceptExternalImport(); }
  }

  private cancelExport(): void { this.exportGeneration++; this.exporting = false; }

  private exportCurrent(page: number, request: number): boolean {
    return this.pageVisible && page === this.pageGeneration && request === this.exportGeneration &&
      (this.detailFile.length > 0 ? this.detailOnTop() : this.rootVisible && this.currentVisibleTab === 1);
  }

  private confirmExport(profile: ProfileMeta): void {
    if (this.exporting || !this.pageVisible) { return; }
    const page = this.pageGeneration;
    const request = ++this.exportGeneration;
    this.exporting = true;
    let available = true;
    const cancel = (): void => {
      if (!available) { return; }
      available = false;
      if (request === this.exportGeneration) { this.cancelExport(); this.acceptExternalImport(); }
    };
    AlertDialog.show({ title: UiText.get($r('app.string.profile_export')),
      message: UiText.get($r('app.string.profile_export_risk')),
      primaryButton: { value: UiText.get($r('app.string.profile_cancel')), action: cancel }, cancel: cancel,
      secondaryButton: { value: UiText.get($r('app.string.profile_export_choose')), action: () => {
        if (!available || !this.exportCurrent(page, request)) { return; }
        available = false;
        this.exportProfile(profile, page, request);
      } } });
  }

  private async exportProfile(profile: ProfileMeta, page: number, request: number): Promise<void> {
    const current = (): boolean => this.exportCurrent(page, request);
    try {
      if (!current()) { return; }
      const context = getContext(this) as common.UIAbilityContext;
      const content = ProfileStore.getProfileContent(context, profile.file);
      if (content === null) { this.toast(UiText.get($r('app.string.profile_read_failed'))); return; }
      const docPicker = new picker.DocumentViewPicker(context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`${profile.name}.yaml`];
      options.fileSuffixChoices = [UiText.get($r('app.string.profile_yaml_type'))];
      const uris = await docPicker.save(options);
      if (!current() || uris.length === 0) { return; }
      const bytes = new util.TextEncoder().encodeInto(content);
      await BoundedFileReader.write(uris[0], bytes.buffer as ArrayBuffer, current);
      if (current()) { this.toast(UiText.get($r('app.string.profile_exported'))); }
    } catch (error) {
      Logger.warn(TAG, 'profile-export ' + JSON.stringify(ConnectionFailures.classify('assets', (error as Error).message ?? '')));
      if (current()) { this.toast(UiText.get($r('app.string.profile_export_failed'))); }
    } finally {
      if (request === this.exportGeneration) { this.exporting = false; this.acceptExternalImport(); }
    }
  }

  private releaseExternalImport(): void {
    ProfileImportInput.release(this.externalImport);
    this.externalImport = null;
  }

  private cancelImport(): void {
    this.importGeneration++;
    this.activationRequest++;
    this.releaseExternalImport();
    this.inputUrl = '';
    this.sharedFileUri = '';
    this.showSheet = false;
    this.sheetMode = SHEET_NONE;
    this.acceptExternalImport();
  }

  private acceptExternalImport(): void {
    if (!this.pageVisible || this.detailFile.length > 0 || !this.rootVisible ||
      this.currentVisibleTab !== 1 || this.importing || this.exporting || this.activating || this.scanning ||
      this.showSheet || this.sheetMode !== SHEET_NONE || this.regionBusy || this.recovering ||
      this.updatingFile.length > 0 || this.refreshing || ProfileTransactions.isBusy()) { return; }
    if ((this.navStack.getAllPathName?.() ?? []).length > 0) { return; }
    const candidate = ProfileImportInput.take();
    if (candidate === null) { return; }
    this.externalImport = candidate;
    this.importGeneration++;
    this.importError = '';
    if (candidate.kind === 'url') {
      this.inputUrl = candidate.value;
      this.sheetMode = SHEET_URL;
    } else {
      this.sharedFileUri = candidate.value;
      this.sheetMode = SHEET_SHARED_FILE;
    }
    this.showSheet = true;
  }

  private scanInput(): void {
    if (this.scanning || this.importing || this.activating) { return; }
    if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
      this.toast(UiText.get($r('app.string.profile_scan_unsupported'))); return;
    }
    const page = this.pageGeneration;
    const tab = this.currentVisibleTab;
    const paths = this.navStack.getAllPathName();
    const request = ++this.importGeneration;
    this.scanning = true;
    this.showSheet = false;
    this.sheetMode = SHEET_NONE;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: true
      }, (error, result) => {
        try {
        if (!this.pageVisible || page !== this.pageGeneration || request !== this.importGeneration ||
          tab !== this.currentVisibleTab || !this.samePath(paths)) { return; }
        if (error) {
          // Cancellation/denied camera does not start another action. Album and
          // ordinary import remain available on the next user request.
          return;
        }
        const candidate = ProfileImportInput.parseText(result.originalValue);
        if (candidate === null) { this.toast(UiText.get($r('app.string.profile_scan_no_link'))); return; }
        this.inputUrl = candidate.value;
        this.importError = '';
        this.sheetMode = SHEET_URL;
        this.showSheet = true;
        } finally { this.scanning = false; this.acceptExternalImport(); }
      });
    } catch (_) {
      this.scanning = false;
      this.toast(UiText.get($r('app.string.profile_scan_failed')));
      this.acceptExternalImport();
    }
  }

  private async importUrl(): Promise<void> {
    const url = this.inputUrl.trim();
    if (url.length === 0) {
      return;
    }
    if (this.importing) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const existing = this.profiles.find((p: ProfileMeta) => ProfileStore.getOrigin(context, p.file) === url);
    if (existing !== undefined) {
      this.finishImport(existing.file); return;
    }
    this.importError = '';
    this.importing = true;
    const page = this.pageGeneration;
    const request = ++this.importGeneration;
    try {
      const file = await ProfileStore.importFromUrl(context, url);
      if (!this.pageVisible || page !== this.pageGeneration || request !== this.importGeneration) { return; }
      this.inputUrl = '';
      this.finishImport(file);
    } catch (_) {
      if (this.pageVisible && page === this.pageGeneration && request === this.importGeneration) {
        this.importError = UiText.get($r('app.string.profile_import_failed'));
      }
    } finally {
      this.importing = false;
      this.acceptExternalImport();
    }
  }

  private async importFile(sharedUri: string = ''): Promise<void> {
    if (this.importing) { return; }
    this.importing = true;
    const page = this.pageGeneration;
    const request = ++this.importGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      let uris: string[] = [sharedUri];
      if (sharedUri.length === 0) {
        const docPicker = new picker.DocumentViewPicker(context);
        uris = await docPicker.select({
          maxSelectNumber: 1,
          selectMode: picker.DocumentSelectMode.FILE,
          fileSuffixFilters: ['.yaml', '.yml']
        });
      }
      if (!uris || uris.length === 0) {
        return;
      }
      if (!this.pageVisible || page !== this.pageGeneration || request !== this.importGeneration) { return; }
      const uri = uris[0];
      const current = (): boolean => this.pageVisible && page === this.pageGeneration &&
        request === this.importGeneration;
      const content = await BoundedFileReader.yaml(uri, current);
      if (!current()) { return; }
      const seg = uri.split('/').pop() ?? `file_${Date.now()}`;
      const name = decodeURIComponent(seg).replace(/\.(yaml|yml)$/i, '');
      const file = ProfileStore.importContent(context, name, content);
      this.finishImport(file);
    } catch (e) {
      if (this.pageVisible && page === this.pageGeneration && request === this.importGeneration) {
        this.toast(UiText.get($r('app.string.profile_file_failed')));
      }
    } finally { this.importing = false; this.acceptExternalImport(); }
  }

  private async importClipboard(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    let text = '';
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      text = data.getPrimaryText().trim();
    } catch (e) {
      Logger.warn(TAG, `clipboard read failed: ${JSON.stringify(e)}`);
      // 普通应用无 READ_PASTEBOARD（system_basic 级权限），跨应用内容读不到：
      // 回退到手动粘贴表单，保留 URL 与 YAML 导入
      this.toast(UiText.get($r('app.string.profile_paste_manually')));
      this.sheetMode = SHEET_PASTE;
      this.showSheet = true;
      return;
    }
    if (text.length === 0) {
      this.sheetMode = SHEET_PASTE;
      this.showSheet = true;
      return;
    }
    try {
      if (text.includes('proxies:') || text.includes('proxy-groups:') || text.includes('proxy-providers:')) {
        const name = `clipboard_${Date.now()}`;
        const file = ProfileStore.importContent(context, name, text);
        this.finishImport(file);
      } else {
        const file = await ProfileStore.importFromUrl(context, text);
        this.finishImport(file);
      }
      this.changed();
    } catch (e) {
      this.importError = UiText.get($r('app.string.profile_import_failed'));
      this.sheetMode = SHEET_PASTE;
      this.showSheet = true;
    }
  }

  /** 下拉刷新：激活配置为 URL 源时重新下载并热重载 */
  private async onPullRefresh(): Promise<void> {
    if (this.refreshing) { return; }
    this.refreshing = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const active = ProfileStore.getActiveFile(context);
      if (active.length > 0 && this.isUrlProfile(active)) {
        await this.updateFile(active);
      }
      this.refresh();
    } finally {
      this.refreshing = false;
      this.acceptExternalImport();
    }
  }

  private regionNames(): string[] {
    return this.regionPreview?.regions ?? REGION_NAMES;
  }

  private regionLabel(name: string): string {
    // Region keys are persisted canonical data. Only their display labels are localized.
    if (name === '香港') { return UiText.get($r('app.string.profile_region_hk')); }
    if (name === '台湾') { return UiText.get($r('app.string.profile_region_tw')); }
    if (name === '日本') { return UiText.get($r('app.string.profile_region_jp')); }
    if (name === '新加坡') { return UiText.get($r('app.string.profile_region_sg')); }
    if (name === '美国') { return UiText.get($r('app.string.profile_region_us')); }
    if (name === '韩国') { return UiText.get($r('app.string.profile_region_kr')); }
    if (name === '英国') { return UiText.get($r('app.string.profile_region_uk')); }
    if (name === '德国') { return UiText.get($r('app.string.profile_region_de')); }
    return name === '未知' ? UiText.get($r('app.string.profile_other_region')) : name;
  }

  @Builder
  ProfileRow(p: ProfileMeta) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.doc')).fontSize(20).fontColor([UI.muted])
        Column({ space: 6 }) {
          Text(p.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(p.active ? UiText.get($r('app.string.profile_current')) : (this.isUrlProfile(p.file) ? UiText.get($r('app.string.profile_url_type')) : UiText.get($r('app.string.profile_local_type'))))
            .fontSize(13).fontColor(UI.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).accessibilityLevel('no').fontSize(16).fontColor([UI.muted])
      }.padding(18).width('100%')
    }.accessibilityText(p.name).accessibilitySelected(p.active).width('100%').constraintSize({ minHeight: 84 }).backgroundColor(UI.surface).borderRadius(24)
      .onClick(() => {
        ProfileDetailBus.current = p.file;
        this.navStack.pushPath({ name: 'profileDetail' });
      })
  }

  @Builder
  DetailAction(label: string, onTap: () => void, enabled: boolean = true) {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(label).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).accessibilityLevel('no').fontSize(16).fontColor([UI.muted])
      }.padding(18).width('100%')
    }.width('100%').constraintSize({ minHeight: 72 }).borderRadius(24).backgroundColor(UI.surface).fontColor(UI.ink)
      .enabled(enabled).accessibilityText(label).onClick(onTap)
  }

  @Builder
  ProfileDetail(p: ProfileMeta) {
    Column({ space: 16 }) {
      Scroll() {
        Column({ space: 16 }) {
          Text(p.active ? UiText.get($r('app.string.profile_current')) : UiText.get($r('app.string.profile_details'))).fontSize(13).fontColor(UI.muted).width('100%')
          Text(p.name).fontSize(28).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
          Text(this.isUrlProfile(p.file) ? UiText.get($r('app.string.profile_url_type')) : UiText.get($r('app.string.profile_local_type'))).fontSize(14).fontColor(UI.muted).width('100%')
          Text(this.subText(p)).fontSize(14).fontColor(UI.muted).width('100%')
          if (this.updateFeedback[p.file] !== undefined) {
            Text(this.updateFeedback[p.file]).fontSize(14).fontColor(UI.error).width('100%')
            if (p.active) {
              Button(this.updatingFile === p.file ? UiText.get($r('app.string.profile_updating')) : UiText.get($r('app.string.profile_retry_auto'))).width('100%').constraintSize({ minHeight: 48 })
                .enabled(this.updatingFile.length === 0).onClick(() => { this.retryAutomatic(p); })
            }
          }
          this.DetailAction(UiText.get($r('app.string.profile_templates')), () => { this.openTemplate(p.file); })
          this.DetailAction(UiText.get($r('app.string.profile_nodes_groups')), () => { this.openProxyEditor(p.file); })
          this.DetailAction(UiText.get($r('app.string.profile_rules_dns')), () => {
            this.openRuleDns(p.file);
          })
          if (!p.active) {
            Button(UiText.get($r('app.string.profile_enable'))).width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent)
              .onClick(() => this.activate(p))
          }
          if (this.isUrlProfile(p.file)) {
            Button(this.updatingFile === p.file ? UiText.get($r('app.string.profile_updating')) : UiText.get($r('app.string.profile_update')))
              .width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.updatingFile.length === 0)
              .onClick(() => this.updateProfile(p))
          }
          Button(this.moreActions ? UiText.get($r('app.string.profile_less')) : UiText.get($r('app.string.profile_more')))
            .constraintSize({ minHeight: 48 }).width('100%')
            .accessibilityDescription(this.moreActions ? UiText.get($r('app.string.profile_expanded')) : UiText.get($r('app.string.profile_collapsed')))
            .onClick(() => { this.moreActions = !this.moreActions; })
          if (this.moreActions) {
          this.DetailAction(UiText.get($r('app.string.profile_original')), () => {
            ProfileEditBus.current = p.file;
            this.navStack.pushPath({ name: 'profileEdit' });
          })
          this.DetailAction(UiText.get($r('app.string.profile_merge')), () => {
            ProfileEditBus.current = p.file;
            this.navStack.pushPath({ name: 'profileMerge' });
          })
          this.DetailAction(UiText.get($r('app.string.profile_generated')), () => {
            ProfileEditBus.current = p.file;
            this.navStack.pushPath({ name: 'profileGenerated' });
          })
          if (this.savedRegion(p.file) !== null) {
            this.DetailAction(UiText.get($r('app.string.profile_region_edit')), () => { this.editRegion(p.file); })
            this.DetailAction(this.savedRegion(p.file)?.enable ? UiText.get($r('app.string.profile_region_disable')) :
              UiText.get($r('app.string.profile_region_enable')), () => { this.toggleRegion(p.file); })
          } else {
            this.DetailAction(UiText.get($r('app.string.profile_region_create')), () => { this.editRegion(p.file); })
          }
          this.DetailAction(UiText.get($r('app.string.profile_rename')), () => {
            this.renameTarget = p.file;
            this.renameInput = p.name;
            this.sheetMode = SHEET_RENAME;
            this.showSheet = true;
          })
          this.DetailAction(this.exporting ? UiText.get($r('app.string.profile_exporting')) : UiText.get($r('app.string.profile_export')), () => { this.confirmExport(p); }, !this.exporting)
            if (this.isUrlProfile(p.file)) {
            this.DetailAction(UiText.get($r('app.string.profile_copy_url')), () => {
              this.copyOrigin(getContext(this) as common.UIAbilityContext, p.file);
            })
            }
          Button(UiText.get($r('app.string.profile_remove'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent)
            .fontColor(UI.error).onClick(() => this.confirmDelete(p))
          }
        }.width('100%').padding({ bottom: 12 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }

  @Builder
  ImportEntry(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon).accessibilityLevel('no')
        .fontSize(20)
        .fontColor([UI.muted])
      Text(label)
        .fontSize(15)
        .fontColor(UI.ink)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).accessibilityLevel('no')
        .fontSize(16)
        .fontColor([UI.muted])
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ top: 14, bottom: 14, left: 20, right: 20 })
    .stateStyles({
      pressed: { .backgroundColor(UI.soft) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  ImportMenuSheet() {
    Column({ space: 0 }) {
      Text(UiText.get($r('app.string.profile_add')))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
        .width('100%')
        .padding({ top: 20, left: 20, right: 20, bottom: 8 })
      this.ImportEntry($r('sys.symbol.qrcode'), UiText.get($r('app.string.profile_scan')), () => { this.scanInput(); })
      this.ImportEntry($r('sys.symbol.link'), UiText.get($r('app.string.profile_link')), () => {
        this.sheetMode = SHEET_URL;
      })
      this.ImportEntry($r('sys.symbol.folder'), UiText.get($r('app.string.profile_file')), () => {
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
        this.importFile();
      })
      this.ImportEntry($r('sys.symbol.text_clipboard'), UiText.get($r('app.string.profile_clipboard')), () => {
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
        this.importClipboard();
      })
      Row()
        .height(16)
    }
    .width('100%')
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  @Builder
  UrlImportDialog() {
    Column({ space: 14 }) {
      Text(UiText.get($r('app.string.profile_import_url')))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: 'https://example.com/sub.yaml', text: this.inputUrl }).accessibilityText(UiText.get($r('app.string.profile_link')))
        .constraintSize({ minHeight: 48 })
        .width('100%')
        .onChange((v: string) => {
          this.inputUrl = v;
        })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(UI.error).width('100%')
      }
      Row({ space: 12 }) {
        Button(UiText.get($r('app.string.profile_cancel')))
          .constraintSize({ minHeight: 48 })
          .enabled(!this.importing)
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => { this.cancelImport(); })
        Button(this.importing ? UiText.get($r('app.string.profile_importing')) : UiText.get($r('app.string.profile_import')))
          .constraintSize({ minHeight: 48 })
          .backgroundColor(UI.action).fontColor(UI.onAccent)
          .layoutWeight(1)
          .enabled(!this.importing)
          .onClick(() => this.importUrl())
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  @Builder
  RenameSheet() {
    Column({ space: 14 }) {
      Text(UiText.get($r('app.string.profile_rename_title')))
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: UiText.get($r('app.string.profile_new_name')), text: this.renameInput })
        .constraintSize({ minHeight: 48 })
        .width('100%')
        .onChange((v: string) => {
          this.renameInput = v;
        })
      Row({ space: 12 }) {
        Button(UiText.get($r('app.string.profile_cancel')))
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.showSheet = false;
            this.sheetMode = SHEET_NONE;
            this.renameTarget = '';
            this.renameInput = '';
          })
        Button(UiText.get($r('app.string.profile_confirm')))
          .constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
          .layoutWeight(1)
          .onClick(() => {
            this.doRename();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  private async importPaste(): Promise<void> {
    if (this.importing || this.inputPaste.trim().length === 0) { return; }
    this.importing = true;
    this.importError = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const text = this.inputPaste.trim();
      const file = /^https?:\/\//.test(text) ? await ProfileStore.importFromUrl(context, text) :
        ProfileStore.importContent(context, `clipboard_${Date.now()}`, text);
      this.inputPaste = '';
      this.finishImport(file);
    } catch (e) {
      this.importError = UiText.get($r('app.string.profile_import_failed'));
    } finally {
      this.importing = false;
    }
  }

  @Builder
  PasteSheet() {
    Column({ space: 16 }) {
      Text(UiText.get($r('app.string.profile_paste_title'))).fontSize(20).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      TextArea({ text: this.inputPaste, placeholder: UiText.get($r('app.string.profile_paste_placeholder')) }).height(160)
        .fontSize(14).onChange((value: string) => { this.inputPaste = value; })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(UI.error)
      }
      Button(this.importing ? UiText.get($r('app.string.profile_importing')) : UiText.get($r('app.string.profile_import'))).width('100%').constraintSize({ minHeight: 56 })
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.importing).onClick(() => this.importPaste())
    }.padding(24).width('100%')
  }

  @Builder
  SharedFileSheet() {
    Column({ space: 16 }) {
      Text(UiText.get($r('app.string.profile_import_file_title'))).fontSize(21).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Button(this.importing ? UiText.get($r('app.string.profile_importing')) : UiText.get($r('app.string.profile_import'))).width('100%').constraintSize({ minHeight: 48 })
        .enabled(!this.importing).onClick(() => { this.importFile(this.sharedFileUri); })
      Button(UiText.get($r('app.string.profile_cancel'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
        .onClick(() => {
          this.cancelImport();
        })
    }.width('100%').padding(24)
  }

  @Builder
  ReadySheet() {
    Column({ space: 20 }) {
      Text(UiText.get($r('app.string.profile_imported'))).fontSize(24).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text(this.importedFile.replace(/\.(yaml|yml)$/, '')).fontSize(16).fontColor(UI.muted)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(UI.error).width('100%')
      }
      Button(this.activating ? UiText.get($r('app.string.profile_enabling')) : UiText.get($r('app.string.profile_enable_connect')))
        .width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(!this.activating).onClick(() => { this.activateAndConnect(); })
      Button(UiText.get($r('app.string.profile_enable_later'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.accentText)
        .onClick(() => {
          this.activationRequest++;
          this.showSheet = false; this.sheetMode = SHEET_NONE;
        })
    }.padding(24).width('100%')
  }

  @Builder
  RegionSheet() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.profile_region_title'))).fontSize(21).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text(UiText.get($r('app.string.profile_region_risk')))
        .fontSize(13).fontColor(UI.muted)
      if (this.regionPreview !== null) {
        Select(this.regionPreview.selectors.map((name: string) => new RegionSelectOption(name)))
          .selected(this.regionPreview.selectors.indexOf(this.regionSelector))
          .value(this.regionSelector).width('100%')
          .onSelect(async (index: number) => {
            this.regionSelector = this.regionPreview?.selectors[index] ?? '';
            this.regionAssignments = {};
            try { await this.refreshRegionPreview(); } catch (_) { this.importError = UiText.get($r('app.string.profile_preview_failed')); }
          })
        Row({ space: 8 }) {
          Button(UiText.get($r('app.string.profile_by_region'))).backgroundColor(this.regionMode === 'region' ? UI.action : UI.soft)
            .fontColor(this.regionMode === 'region' ? UI.onAccent : UI.accentText)
            .onClick(() => { this.regionMode = 'region'; })
          Button(UiText.get($r('app.string.profile_all_nodes'))).backgroundColor(this.regionMode === 'all' ? UI.action : UI.soft)
            .fontColor(this.regionMode === 'all' ? UI.onAccent : UI.accentText)
            .onClick(() => { this.regionMode = 'all'; })
          Button(UiText.get($r('app.string.profile_unchanged'))).backgroundColor(UI.soft).fontColor(UI.accentText)
            .onClick(() => {
          this.activationRequest++;
          this.showSheet = false; this.sheetMode = SHEET_NONE;
        })
        }
        if (this.regionPreview.providerPending) {
          Text(UiText.get($r('app.string.profile_provider_wait')))
            .fontSize(13).fontColor(UI.error)
          Button(UiText.get($r('app.string.profile_refresh_preview'))).backgroundColor(UI.soft).fontColor(UI.accentText)
            .onClick(async () => {
              try { await this.refreshRegionPreview(); this.importError = ''; }
              catch (_) { this.importError = UiText.get($r('app.string.profile_provider_pending')); }
            })
        }
        Text(UiText.get($r('app.string.profile_region_count'), Object.keys(this.regionPreview.nodes).length, this.regionPreview.unknown))
          .fontSize(14).fontColor(UI.ink)
        if (this.regionMode === 'region') {
          Text(this.regionNames().filter((name: string) => (this.regionPreview?.counts[name] ?? 0) > 0)
            .map((name: string) => `${this.regionLabel(name)} ${this.regionPreview?.counts[name] ?? 0}`).join(' · '))
            .fontSize(13).fontColor(UI.muted)
        }
        Scroll() {
          Column({ space: 8 }) {
            ForEach(Object.keys(this.regionPreview.nodes), (node: string) => {
              Row({ space: 8 }) {
                Text(node).fontSize(12).fontColor(UI.ink).layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Select(this.regionNames().map((name: string) => new RegionSelectOption(this.regionLabel(name))))
                  .selected(this.regionNames().indexOf(this.regionPreview?.nodes[node] ?? '未知'))
                  .value(this.regionLabel(this.regionPreview?.nodes[node] ?? '未知')).width(104)
                  .accessibilityText(UiText.get($r('app.string.profile_node_region'), node))
                  .onSelect(async (index: number) => {
                    const next: Record<string, string> = {};
                    for (const key of Object.keys(this.regionAssignments)) {
                      next[key] = this.regionAssignments[key];
                    }
                    next[node] = this.regionNames()[index];
                    this.regionAssignments = next;
                    try { await this.refreshRegionPreview(); } catch (_) { this.importError = UiText.get($r('app.string.profile_preview_failed')); }
                  })
              }
            }, (node: string) => node)
          }
        }.height(160)
      }
      if (this.importError.length > 0) { Text(this.importError).fontSize(13).fontColor(UI.error) }
      Button(UiText.get($r('app.string.profile_create_enable'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(this.regionCanCreate())
        .onClick(() => { this.saveRegion(true); })
      Button(UiText.get($r('app.string.profile_create_only'))).width('100%').constraintSize({ minHeight: 44 }).backgroundColor(UI.soft).fontColor(UI.accentText)
        .enabled(this.regionCanCreate())
        .onClick(() => { this.saveRegion(false); })
    }.padding(20).width('100%')
  }

  @Builder
  MainSheet() {
    if (this.sheetMode === SHEET_IMPORT) { this.ImportMenuSheet() }
    else if (this.sheetMode === SHEET_URL) { this.UrlImportDialog() }
    else if (this.sheetMode === SHEET_RENAME) { this.RenameSheet() }
    else if (this.sheetMode === SHEET_SHARED_FILE) { this.SharedFileSheet() }
    else if (this.sheetMode === SHEET_READY) { this.ReadySheet() }
    else if (this.sheetMode === SHEET_PASTE) { this.PasteSheet() }
    else if (this.sheetMode === SHEET_REGION) { this.RegionSheet() }
    else if (this.sheetMode === SHEET_GLOBAL) {
      GlobalMergeEditor({ onClose: () => { this.showSheet = false; } })
    }
  }

  build() {
    Column({ space: 16 }) {
      if (this.recoveryNeeded) {
        Text(UiText.get($r('app.string.profile_uncertain'))).fontSize(14).fontColor(UI.error).width('100%')
        Button(this.recovering ? UiText.get($r('app.string.profile_recovering')) : UiText.get($r('app.string.profile_recover'))).width('100%').constraintSize({ minHeight: 48 })
          .enabled(!this.recovering).onClick(() => { this.confirmRecovery(); })
      }
      if (this.selectedFile.length > 0) {
        ForEach(this.profiles.filter((p: ProfileMeta) => p.file === this.selectedFile), (p: ProfileMeta) => {
          this.ProfileDetail(p)
        }, (p: ProfileMeta) => this.detailKey(p))
      } else {
        Row() {
          Text(UiText.get($r('app.string.profile_tab'))).fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink).layoutWeight(1)
          Button(UiText.get($r('app.string.profile_add_short'))).constraintSize({ minHeight: 48 }).fontSize(14).backgroundColor(UI.soft).fontColor(UI.accentText)
            .onClick(() => { this.sheetMode = SHEET_IMPORT; this.importError = ''; this.showSheet = true; })
        }.width('100%').margin({ top: 16, bottom: 12 })
        Button() {
          Column({ space: 4 }) {
            Text(UiText.get($r('app.string.profile_global'))).fontSize(16).fontColor(UI.ink)
          }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 20, right: 20 })
        }.width('100%').constraintSize({ minHeight: 64 }).backgroundColor(UI.soft).borderRadius(16)
          .onClick(() => { this.sheetMode = SHEET_GLOBAL; this.showSheet = true; })
        if (this.profiles.length === 0) {
          Column({ space: 20 }) {
            Text(UiText.get($r('app.string.profile_import_title'))).fontSize(32).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
            this.ImportEntry($r('sys.symbol.qrcode'), UiText.get($r('app.string.profile_scan')), () => { this.scanInput(); })
            this.ImportEntry($r('sys.symbol.link'), UiText.get($r('app.string.profile_link')), () => {
              this.sheetMode = SHEET_URL; this.showSheet = true;
            })
            this.ImportEntry($r('sys.symbol.folder'), UiText.get($r('app.string.profile_file')), () => { this.importFile(); })
            this.ImportEntry($r('sys.symbol.text_clipboard'), UiText.get($r('app.string.profile_clipboard')), () => { this.importClipboard(); })
          }.padding(20).width('100%').backgroundColor(UI.surface).borderRadius(28)
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            List({ space: 12 }) {
              ForEach(this.profiles, (p: ProfileMeta) => {
                ListItem() { this.ProfileRow(p) }
              }, (p: ProfileMeta) => p.file + '|' + (p.active ? '1' : '0') + '|' + this.metaStamp(p.file))
            }.width('100%').scrollBar(BarState.Off)
          }.onRefreshing(() => { this.onPullRefresh(); }).width('100%').layoutWeight(1)
        }
      }
    }.width('100%').height('100%').padding({ left: 24, right: 24, bottom: 12 })
      .backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
      .bindSheet($$this.showSheet, this.MainSheet(), { height: this.sheetMode === SHEET_GLOBAL ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        onDisappear: () => {
          if (!this.showSheet) {
            this.sheetMode = SHEET_NONE;
            this.releaseExternalImport();
            this.acceptExternalImport();
          }
        },
        shouldDismiss: (dismiss: SheetDismiss) => {
          if (this.sheetMode !== SHEET_GLOBAL && !this.importing && !this.activating && !this.regionBusy && !ProfileTransactions.isBusy()) {
            this.importGeneration++; this.activationRequest++;
            dismiss.dismiss();
          }
        } })
  }
}
