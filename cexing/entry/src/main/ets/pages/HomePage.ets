import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi, TrafficMsg, formatRate } from '../lib/CoreApi';
import { ProfileStore } from '../lib/ProfileStore';
import { Settings } from '../lib/Settings';
import { BackgroundNotice } from './BackgroundNotice';
import { AppRuntime } from '../lib/AppRuntime';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { NativeTheme as UI } from './NativeTheme';
import { ProfileDetailBus } from './ProfilePage';

const MODE_LABELS: string[] = [UiText.get($r('app.string.mode_rule')), UiText.get($r('app.string.mode_global')), UiText.get($r('app.string.mode_direct'))];
const MODE_VALUES: string[] = ['rule', 'global', 'direct'];

@Component
export struct HomePage {
  @Consume('rootVisible') @Watch('onRootVisible') rootVisible: boolean;
  @Consume('profileRevision') @Watch('onProfilesChanged') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @State status: VpnStatus = VpnController.status;
  private preparingSmart: boolean = false;
  @State profileName: string = UiText.get($r('app.string.state_not_imported'));
  @State hasProfile: boolean = false;
  @State upRate: string = '—';
  @State downRate: string = '—';
  @State mode: string = 'rule';
  @State stageWidth: number = 340;
  @State wide: boolean = false;
  @State stageHeight: number = 174;
  @State shortWindow: boolean = false;
  @State prioritizePanel: boolean = false;
  @State startFailed: boolean = false;
  @State stopUnknown: boolean = false;
  private lastTrafficAt: number = 0;
  private freshnessTimer: number = -1;
  private stopRequest: number = 0;
  private watcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private visible: boolean = false;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    if ((status === VpnStatus.Connecting || status === VpnStatus.Connected) &&
      (this.status === VpnStatus.Disconnected || this.status === VpnStatus.Disconnecting)) {
      this.stopRequest++;
      this.stopUnknown = false;
    }
    this.status = status;
    this.stopUnknown = status === VpnStatus.Disconnected && VpnController.needsStop();
    if (status === VpnStatus.Disconnected && VpnController.getLastStopCompleted() === true &&
      VpnController.getLastStartFailure() === null) { this.startFailed = false; }
    if (this.visible) {
      this.refreshTraffic();
      this.showStartFailure();
    }
  };

  private showStartFailure(): void {
    const message = VpnController.consumeLastStartError();
    if (message.length > 0) {
      this.startFailed = true;
      promptAction.showToast({ message: UiText.get($r('app.string.failure_start_detail'), message), duration: 3000 });
    }
  }

  aboutToAppear(): void {
    this.visible = true;
    this.status = VpnController.status;
    this.stopUnknown = this.status === VpnStatus.Disconnected &&
      VpnController.needsStop();
    VpnController.onChanged(this.listener);
    this.showStartFailure();
    this.refreshProfile();
    this.refreshTraffic();
    this.freshnessTimer = setInterval(() => {
      if (this.lastTrafficAt > 0 && Date.now() - this.lastTrafficAt > 4000) {
        this.upRate = '—';
        this.downRate = '—';
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.stopRequest++;
    VpnController.offChanged(this.listener);
    this.watcher.stop();
    clearInterval(this.freshnessTimer);
    this.freshnessTimer = -1;
  }

  private onProfilesChanged(): void {
    if (this.visible && this.currentVisibleTab === 0) { this.refreshProfile(); }
  }

  private onRootVisible(): void {
    if (!this.rootVisible) { this.stopRequest++; }
    this.refreshTraffic();
  }

  private onTabVisible(): void {
    if (this.currentVisibleTab !== 0) { this.stopRequest++; }
    if (this.currentVisibleTab === 0) {
      this.refreshProfile();
    }
    this.refreshTraffic();
  }

  private refreshProfile(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const file = ProfileStore.getActiveFile(ctx);
    this.hasProfile = file.length > 0;
    this.profileName = this.hasProfile ? file.replace(/\.(yaml|yml)$/, '') : UiText.get($r('app.string.state_not_imported'));
    const saved = Settings.load(ctx).mode;
    if (MODE_VALUES.indexOf(saved) >= 0) {
      this.mode = saved;
    }
    CoreApi.getConfigs().then((config) => {
      if (config !== null) {
        this.mode = config.mode;
      }
    });
  }

  private refreshTraffic(): void {
    this.watcher.stop();
    this.upRate = '—';
    this.downRate = '—';
    this.lastTrafficAt = 0;
    if (this.visible && this.rootVisible && this.currentVisibleTab === 0 && this.status === VpnStatus.Connected) {
      this.watcher.start('/traffic', (traffic: TrafficMsg) => {
        this.lastTrafficAt = Date.now();
        this.upRate = formatRate(traffic.up);
        this.downRate = formatRate(traffic.down);
      });
    }
  }

  private async stopVpn(ctx: common.UIAbilityContext): Promise<void> {
    const request = ++this.stopRequest;
    let completed = false;
    try { completed = await VpnController.stop(ctx); }
    catch (_) {}
    if (request !== this.stopRequest) { return; }
    this.stopUnknown = !completed;
    if (!completed && this.visible && this.rootVisible &&
      this.currentVisibleTab === 0) {
      promptAction.showToast({ message: UiText.get($r('app.string.failure_stop_unknown')), duration: 3000 });
    }
  }

  private async toggle(): Promise<void> {
    AppRuntime.cancelRestore();
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.status === VpnStatus.Disconnected) {
      if (VpnController.needsStop() || this.stopUnknown) { await this.stopVpn(ctx); return; }
      if (this.preparingSmart) { return; }
      const file = ProfileStore.getActiveFile(ctx);
      if (file.length === 0) {
        this.tabJump = 1;
        return;
      }
      const request = this.stopRequest;
      this.startFailed = false;
      this.preparingSmart = true;
      try { await ProfileTransactions.ensureActiveSmartPolicy(ctx); }
      catch (_) {
        if (request !== this.stopRequest || !this.visible || !this.rootVisible ||
          this.currentVisibleTab !== 0) { return; }
        this.startFailed = true;
        promptAction.showToast({ message: UiText.get($r('app.string.failure_prepare_config')) });
        return;
      } finally { this.preparingSmart = false; }
      if (request !== this.stopRequest || !this.visible || !this.rootVisible ||
        this.currentVisibleTab !== 0 || VpnController.status !== VpnStatus.Disconnected ||
        ProfileStore.getActiveFile(ctx) !== file) { return; }
      if (VpnController.needsStop()) {
        this.stopUnknown = true;
        promptAction.showToast({ message: UiText.get($r('app.string.failure_state_unknown')) });
        return;
      }
      VpnController.start(ctx);
    } else if (this.status === VpnStatus.Connecting) {
      this.stopVpn(ctx);
    } else if (this.status === VpnStatus.Connected) {
      this.stopVpn(ctx);
    }
  }

  private async changeMode(index: number): Promise<void> {
    const next = MODE_VALUES[index];
    if (this.status === VpnStatus.Connected && !(await CoreApi.patchMode(next))) {
      promptAction.showToast({ message: UiText.get($r('app.string.failure_mode_change')) });
      return;
    }
    this.mode = next;
    const ctx = getContext(this) as common.UIAbilityContext;
    const settings = Settings.load(ctx);
    settings.mode = next;
    try { await Settings.save(ctx, settings, ['mode']); }
    catch (_) { promptAction.showToast({ message: UiText.get($r('app.string.failure_mode_save')) }); }
  }

  private label(): string {
    if (this.status === VpnStatus.Connected) { return UiText.get($r('app.string.state_connected')); }
    if (this.status === VpnStatus.Connecting) { return UiText.get($r('app.string.state_connecting')); }
    if (this.status === VpnStatus.Disconnecting) { return UiText.get($r('app.string.state_disconnecting')); }
    return this.stopUnknown ? UiText.get($r('app.string.state_stop_unknown')) : (this.startFailed ? UiText.get($r('app.string.state_connect_failed')) : UiText.get($r('app.string.state_disconnected')));
  }

  private stateLine(): string {
    if (this.status === VpnStatus.Connected) { return UiText.get($r('app.string.state_connected_actions')); }
    if (this.status === VpnStatus.Connecting) { return UiText.get($r('app.string.state_system_connecting')); }
    if (this.status === VpnStatus.Disconnecting) { return UiText.get($r('app.string.state_system_disconnecting')); }
    return this.stopUnknown ? UiText.get($r('app.string.state_stop_diagnostics')) :
      (this.startFailed ? UiText.get($r('app.string.state_retry_diagnostics')) : UiText.get($r('app.string.state_ready_connect')));
  }

  @Builder
  Rate(upload: boolean, label: string) {
    Column({ space: 7 }) {
      Text(label).fontSize(12).fontColor('#C9D3D9')
      Text() {
        Span((upload ? this.upRate : this.downRate).split(' ')[0]).fontSize(28).fontWeight(600)
        Span((upload ? this.upRate : this.downRate).indexOf(' ') >= 0 ?
          ` ${(upload ? this.upRate : this.downRate).split(' ').slice(1).join(' ')}` : '')
          .fontSize(12).fontColor('#C9D3D9')
      }.fontColor(Color.White).fontFeature('tnum')
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      .accessibilityGroup(true).accessibilityText(`${label} ${upload ? this.upRate : this.downRate}`)
  }

  @Builder
  ConnectionCard() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Polygon().width('100%').height(this.stageHeight)
          .points([[this.stageWidth * 0.87, 0], [this.stageWidth, 0],
            [this.stageWidth, this.stageHeight], [this.stageWidth * 0.64, this.stageHeight]])
          .fill('#EDF0F1').accessibilityLevel('no')
        Polygon().width('100%').height(this.stageHeight)
          .points([[this.stageWidth, this.stageHeight * 0.14], [this.stageWidth, this.stageHeight], [this.stageWidth * 0.74, this.stageHeight]])
          .fill(UI.stage).accessibilityLevel('no')
        Polygon().width('100%').height(this.stageHeight)
          .points([[this.stageWidth * 0.86, this.stageHeight * 0.6], [this.stageWidth * 0.87, this.stageHeight * 0.6],
            [this.stageWidth * 0.75, this.stageHeight], [this.stageWidth * 0.74, this.stageHeight]])
          .fill(this.status === VpnStatus.Connected ? UI.signal : '#AEBCC3').accessibilityLevel('no')
        Column({ space: 13 }) {
          if (!this.shortWindow) {
            Text(UiText.get($r('app.string.home_connection_state'))).fontSize(12).fontColor(UI.stateMuted).margin({ bottom: 5 })
          }
          Text(this.label()).fontSize(36).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.stateInk)
          Row({ space: 8 }) {
            if (this.status === VpnStatus.Connecting || this.status === VpnStatus.Disconnecting) {
              LoadingProgress().width(16).height(16).color('#00869B')
            } else {
              Circle().width(7).height(7)
                .fill(this.status === VpnStatus.Connected ? '#00869B' : '#97A6AE')
            }
            Text(this.stateLine()).fontSize(13).fontColor(UI.stateMuted)
          }
        }.alignItems(HorizontalAlign.Start).padding({ left: 24, right: 24, top: this.shortWindow ? 16 : 24,
          bottom: this.shortWindow ? 16 : 24 }).width('74%')
      }.width('100%').constraintSize({ minHeight: this.stageHeight })
        .onAreaChange((_old: Area, area: Area) => { this.stageWidth = Number(area.width); })
      if (this.status === VpnStatus.Connected) {
        Row({ space: 20 }) {
          this.Rate(true, UiText.get($r('app.string.home_upload')))
          Divider().vertical(true).height(48).color('#52616A')
          this.Rate(false, UiText.get($r('app.string.home_download')))
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([Color.White])
        }.padding({ top: 18, bottom: 18, left: 24, right: 24 }).width('100%').backgroundColor(UI.stage)
          .accessibilityRole(AccessibilityRoleType.BUTTON).accessibilityGroup(true).accessibilityText(UiText.get($r('app.string.home_traffic_description'), this.upRate, this.downRate))
          .onClick(() => { this.navStack.pushPath({ name: 'traffic' }); })
      } else {
        Row() {
          Text(UiText.get($r('app.string.nav_traffic'))).fontSize(12).fontColor('#C9D3D9').layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([Color.White])
        }.width('100%').padding({ top: 17, bottom: 17, left: 24, right: 24 }).backgroundColor(UI.stage)
          .accessibilityRole(AccessibilityRoleType.BUTTON).accessibilityGroup(true).accessibilityText(UiText.get($r('app.string.home_view_traffic')))
          .onClick(() => { this.navStack.pushPath({ name: 'traffic' }); })
      }
    }.width(this.wide ? '48%' : '100%').backgroundColor(Color.White)
      .borderRadius(28).clip(true).border({ width: 1, color: UI.line })
  }

  @Builder
  PanelEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([UI.accentText])
        Column({ space: 4 }) {
          Text(UiText.get($r('app.string.nav_panel'))).fontSize(17).fontWeight(FontWeight.Medium)
          Text('Zashboard').fontSize(11).fontColor(UI.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding(18)
    }.width('100%').constraintSize({ minHeight: 80 }).borderRadius(24)
      .backgroundColor(UI.soft).fontColor(UI.ink).enabled(this.status === VpnStatus.Connected)
      .onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
  }

  @Builder
  ConnectionTools() {
    Column({ space: 16 }) {
      if (!this.prioritizePanel) { this.PanelEntry() }
      Row() {
        Text(UiText.get($r('app.string.home_current_profile'))).fontSize(13).fontColor(UI.muted).layoutWeight(1)
        Button(UiText.get($r('app.string.action_manage')), { type: ButtonType.Normal }).constraintSize({ minHeight: 48 }).fontSize(14)
          .backgroundColor(Color.Transparent).fontColor(UI.ink).onClick(() => { this.tabJump = 1; })
      }.width('100%')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Text(this.profileName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([UI.muted])
        }.padding(18).width('100%')
      }.width('100%').constraintSize({ minHeight: 80 }).borderRadius(24).backgroundColor(UI.surface)
        .accessibilityText(UiText.get($r('app.string.a11y_current_profile'), this.profileName))
        .onClick(() => {
          const file = ProfileStore.getActiveFile(getContext(this) as common.UIAbilityContext);
          if (file.length === 0) { this.tabJump = 1; return; }
          ProfileDetailBus.current = file;
          this.navStack.pushPath({ name: 'profileDetail' });
        })
      Row({ space: 4 }) {
        ForEach(MODE_LABELS, (label: string, index: number) => {
          Button(label).layoutWeight(1).constraintSize({ minHeight: 48 }).fontSize(14)
            .backgroundColor(this.mode === MODE_VALUES[index] ? UI.soft : Color.Transparent)
            .fontColor(this.mode === MODE_VALUES[index] ? UI.accentText : UI.muted)
            .accessibilitySelected(this.mode === MODE_VALUES[index])
            .accessibilityDescription(this.status === VpnStatus.Connecting || this.status === VpnStatus.Disconnecting ? this.stateLine() : '')
            .enabled(this.status === VpnStatus.Connected || this.status === VpnStatus.Disconnected)
            .onClick(() => this.changeMode(index))
        }, (label: string) => label)
      }.padding(4).borderRadius(28).backgroundColor(UI.surface).width('100%')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([UI.accentText])
          Text(UiText.get($r('app.string.home_check_connection'))).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
        }.width('100%').padding({ left: 18, right: 18 })
      }.width('100%').constraintSize({ minHeight: 56 }).borderRadius(20).backgroundColor(UI.surface)
        .accessibilityText(UiText.get($r('app.string.home_check_description')))
        .onClick(() => { this.navStack.pushPath({ name: 'diagnostics' }); })
    }.width(this.wide ? '48%' : '100%').alignItems(HorizontalAlign.Start)
      .margin({ top: this.wide ? 0 : 6 })
  }

  build() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.nav_connection'))).fontSize(26).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.ink)
        .width('100%').margin({ top: 16, bottom: 12 })
      Scroll() {
        Column({ space: 20 }) {
          BackgroundNotice({ status: this.status, visible: this.rootVisible && this.currentVisibleTab === 0 })
          if (!this.hasProfile) {
            Column({ space: 18 }) {
              Text(UiText.get($r('app.string.home_import_profile'))).fontSize(36).fontWeight(FontWeight.Bold).fontColor(UI.ink)
              Button(UiText.get($r('app.string.action_add_profile'))).width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent)
                .onClick(() => { this.tabJump = 1; })
            }.padding(24).width('100%').borderRadius(28).backgroundColor(UI.surface)
          } else {
            if (this.prioritizePanel && this.status === VpnStatus.Connected) { this.PanelEntry() }
            Flex({ direction: this.wide ? FlexDirection.Row : FlexDirection.Column,
              justifyContent: FlexAlign.SpaceBetween }) {
              this.ConnectionCard()
              this.ConnectionTools()
            }.width('100%')
          }
        }.width('100%').padding({ bottom: 12 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      if (this.hasProfile || this.stopUnknown) {
        Button(this.status === VpnStatus.Disconnected ? (this.stopUnknown ? UiText.get($r('app.string.action_retry_disconnect')) : UiText.get($r('app.string.action_connect_vpn'))) :
          (this.status === VpnStatus.Connecting ? UiText.get($r('app.string.action_cancel_connect')) :
            (this.status === VpnStatus.Disconnecting ? UiText.get($r('app.string.state_disconnecting')) : UiText.get($r('app.string.action_disconnect')))))
          .width('100%').constraintSize({ minHeight: 56 }).fontSize(16).fontWeight(FontWeight.Medium)
          .backgroundColor(this.status === VpnStatus.Connected ? UI.soft : UI.action)
          .fontColor(this.status === VpnStatus.Connected ? UI.accentText : UI.onAccent)
          .accessibilityDescription(this.status === VpnStatus.Disconnecting ? this.stateLine() : '')
          .enabled(this.status !== VpnStatus.Disconnecting).onClick(() => this.toggle())
      }
    }.padding({ left: 24, right: 24, bottom: 12 }).width('100%').height('100%')
      .backgroundColor(UI.paper).constraintSize({ maxWidth: 1120 }).alignSelf(ItemAlign.Center)
      .onAreaChange((_old: Area, area: Area) => {
        this.wide = Number(area.width) >= 700;
        const scale = (getContext(this) as common.UIAbilityContext).config.fontSizeScale ?? 1;
        this.shortWindow = Number(area.height) <= 400;
        this.stageHeight = (this.shortWindow ? 134 : 174) + Math.max(0, scale - 1) * 160;
        this.prioritizePanel = Number(area.height) <= 650 || this.stageHeight >= 240;
      })

  }
}
