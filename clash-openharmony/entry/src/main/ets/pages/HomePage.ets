import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi, TrafficMsg, formatRate } from '../lib/CoreApi';
import { ProfileStore } from '../lib/ProfileStore';
import { Settings } from '../lib/Settings';

const MODE_LABELS: string[] = ['规则', '全局', '直连'];
const MODE_VALUES: string[] = ['rule', 'global', 'direct'];

@Component
export struct HomePage {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @State status: VpnStatus = VpnController.status;
  @State profileName: string = '未导入';
  @State upRate: string = '—';
  @State downRate: string = '—';
  @State mode: string = 'rule';
  private watcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private visible: boolean = false;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    this.status = status;
    if (this.visible) {
      this.refreshTraffic();
      const message = VpnController.consumeLastStartError();
      if (message.length > 0) {
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
  }

  aboutToDisappear(): void {
    this.visible = false;
    VpnController.offChanged(this.listener);
    this.watcher.stop();
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
    if (this.visible && this.currentVisibleTab === 0 && this.status === VpnStatus.Connected) {
      this.watcher.start('/traffic', (traffic: TrafficMsg) => {
        this.upRate = formatRate(traffic.up);
        this.downRate = formatRate(traffic.down);
      });
    }
  }

  private toggle(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    if (this.status === VpnStatus.Disconnected) {
      if (ProfileStore.getActiveFile(ctx).length === 0) {
        this.tabJump = 1;
        return;
      }
      VpnController.start(ctx);
    } else if (this.status === VpnStatus.Connected || this.status === VpnStatus.Connecting) {
      VpnController.stop(ctx);
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
    return '未连接';
  }

  build() {
    Column({ space: 20 }) {
      Text('ClashOH').fontSize(26).fontWeight(FontWeight.Bold)
      Text(this.label()).fontSize(20)
      Button(this.status === VpnStatus.Disconnected ? '连接' :
        (this.status === VpnStatus.Connecting ? '取消连接' : '断开'))
        .enabled(this.status !== VpnStatus.Disconnecting)
        .onClick(() => this.toggle())
      Text(`当前配置：${this.profileName}`)
      Text(`↑ ${this.upRate}    ↓ ${this.downRate}`)
      Row({ space: 12 }) {
        ForEach(MODE_LABELS, (label: string, index: number) => {
          Button(label)
            .enabled(this.mode !== MODE_VALUES[index] &&
              (this.status === VpnStatus.Connected || this.status === VpnStatus.Disconnected))
            .onClick(() => this.changeMode(index))
        }, (label: string) => label)
      }
      Button('管理配置').onClick(() => { this.tabJump = 1; })
      Button('代理组')
        .enabled(this.status === VpnStatus.Connected)
        .onClick(() => { this.navStack.pushPath({ name: 'proxies' }); })
    }
    .padding(24)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
