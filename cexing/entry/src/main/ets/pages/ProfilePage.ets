import { NativeTheme as UI } from './NativeTheme';
/*
 * Profile 列表（激活/更新/编辑/重命名/导出/删除）+ 订阅导入（URL/文件/剪贴板，入口在右上 ＋ 半屏菜单）
 * 激活=写入 active 标记；若内核运行中则 PUT /configs 热切换，无需重启 VPN
 */
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { ProfileStore, ProfileMeta, ProfileMetaExt } from '../lib/ProfileStore';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { EffectiveVersions, RegionPlan, RegionPreview } from '../lib/EffectiveVersions';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi } from '../lib/CoreApi';
import { Logger } from '../lib/Logger';
import { ProfileEditBus } from './ProfileEditPage';

const TAG = 'profile';

/** 半屏 sheet 内容切换 */
const SHEET_NONE = 0;
const SHEET_IMPORT = 1;
const SHEET_URL = 2;
const SHEET_RENAME = 3;
const SHEET_READY = 4;
const SHEET_PASTE = 5;
const SHEET_REGION = 6;
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
  @Prop detailFile: string = '';
  @Consume('profileRevision') @Watch('refresh') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @State profiles: ProfileMeta[] = [];
  @State metas: Record<string, ProfileMetaExt> = {};
  @State importing: boolean = false;
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

  private onTabVisible(): void {
    if (this.currentVisibleTab === 1) { this.refresh(); }
  }

  private changed(): void {
    this.profileRevision++;
    this.refresh();
  }

  private finishImport(file: string): void {
    this.changed();
    this.importedFile = file;
    this.importError = '';
    this.prepareRegionOffer(file);
  }

  private async prepareRegionOffer(file: string): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const probe: RegionPlan = { mode: 'region', selector: '', enable: false, assignments: {} };
      const first = await ProfileTransactions.previewRegion(context, file, probe);
      if (first.offerable && first.selectors.length > 0) {
        this.regionAssignments = {};
        this.regionMode = 'region';
        for (const selector of first.selectors) {
          this.regionSelector = selector;
          await this.refreshRegionPreview();
          if (this.regionPreview?.eligible === true) {
            this.sheetMode = SHEET_REGION;
            this.showSheet = true;
            return;
          }
        }
      }
    } catch (_) { /* ordinary import remains available if a preview cannot run */ }
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
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const plan: RegionPlan = { mode: this.regionMode, selector: this.regionSelector,
        enable: enable, assignments: this.regionAssignments };
      await ProfileTransactions.setRegionPlan(context, this.importedFile, plan);
      this.changed();
      this.showSheet = false;
      this.sheetMode = SHEET_NONE;
      this.toast(enable ? '地区策略已创建并启用' : '地区策略已创建，可稍后启用');
    } catch (e) { this.importError = (e as Error).message ?? '地区策略未保存'; }
    finally { this.regionBusy = false; }
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
    this.importedFile = file;
    this.importError = '';
    const existing = this.savedRegion(file);
    this.regionMode = existing?.mode ?? 'region';
    this.regionAssignments = existing?.assignments ?? {};
    this.regionSelector = existing?.selector ?? '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      if (this.regionSelector === '') {
        const probe: RegionPlan = { mode: 'region', selector: '', enable: false, assignments: {} };
        const first = await ProfileTransactions.previewRegion(context, file, probe);
        this.regionSelector = first.selectors[0] ?? '';
      }
      await this.refreshRegionPreview();
      this.sheetMode = SHEET_REGION;
      this.showSheet = true;
    } catch (_) { this.toast('当前订阅无法创建地区策略'); }
  }

  private async toggleRegion(file: string): Promise<void> {
    try {
      const saved = this.savedRegion(file);
      if (saved === null) { return; }
      const context = getContext(this) as common.UIAbilityContext;
      await ProfileTransactions.setRegionPlan(context, file, { mode: saved.mode,
        selector: saved.selector, assignments: saved.assignments, enable: !saved.enable });
      this.changed();
      this.toast(saved.enable ? '已恢复原订阅规则，策略可重新启用' : '已启用 Smart 地区策略');
    } catch (e) { this.toast((e as Error).message ?? '地区策略切换失败'); }
  }

  private confirmDelete(p: ProfileMeta): void {
    AlertDialog.show({
      title: '删除订阅？',
      message: p.name,
      primaryButton: { value: '保留', action: () => {} },
      secondaryButton: { value: '删除', fontColor: UI.error, action: async () => {
        const context = getContext(this) as common.UIAbilityContext;
        if (ProfileStore.getActiveFile(context) === p.file &&
          VpnController.status !== VpnStatus.Disconnected) {
          this.toast('请先断开连接，再删除当前订阅');
          return;
        }
        try {
          await ProfileTransactions.remove(context, p.file);
          this.changed();
          this.toast('已删除');
        } catch (_) {
          this.refresh();
          this.toast('删除失败，请重试');
        }
      } }
    });
  }

  aboutToAppear(): void {
    this.selectedFile = this.detailFile;
    this.refresh();
  }

  private refresh(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.profiles = ProfileStore.list(context);
    this.metas = ProfileStore.getMeta(context);
    if (this.selectedFile.length > 0 && !this.profiles.some((p: ProfileMeta) => p.file === this.selectedFile)) {
      this.selectedFile = '';
      if (this.detailFile.length > 0) { this.navStack.pop(); }
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private metaStamp(file: string): number {
    const m = this.metas[file];
    return m !== undefined ? m.updatedAt : 0;
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
          return `流量 ${this.fmtTraffic(used)}/${this.fmtTraffic(m.sub.total)} · 剩 ${this.daysLeft(m.sub.expire)} 天`;
        }
        return `流量 ${this.fmtTraffic(used)}/${this.fmtTraffic(m.sub.total)}`;
      }
      if (m.sub.expire > 0) {
        return `流量 ${this.fmtTraffic(used)} · 剩 ${this.daysLeft(m.sub.expire)} 天`;
      }
      return `流量 ${this.fmtTraffic(used)}`;
    }
    return `${(p.size / 1024).toFixed(1)} KB · ${new Date(p.mtime * 1000).toLocaleDateString()}`;
  }

  private async activate(p: ProfileMeta): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const result = await ProfileTransactions.activate(context, p.file);
      this.toast(result === 'applied' ? `已切换到「${p.name}」` : `已选择「${p.name}」，启动 VPN 后生效`);
      this.changed();
    } catch (e) {
      this.toast((e as Error).message ?? '切换失败');
    }
  }

  private async updateProfile(p: ProfileMeta): Promise<void> {
    if (this.updatingFile.length > 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.updatingFile = p.file;
    try {
      const result = await ProfileTransactions.update(context, p.file);
      this.toast(result === 'applied' ? '已更新并应用' : '已更新，启用或启动后生效');
      this.changed();
    } catch (e) {
      this.toast(`更新失败: ${(e as Error).message}`);
    } finally {
      this.updatingFile = '';
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
      this.toast('订阅 URL 已复制');
    } catch (e) {
      Logger.warn(TAG, `copyOrigin: ${JSON.stringify(e)}`);
      this.toast('复制失败');
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
      this.toast(`已重命名为 ${renamed.replace(/\.(yaml|yml)$/, '')}`);
      this.changed();
    } catch (e) {
      this.toast(`重命名失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  private async exportProfile(p: ProfileMeta): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, p.file);
    if (content === null) {
      this.toast('读取配置失败');
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker(context);
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`${p.name}.yaml`];
      opt.fileSuffixChoices = ['YAML 配置|.yaml'];
      const uris = await docPicker.save(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
      fileIo.closeSync(f);
      this.toast('已导出');
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `export: ${msg}`);
      this.toast(`导出失败: ${msg}`);
    }
  }

  private async importUrl(): Promise<void> {
    const url = this.inputUrl.trim();
    if (url.length === 0) {
      return;
    }
    if (this.importing) { return; }
    this.importError = '';
    this.importing = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const file = await ProfileStore.importFromUrl(context, url);
      this.inputUrl = '';
      this.finishImport(file);
    } catch (e) {
      this.importError = '导入失败，请检查输入与网络后重试';
    } finally {
      this.importing = false;
    }
  }

  private async importFile(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const docPicker = new picker.DocumentViewPicker(context);
      const uris = await docPicker.select({
        maxSelectNumber: 1,
        selectMode: picker.DocumentSelectMode.FILE,
        fileSuffixFilters: ['.yaml', '.yml']
      });
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      // 循环读完整文件（readSync 单次可能短读，也避免固定 2MB 上限截断大订阅）
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (true) {
        const buf = new ArrayBuffer(1024 * 1024);
        const len = fileIo.readSync(f.fd, buf);
        if (len <= 0) {
          break;
        }
        chunks.push(new Uint8Array(buf.slice(0, len)));
        total += len;
        if (total > 32 * 1024 * 1024) {
          fileIo.closeSync(f);
          throw new Error('配置文件超过 32MB 上限');
        }
      }
      fileIo.closeSync(f);
      const merged = new Uint8Array(total);
      let off = 0;
      for (const c of chunks) {
        merged.set(c, off);
        off += c.length;
      }
      const content = util.TextDecoder.create('utf-8').decodeToString(merged);
      const seg = uri.split('/').pop() ?? `file_${Date.now()}`;
      const name = decodeURIComponent(seg).replace(/\.(yaml|yml)$/i, '');
      const file = ProfileStore.importContent(context, name, content);
      this.finishImport(file);
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `importFile: ${msg}`);
      this.toast(`导入失败: ${msg}`);
    }
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
      this.toast('请手动粘贴链接或 YAML');
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
      this.importError = '导入失败，请检查输入与网络后重试';
      this.sheetMode = SHEET_PASTE;
      this.showSheet = true;
    }
  }

  /** 下拉刷新：激活配置为 URL 源时重新下载并热重载 */
  private async onPullRefresh(): Promise<void> {
    this.refreshing = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const active = ProfileStore.getActiveFile(context);
      if (active.length > 0 && this.isUrlProfile(active)) {
        try {
          const result = await ProfileTransactions.update(context, active);
          this.toast(result === 'applied' ? '已更新并应用' : '已更新，启用或启动后生效');
        } catch (e) {
          Logger.warn(TAG, `pull refresh update failed: ${(e as Error).message ?? JSON.stringify(e)}`);
          this.toast(`更新失败: ${(e as Error).message}`);
        }
      }
      this.refresh();
    } finally {
      this.refreshing = false;
    }
  }

  @Builder
  ProfileRow(p: ProfileMeta) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.doc')).fontSize(20).fontColor([UI.muted])
        Column({ space: 6 }) {
          Text(p.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(p.active ? '当前使用' : (this.isUrlProfile(p.file) ? 'URL 订阅' : '本地配置'))
            .fontSize(13).fontColor(UI.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([UI.muted])
      }.padding(18).width('100%')
    }.width('100%').constraintSize({ minHeight: 84 }).backgroundColor(UI.surface).borderRadius(24)
      .onClick(() => {
        ProfileDetailBus.current = p.file;
        this.navStack.pushPath({ name: 'profileDetail' });
      })
  }

  @Builder
  DetailAction(label: string, onTap: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(label).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([UI.muted])
      }.padding(18).width('100%')
    }.width('100%').height(72).borderRadius(24).backgroundColor(UI.surface).fontColor(UI.ink)
      .onClick(onTap)
  }

  @Builder
  ProfileDetail(p: ProfileMeta) {
    Column({ space: 16 }) {
      Scroll() {
        Column({ space: 16 }) {
          Text(p.active ? '当前使用' : '订阅详情').fontSize(13).fontColor(UI.muted).width('100%')
          Text(p.name).fontSize(28).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
          Text(this.isUrlProfile(p.file) ? 'URL 订阅' : '本地配置').fontSize(14).fontColor(UI.muted).width('100%')
          Text(this.subText(p)).fontSize(14).fontColor(UI.muted).width('100%')
          this.DetailAction('原始配置', () => {
            ProfileEditBus.current = p.file;
            this.navStack.pushPath({ name: 'profileEdit' });
          })
          this.DetailAction('内核参数覆写', () => { this.navStack.pushPath({ name: 'override' }); })
          if (this.savedRegion(p.file) !== null) {
            this.DetailAction('修改 Smart 地区策略', () => { this.editRegion(p.file); })
            this.DetailAction(this.savedRegion(p.file)?.enable ? '关闭地区策略并恢复原规则' :
              '启用 Smart 地区策略', () => { this.toggleRegion(p.file); })
          } else {
            this.DetailAction('创建 Smart 地区策略', () => { this.editRegion(p.file); })
          }
          this.DetailAction('重命名', () => {
            this.renameTarget = p.file;
            this.renameInput = p.name;
            this.sheetMode = SHEET_RENAME;
            this.showSheet = true;
          })
          this.DetailAction('导出配置', () => { this.exportProfile(p); })
          if (!p.active) {
            Button('启用订阅').width('100%').height(56).backgroundColor(UI.action).fontColor(UI.onAccent)
              .onClick(() => this.activate(p))
          }
          if (this.isUrlProfile(p.file)) {
            Button(this.updatingFile === p.file ? '更新中…' : '更新订阅')
              .width('100%').height(56).backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.updatingFile.length === 0)
              .onClick(() => this.updateProfile(p))
            this.DetailAction('复制订阅链接', () => {
              this.copyOrigin(getContext(this) as common.UIAbilityContext, p.file);
            })
          }
          Button('删除订阅').width('100%').height(48).backgroundColor(Color.Transparent)
            .fontColor(UI.error).onClick(() => this.confirmDelete(p))
        }.width('100%').padding({ bottom: 12 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%')
  }

  @Builder
  ImportEntry(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([UI.muted])
      Text(label)
        .fontSize(15)
        .fontColor(UI.ink)
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
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
      Text('添加订阅')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
        .width('100%')
        .padding({ top: 20, left: 20, right: 20, bottom: 8 })
      this.ImportEntry($r('sys.symbol.link'), '订阅链接', () => {
        this.sheetMode = SHEET_URL;
      })
      this.ImportEntry($r('sys.symbol.folder'), '配置文件', () => {
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
        this.importFile();
      })
      this.ImportEntry($r('sys.symbol.text_clipboard'), '剪贴板', () => {
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
      Text('从 URL 导入订阅')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: 'https://example.com/sub.yaml', text: this.inputUrl })
        .height(48)
        .width('100%')
        .onChange((v: string) => {
          this.inputUrl = v;
        })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(UI.error).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消')
          .height(48)
          .enabled(!this.importing)
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.showSheet = false;
            this.sheetMode = SHEET_NONE;
            this.inputUrl = '';
          })
        Button(this.importing ? '导入中…' : '导入')
          .height(48)
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
      Text('重命名配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(UI.ink)
      TextInput({ placeholder: '新名称（自动补 .yaml）', text: this.renameInput })
        .height(48)
        .width('100%')
        .onChange((v: string) => {
          this.renameInput = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(UI.soft)
          .fontColor(UI.ink)
          .onClick(() => {
            this.showSheet = false;
            this.sheetMode = SHEET_NONE;
            this.renameTarget = '';
            this.renameInput = '';
          })
        Button('确定')
          .height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
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
      this.importError = '导入失败，请检查输入与网络后重试';
    } finally {
      this.importing = false;
    }
  }

  @Builder
  PasteSheet() {
    Column({ space: 16 }) {
      Text('粘贴链接或 YAML').fontSize(20).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      TextArea({ text: this.inputPaste, placeholder: '订阅链接或完整配置' }).height(160)
        .fontSize(14).onChange((value: string) => { this.inputPaste = value; })
      if (this.importError.length > 0) {
        Text(this.importError).fontSize(14).fontColor(UI.error)
      }
      Button(this.importing ? '导入中…' : '导入').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.importing).onClick(() => this.importPaste())
    }.padding(24).width('100%')
  }

  @Builder
  ReadySheet() {
    Column({ space: 20 }) {
      Text('订阅已准备好').fontSize(24).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text(this.importedFile.replace(/\.(yaml|yml)$/, '')).fontSize(16).fontColor(UI.muted)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('启用订阅').width('100%').height(56).backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => {
        const profile = this.profiles.find((p: ProfileMeta) => p.file === this.importedFile);
        if (profile !== undefined) { this.activate(profile); }
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
      })
      Button('稍后启用').width('100%').height(48).backgroundColor(UI.soft).fontColor(UI.accentText)
        .onClick(() => { this.showSheet = false; this.sheetMode = SHEET_NONE; })
    }.padding(24).width('100%')
  }

  @Builder
  RegionSheet() {
    Column({ space: 12 }) {
      Text('为订阅创建 Smart 策略？').fontSize(21).fontWeight(FontWeight.Bold).fontColor(UI.ink)
      Text('仅按节点名称推测地区。原订阅及原 Selector 保留，可关闭后恢复。')
        .fontSize(13).fontColor(UI.muted)
      if (this.regionPreview !== null) {
        Select(this.regionPreview.selectors.map((name: string) => new RegionSelectOption(name)))
          .selected(this.regionPreview.selectors.indexOf(this.regionSelector))
          .value(this.regionSelector).width('100%')
          .onSelect(async (index: number) => {
            this.regionSelector = this.regionPreview?.selectors[index] ?? '';
            this.regionAssignments = {};
            try { await this.refreshRegionPreview(); } catch (_) { this.importError = '预览失败'; }
          })
        Row({ space: 8 }) {
          Button('按地区').backgroundColor(this.regionMode === 'region' ? UI.action : UI.soft)
            .fontColor(this.regionMode === 'region' ? UI.onAccent : UI.accentText)
            .onClick(() => { this.regionMode = 'region'; })
          Button('全部节点').backgroundColor(this.regionMode === 'all' ? UI.action : UI.soft)
            .fontColor(this.regionMode === 'all' ? UI.onAccent : UI.accentText)
            .onClick(() => { this.regionMode = 'all'; })
          Button('保持原样').backgroundColor(UI.soft).fontColor(UI.accentText)
            .onClick(() => { this.showSheet = false; this.sheetMode = SHEET_NONE; })
        }
        if (this.regionPreview.providerPending) {
          Text('该 Selector 含尚未解析的 provider 节点，暂不能生成策略。')
            .fontSize(13).fontColor(UI.error)
        }
        Text(`直接节点 ${Object.keys(this.regionPreview.nodes).length} · 未知 ${this.regionPreview.unknown}`)
          .fontSize(14).fontColor(UI.ink)
        if (this.regionMode === 'region') {
          Text(REGION_NAMES.filter((name: string) => (this.regionPreview?.counts[name] ?? 0) > 0)
            .map((name: string) => `${name} ${this.regionPreview?.counts[name] ?? 0}`).join(' · '))
            .fontSize(13).fontColor(UI.muted)
        }
        Scroll() {
          Column({ space: 8 }) {
            ForEach(Object.keys(this.regionPreview.nodes), (node: string) => {
              Row({ space: 8 }) {
                Text(node).fontSize(12).fontColor(UI.ink).layoutWeight(1)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Select(REGION_NAMES.map((name: string) => new RegionSelectOption(name)))
                  .selected(REGION_NAMES.indexOf(this.regionPreview?.nodes[node] ?? '未知'))
                  .value(this.regionPreview?.nodes[node] ?? '未知').width(104)
                  .onSelect(async (index: number) => {
                    const next: Record<string, string> = {};
                    for (const key of Object.keys(this.regionAssignments)) {
                      next[key] = this.regionAssignments[key];
                    }
                    next[node] = REGION_NAMES[index];
                    this.regionAssignments = next;
                    try { await this.refreshRegionPreview(); } catch (_) { this.importError = '预览失败'; }
                  })
              }
            }, (node: string) => node)
          }
        }.height(160)
      }
      if (this.importError.length > 0) { Text(this.importError).fontSize(13).fontColor(UI.error) }
      Button('创建并启用').width('100%').height(48).backgroundColor(UI.action).fontColor(UI.onAccent)
        .enabled(this.regionCanCreate())
        .onClick(() => { this.saveRegion(true); })
      Button('仅创建').width('100%').height(44).backgroundColor(UI.soft).fontColor(UI.accentText)
        .enabled(this.regionCanCreate())
        .onClick(() => { this.saveRegion(false); })
    }.padding(20).width('100%')
  }

  @Builder
  MainSheet() {
    if (this.sheetMode === SHEET_IMPORT) { this.ImportMenuSheet() }
    else if (this.sheetMode === SHEET_URL) { this.UrlImportDialog() }
    else if (this.sheetMode === SHEET_RENAME) { this.RenameSheet() }
    else if (this.sheetMode === SHEET_READY) { this.ReadySheet() }
    else if (this.sheetMode === SHEET_PASTE) { this.PasteSheet() }
    else if (this.sheetMode === SHEET_REGION) { this.RegionSheet() }
  }

  build() {
    Column({ space: 16 }) {
      if (this.selectedFile.length > 0) {
        ForEach(this.profiles.filter((p: ProfileMeta) => p.file === this.selectedFile), (p: ProfileMeta) => {
          this.ProfileDetail(p)
        }, (p: ProfileMeta) => p.file + '|' + (p.active ? '1' : '0') + '|' + this.metaStamp(p.file))
      } else {
        Row() {
          Text('订阅').fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink).layoutWeight(1)
          Button('添加').height(48).fontSize(14).backgroundColor(UI.soft).fontColor(UI.accentText)
            .onClick(() => { this.sheetMode = SHEET_IMPORT; this.importError = ''; this.showSheet = true; })
        }.width('100%').margin({ top: 16, bottom: 12 })
        if (this.profiles.length === 0) {
          Column({ space: 20 }) {
            Text('导入订阅').fontSize(32).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
            this.ImportEntry($r('sys.symbol.link'), '订阅链接', () => {
              this.sheetMode = SHEET_URL; this.showSheet = true;
            })
            this.ImportEntry($r('sys.symbol.folder'), '配置文件', () => { this.importFile(); })
            this.ImportEntry($r('sys.symbol.text_clipboard'), '剪贴板', () => { this.importClipboard(); })
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
      .bindSheet($$this.showSheet, this.MainSheet(), { height: SheetSize.FIT_CONTENT,
        shouldDismiss: (dismiss: SheetDismiss) => { if (!this.importing && !this.regionBusy) { dismiss.dismiss(); } } })
  }
}
