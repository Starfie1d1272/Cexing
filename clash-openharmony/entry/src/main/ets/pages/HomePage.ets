import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi, TrafficMsg, formatRate } from '../lib/CoreApi';
import { ProfileStore } from '../lib/ProfileStore';
import { Settings } from '../lib/Settings';
import { AppRuntime } from '../lib/AppRuntime';
import { NativeTheme as UI } from './NativeTheme';

const MODE_LABELS: string[] = ['规则', '全局', '直连'];
const MODE_VALUES: string[] = ['rule', 'global', 'direct'];

@Component
export struct HomePage {
  @Consume('rootVisible') @Watch('refreshTraffic') rootVisible: boolean;
  @Consume('profileRevision') @Watch('onProfilesChanged') profileRevision: number;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @State status: VpnStatus = VpnController.status;
  @State profileName: string = '未导入';
  @State upRate: string = '—';
  @State downRate: string = '—';
  @State mode: string = 'rule';
  @State stageWidth: number = 340;
  @State wide: boolean = false;
  @State startFailed: boolean = false;
  private lastTrafficAt: number = 0;
  private freshnessTimer: number = -1;
  private watcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private visible: boolean = false;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    this.status = status;
    if (this.visible) {
      this.refreshTraffic();
      const message = VpnController.consumeLastStartError();
      if (message.length > 0) {
        this.startFailed = true;
        promptAction.showToast({ message: `启动失败：${message}`, duration: 3000 });
      }
    }
  };

  aboutToAppear(): void {
    this.visible = true;
    this.status = VpnController.status;
    VpnController.onChanged(this.listener);
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
    VpnController.offChanged(this.listener);
    this.watcher.stop();
    clearInterval(this.freshnessTimer);
    this.freshnessTimer = -1;
  }

  private onProfilesChanged(): void {
    if (this.visible && this.currentVisibleTab === 0) { this.refreshProfile(); }
  }

  private onTabVisible(): void {
    if (this.currentVisibleTab === 0) {
      this.refreshProfile();
    }
    this.refreshTraffic();
  }

  private refreshProfile(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const file = ProfileStore.getActiveFile(ctx);
    this.profileName = file.length > 0 ? file.replace(/\.(yaml|yml)$/, '') : '未导入';
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

  private toggle(): void {
    AppRuntime.cancelRestore();
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.status === VpnStatus.Disconnected) {
      if (ProfileStore.getActiveFile(ctx).length === 0) {
        this.tabJump = 1;
        return;
      }
      this.startFailed = false;
      VpnController.start(ctx);
    } else if (this.status === VpnStatus.Connecting) {
      VpnController.stop(ctx);
    } else if (this.status === VpnStatus.Connected) {
      AlertDialog.show({
        title: '断开连接？',
        message: '系统 VPN 会话将结束',
        primaryButton: { value: '保持连接', action: () => {} },
        secondaryButton: { value: '断开连接', action: () => {
          // Recheck after the dialog: the runtime may have changed state.
          if (VpnController.status === VpnStatus.Connected) {
            AppRuntime.cancelRestore();
            VpnController.stop(ctx);
          }
        } }
      });
    }
  }

  private async changeMode(index: number): Promise<void> {
    const next = MODE_VALUES[index];
    if (this.status === VpnStatus.Connected && !(await CoreApi.patchMode(next))) {
      promptAction.showToast({ message: '模式切换失败' });
      return;
    }
    this.mode = next;
    const ctx = getContext(this) as common.UIAbilityContext;
    const settings = Settings.load(ctx);
    settings.mode = next;
    Settings.save(ctx, settings);
  }

  private label(): string {
    if (this.status === VpnStatus.Connected) { return '已连接'; }
    if (this.status === VpnStatus.Connecting) { return '连接中…'; }
    if (this.status === VpnStatus.Disconnecting) { return '断开中…'; }
    return this.startFailed ? '连接失败' : '未连接';
  }

  private stateLine(): string {
    if (this.status === VpnStatus.Connected) { return '内核已就绪'; }
    if (this.status === VpnStatus.Connecting) { return '正在建立系统连接'; }
    if (this.status === VpnStatus.Disconnecting) { return '正在结束系统会话'; }
    return this.startFailed ? '可重试或前往诊断' : '准备连接';
  }

  @Builder
  Rate(value: string, label: string) {
    Column({ space: 7 }) {
      Text(value).fontSize(26).fontWeight(FontWeight.Medium).fontColor(Color.White)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label).fontSize(12).fontColor('#C9D3D9')
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }

  @Builder
  ConnectionCard() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Polygon().width('100%').height(174)
          .points([[this.stageWidth * 0.87, 0], [this.stageWidth, 0],
            [this.stageWidth, 174], [this.stageWidth * 0.64, 174]])
          .fill('#EDF0F1').accessibilityLevel('no')
        Polygon().width('100%').height(174)
          .points([[this.stageWidth, 24], [this.stageWidth, 174], [this.stageWidth * 0.74, 174]])
          .fill(UI.stage).accessibilityLevel('no')
        Polygon().width('100%').height(174)
          .points([[this.stageWidth * 0.86, 104], [this.stageWidth * 0.87, 104],
            [this.stageWidth * 0.75, 174], [this.stageWidth * 0.74, 174]])
          .fill(this.status === VpnStatus.Connected ? UI.signal : '#AEBCC3').accessibilityLevel('no')
        Column({ space: 13 }) {
          Text('VPN / 系统连接').fontSize(12).fontColor(UI.muted).margin({ bottom: 5 })
          Text(this.label()).fontSize(36).fontWeight(FontWeight.Bold).fontColor(UI.ink)
          Row({ space: 8 }) {
            if (this.status === VpnStatus.Connecting || this.status === VpnStatus.Disconnecting) {
              LoadingProgress().width(16).height(16).color(UI.accent)
            } else {
              Circle().width(7).height(7)
                .fill(this.status === VpnStatus.Connected ? UI.accent : '#97A6AE')
            }
            Text(this.stateLine()).fontSize(13).fontColor(UI.muted)
          }
        }.alignItems(HorizontalAlign.Start).padding(24).width('74%')
      }.width('100%').height(174)
        .onAreaChange((_old: Area, area: Area) => { this.stageWidth = Number(area.width); })
      Row({ space: 20 }) {
        this.Rate(this.upRate, '↑ 上传')
        Divider().vertical(true).height(48).color('#52616A')
        this.Rate(this.downRate, '↓ 下载')
      }.padding({ top: 18, bottom: 18, left: 24, right: 24 }).width('100%').backgroundColor(UI.stage)
    }.width(this.wide ? '48%' : '100%').backgroundColor(UI.surface)
      .borderRadius(28).clip(true).border({ width: 1, color: UI.line })
  }

  @Builder
  ConnectionTools() {
    Column({ space: 16 }) {
      Row() {
        Text('当前订阅').fontSize(13).fontColor(UI.muted).layoutWeight(1)
        Button('管理', { type: ButtonType.Normal }).height(48).fontSize(14)
          .backgroundColor(Color.Transparent).fontColor(UI.ink).onClick(() => { this.tabJump = 1; })
      }.width('100%')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          Text(this.profileName).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([UI.muted])
        }.padding(18).width('100%')
      }.width('100%').constraintSize({ minHeight: 80 }).borderRadius(24).backgroundColor(UI.surface)
        .onClick(() => { this.tabJump = 1; })
      Row({ space: 4 }) {
        ForEach(MODE_LABELS, (label: string, index: number) => {
          Button(label).layoutWeight(1).height(48).fontSize(14)
            .backgroundColor(this.mode === MODE_VALUES[index] ? UI.soft : Color.Transparent)
            .fontColor(this.mode === MODE_VALUES[index] ? UI.accent : UI.muted)
            .enabled(this.status === VpnStatus.Connected || this.status === VpnStatus.Disconnected)
            .onClick(() => this.changeMode(index))
        }, (label: string) => label)
      }.padding(4).borderRadius(28).backgroundColor(UI.surface).width('100%')
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([UI.accent])
          Text('节点与策略组').fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
        }.width('100%').padding(18)
      }.width('100%').constraintSize({ minHeight: 80 }).borderRadius(24)
        .backgroundColor(UI.soft).fontColor(UI.ink).enabled(this.status === VpnStatus.Connected)
        .onClick(() => { this.navStack.pushPath({ name: 'proxies' }); })
      // Keep the existing zashboard route gated by its integration owner.
      Button('诊断').height(48).backgroundColor(Color.Transparent).fontColor(UI.muted)
        .onClick(() => { this.navStack.pushPath({ name: 'diagnostics' }); })
    }.width(this.wide ? '48%' : '100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 12 }) {
      Text('连接').fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink)
        .width('100%').margin({ top: 16, bottom: 12 })
      Scroll() {
        Column({ space: 20 }) {
          if (this.profileName === '未导入') {
            Column({ space: 18 }) {
              Text('导入订阅').fontSize(36).fontWeight(FontWeight.Bold).fontColor(UI.ink)
              Button('添加订阅').width('100%').height(56).backgroundColor(UI.accent)
                .onClick(() => { this.tabJump = 1; })
            }.padding(24).width('100%').borderRadius(28).backgroundColor(UI.surface)
          } else {
            Flex({ direction: this.wide ? FlexDirection.Row : FlexDirection.Column,
              justifyContent: FlexAlign.SpaceBetween }) {
              this.ConnectionCard()
              this.ConnectionTools()
            }.width('100%')
          }
        }.width('100%').padding({ bottom: 12 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      if (this.profileName !== '未导入') {
        Button(this.status === VpnStatus.Disconnected ? '连接 VPN' :
          (this.status === VpnStatus.Connecting ? '取消连接' :
            (this.status === VpnStatus.Disconnecting ? '断开中…' : '断开连接')))
          .width('100%').height(56).fontSize(16).fontWeight(FontWeight.Medium)
          .backgroundColor(this.status === VpnStatus.Connected ? UI.soft : UI.accent)
          .fontColor(this.status === VpnStatus.Connected ? UI.accent : Color.White)
          .enabled(this.status !== VpnStatus.Disconnecting).onClick(() => this.toggle())
      }
    }.padding({ left: 24, right: 24, bottom: 12 }).width('100%').height('100%')
      .backgroundColor(UI.paper)
      .onAreaChange((_old: Area, area: Area) => { this.wide = Number(area.width) >= 700; })
  }
}
