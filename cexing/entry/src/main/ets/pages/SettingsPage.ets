import { ProfileStorageDetails } from './ProfileStorageDetails';
import { UiText } from '../lib/UiText';
import { SettingsReconnectButton } from './SettingsReconnectButton';
import { NativeTheme as UI } from './NativeTheme';
/*
 * 分组卡片列表（运行/连接/自动化/诊断/关于，每组带标题）
 * 二级页导航（Navigation pushPath）+ Toggle（保活/自动恢复/订阅自动更新/内核日志落盘）
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings, AppSettings } from '../lib/Settings';
import { LiveViewKeeper } from '../lib/LiveViewKeeper';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { AutoUpdater } from '../lib/AutoUpdater';

/** 订阅自动更新可选间隔（小时） */
const INTERVAL_OPTIONS: number[] = [12, 24, 48, 72];

class SettingRow {
  title: string = '';
  sub: string = '';
  hasToggle: boolean = false;
  dest: string = '';
  action: string = '';
  /** 开关绑定：'keepAlive' | 'autoUpdate' | 'autoRestore' | 'logToFile' */
  toggleKey: string = '';
}

class SettingGroup {
  /** 分组标题（卡片上方 caption） */
  title: string = '';
  rows: SettingRow[] = [];
}

@Component
export struct SettingsPage {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tab') @Watch('onVisibilityChanged') currentVisibleTab: number = 2;
  @Consume('rootVisible') @Watch('onVisibilityChanged') rootVisible: boolean = true;
  @State keepAlive: boolean = false;
  @State autoUpdate: boolean = false;
  @State autoRestore: boolean = false;
  @State autoUpdateIntervalHours: number = 24;
  @State logToFile: boolean = true;

  private groups: SettingGroup[] = [
    {
      title: UiText.get($r('app.string.settings_running')),
      rows: [
        { title: UiText.get($r('app.string.settings_auto_restore')), sub: '', hasToggle: true, dest: '', action: '', toggleKey: 'autoRestore' },
        { title: UiText.get($r('app.string.settings_background')), sub: UiText.get($r('app.string.settings_background_hint')), hasToggle: true, dest: '', action: '', toggleKey: 'keepAlive' }
      ]
    },
    {
      title: UiText.get($r('app.string.settings_system_connection')),
      rows: [
        { title: UiText.get($r('app.string.nav_network')), sub: UiText.get($r('app.string.settings_network_hint')), hasToggle: false, dest: 'network', action: '', toggleKey: '' },
        { title: 'Smart', sub: UiText.get($r('app.string.settings_smart_hint')), hasToggle: false, dest: 'smart', action: '', toggleKey: '' },

      ]
    },
    {
      title: UiText.get($r('app.string.settings_advanced')),
      rows: [
        { title: UiText.get($r('app.string.nav_core')), sub: '', hasToggle: false, dest: 'override', action: '', toggleKey: '' },
        { title: UiText.get($r('app.string.nav_resources')), sub: '', hasToggle: false, dest: 'resources', action: '', toggleKey: '' }
      ]
    },
    {
      title: UiText.get($r('app.string.nav_profiles')),
      rows: [
        { title: UiText.get($r('app.string.settings_auto_update')), sub: UiText.get($r('app.string.settings_update_hint')), hasToggle: true, dest: '', action: '', toggleKey: 'autoUpdate' },
        { title: UiText.get($r('app.string.settings_interval')), sub: '', hasToggle: false, dest: '', action: 'interval', toggleKey: '' }
      ]
    },
    {
      title: UiText.get($r('app.string.nav_diagnostics')),
      rows: [
        { title: UiText.get($r('app.string.nav_diagnostics')), sub: '', hasToggle: false, dest: 'diagnostics', action: '', toggleKey: '' },
        { title: UiText.get($r('app.string.settings_log_file')), sub: UiText.get($r('app.string.settings_next_start')), hasToggle: true, dest: '', action: '', toggleKey: 'logToFile' },
      ]
    }
  ];

  private feedbackGeneration: number = 0;
  private pageActive: boolean = false;
  @State ready: boolean = false;

  aboutToDisappear(): void {
    this.pageActive = false;
    this.feedbackGeneration++;
  }

  private onVisibilityChanged(): void {
    if (this.currentVisibleTab === 2 && this.rootVisible) { this.aboutToAppear(); }
    else { this.pageActive = false; this.feedbackGeneration++; }
  }

  aboutToAppear(): void {
    this.pageActive = this.currentVisibleTab === 2 && this.rootVisible;
    this.feedbackGeneration++;
    const generation = this.feedbackGeneration;
    this.ready = false;
    this.readSettings();
    Settings.idle().then(() => {
      if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
      this.readSettings(); this.ready = true;
    }).catch(() => {
      if (this.pageActive && generation === this.feedbackGeneration) {
        promptAction.showToast({ message: UiText.get($r('app.string.failure_settings_read')) });
      }
    });
  }

  private readSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s: AppSettings = Settings.load(context);
    this.keepAlive = s.keepAlive;
    this.autoUpdate = s.autoUpdate;
    this.autoRestore = s.autoRestore;
    this.autoUpdateIntervalHours = s.autoUpdateIntervalHours;
    this.logToFile = s.logToFile;
  }

  private async onKeepAliveChange(on: boolean): Promise<void> {
    const generation = ++this.feedbackGeneration;
    this.keepAlive = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.keepAlive = on;
    try { await Settings.save(context, s, ['keepAlive']); }
    catch (_) {
      if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
      this.aboutToAppear();
      promptAction.showToast({ message: UiText.get($r('app.string.failure_save')), duration: 2000 });
      return;
    }
    if (this.keepAlive !== on) { return; }
    if (on && VpnController.status === VpnStatus.Connected) {
      const ok = await LiveViewKeeper.start(context);
      if (!this.pageActive || generation !== this.feedbackGeneration || !this.keepAlive) { return; }
      promptAction.showToast({ message: ok ? UiText.get($r('app.string.settings_background_enabled')) : UiText.get($r('app.string.settings_background_denied')), duration: 1500 });
    } else if (!on) {
      await LiveViewKeeper.stop(context);
    }
  }

  private async onAutoUpdateChange(on: boolean): Promise<void> {
    const generation = ++this.feedbackGeneration;
    this.autoUpdate = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.autoUpdate = on;
    try { await Settings.save(context, s, ['autoUpdate']); }
    catch (_) {
      if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
      this.aboutToAppear();
      promptAction.showToast({ message: UiText.get($r('app.string.failure_save')), duration: 2000 });
      return;
    }
    if (on && this.autoUpdate === on) {
      if (this.pageActive && generation === this.feedbackGeneration) {
        promptAction.showToast({ message: UiText.get($r('app.string.settings_enabled')), duration: 1500 });
      }
      // 立即补一轮检查（内核未运行/间隔未到时内部自动跳过）
      AutoUpdater.checkAndRun(context).catch(() => {
        // fire-and-forget：忽略单轮失败
      });
    }
  }

  private onIntervalTap(): void {
    const generation = this.feedbackGeneration;
    const sheets: SheetInfo[] = [];
    for (const h of INTERVAL_OPTIONS) {
      sheets.push({
        title: UiText.get($r('app.string.settings_hours'), h),
        action: async () => {
          if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
          const request = ++this.feedbackGeneration;
          this.autoUpdateIntervalHours = h;
          const context = getContext(this) as common.UIAbilityContext;
          const s = Settings.load(context);
          s.autoUpdateIntervalHours = h;
          try { await Settings.save(context, s, ['autoUpdateIntervalHours']); }
          catch (_) {
            if (!this.pageActive || request !== this.feedbackGeneration) { return; }
            this.aboutToAppear();
            promptAction.showToast({ message: UiText.get($r('app.string.failure_save')), duration: 2000 });
          }
        }
      });
    }
    ActionSheet.show({
      title: UiText.get($r('app.string.settings_interval')),
      message: UiText.get($r('app.string.settings_interval_hint')),
      sheets: sheets
    });
  }

  private toggleValue(row: SettingRow): boolean {
    if (row.toggleKey === 'autoUpdate') {
      return this.autoUpdate;
    }
    if (row.toggleKey === 'autoRestore') {
      return this.autoRestore;
    }
    if (row.toggleKey === 'logToFile') {
      return this.logToFile;
    }
    return this.keepAlive;
  }

  private onToggleChange(row: SettingRow, on: boolean): void {
    if (!this.pageActive || !this.ready) { return; }
    if (row.toggleKey === 'autoUpdate') {
      this.onAutoUpdateChange(on);
    } else if (row.toggleKey === 'autoRestore') {
      this.onAutoRestoreChange(on);
    } else if (row.toggleKey === 'logToFile') {
      this.onLogToFileChange(on);
    } else {
      this.onKeepAliveChange(on);
    }
  }

  private async onAutoRestoreChange(on: boolean): Promise<void> {
    const generation = ++this.feedbackGeneration;
    this.autoRestore = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.autoRestore = on;
    try { await Settings.save(context, s, ['autoRestore']); }
    catch (_) {
      if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
      this.aboutToAppear();
      promptAction.showToast({ message: UiText.get($r('app.string.failure_save')), duration: 2000 });
      return;
    }
  }

  private async onLogToFileChange(on: boolean): Promise<void> {
    const generation = ++this.feedbackGeneration;
    this.logToFile = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.logToFile = on;
    try { await Settings.save(context, s, ['logToFile']); }
    catch (_) {
      if (!this.pageActive || generation !== this.feedbackGeneration) { return; }
      this.aboutToAppear();
      promptAction.showToast({ message: UiText.get($r('app.string.failure_save')), duration: 2000 });
      return;
    }
    if (this.pageActive && generation === this.feedbackGeneration) {
      promptAction.showToast({ message: UiText.get($r('app.string.settings_saved_next')), duration: 1500 });
    }
  }

  private onRowTap(row: SettingRow): void {
    if (row.dest.length > 0) {
      this.navStack.pushPath({ name: row.dest });
      return;
    }
    if (row.action === 'interval') {
      this.onIntervalTap();
    }
  }

  @Builder
  RowItem(row: SettingRow) {
    if (row.hasToggle) {
      this.RowContent(row)
    } else {
      Button({ type: ButtonType.Normal }) { this.RowContent(row) }
        .width('100%').padding(0).backgroundColor(Color.Transparent)
        .accessibilityGroup(true).accessibilityText(row.title).accessibilityDescription(row.sub)
        .onClick(() => this.onRowTap(row))
    }
  }

  @Builder
  RowContent(row: SettingRow) {
    Row() {
      Column({ space: 4 }) {
        Text(row.title)
          .fontSize(16)
          .fontColor(UI.ink)
        if (row.sub.length > 0) {
          Text(row.sub)
            .fontSize(13)
            .fontColor(UI.muted)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .accessibilityLevel('no')
      .layoutWeight(1)
      if (row.hasToggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.toggleValue(row) })
          .selectedColor(UI.accent).accessibilityText(row.title).accessibilityChecked(this.toggleValue(row))
          .accessibilityDescription(this.ready ? row.sub : UiText.get($r('app.string.a11y_loading_settings')))
          .onChange((isOn: boolean) => {
            this.onToggleChange(row, isOn);
          })
      } else {
        if (row.action === 'interval') {
          Text(UiText.get($r('app.string.settings_hours'), this.autoUpdateIntervalHours))
            .fontSize(14)
            .fontColor(UI.muted)
            .constraintSize({ minHeight: 48 })
            .textAlign(TextAlign.Center)
            .margin({ right: 4 })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([UI.muted])
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 72 })
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
    .stateStyles({
      pressed: { .backgroundColor(UI.soft) },
      normal: { .backgroundColor(Color.Transparent) }
    })

  }

  @Builder
  GroupCard(group: SettingGroup) {
    Column() {
      ForEach(group.rows, (row: SettingRow, index: number) => {
        Column() {
          if (row.action !== 'interval' || this.autoUpdate) {
            this.RowItem(row)
          }
          if (index < group.rows.length - 1 &&
            (group.rows[index + 1].action !== 'interval' || this.autoUpdate)) {
            Divider()
              .color(UI.line)
              .margin({ left: 14 })
          }
        }
      }, (row: SettingRow) => row.title)
    }
    .width('100%')
    .backgroundColor(UI.surface)
    .borderRadius(24)
  }

  build() {
    Column({ space: 12 }) {
      SettingsReconnectButton()
      Row() {
        Text(UiText.get($r('app.string.action_settings')))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI.ink)
      }
      .width('100%')
      .constraintSize({ minHeight: 48 })
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8, bottom: 4 })

      List({ space: 12 }) {
        ForEach(this.groups, (group: SettingGroup) => {
          ListItem() {
            Column({ space: 7 }) {
              Text(group.title)
                .fontSize(13)
                .fontColor(UI.muted)
                .width('100%')
                .margin({ left: 4 })
              this.GroupCard(group)
            }
          }
        }, (group: SettingGroup) => group.title)
        ListItem() { ProfileStorageDetails() }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .contentEndOffset(16)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .enabled(this.ready).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
