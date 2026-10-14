import { AppRuntime } from '../lib/AppRuntime';
import { BackgroundState, LiveViewKeeper } from '../lib/LiveViewKeeper';
import { VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

// Mount once near the page's actions. Page release only removes this observer.
@Component
export struct BackgroundNotice {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @Prop @Watch('invalidate') status: VpnStatus = VpnStatus.Disconnected;
  @Prop @Watch('invalidate') visible: boolean = true;
  @Prop detailsOpen: boolean = false;
  @State private background: BackgroundState = AppRuntime.backgroundState();
  @State private busy: boolean = false;
  @State private retryFailed: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private off: (() => void) | null = null;

  aboutToAppear(): void {
    this.active = true;
    this.background = AppRuntime.backgroundState();
    this.off = AppRuntime.onBackgroundChanged((value: BackgroundState) => {
      this.background = value;
      if (!LiveViewKeeper.needsAttention(value)) { this.retryFailed = false; }
    });
  }

  aboutToDisappear(): void {
    this.active = false;
    this.invalidate();
    this.off?.();
    this.off = null;
  }

  private invalidate(): void {
    this.generation++;
    this.busy = false;
    this.retryFailed = false;
  }

  private attention(): boolean {
    return this.visible && this.status === VpnStatus.Connected && LiveViewKeeper.needsAttention(this.background);
  }

  private async retry(): Promise<void> {
    if (!this.active || !this.attention() || this.busy) { return; }
    const generation = this.generation;
    this.busy = true;
    const ok = await AppRuntime.retryBackground().catch(() => false);
    if (!this.active || !this.visible || generation !== this.generation) { return; }
    this.retryFailed = !ok;
    this.busy = false;
  }

  private settings(): void {
    this.invalidate();
    this.navStack.clear();
    this.tabJump = 2;
  }

  private taskLabel(): string {
    if (this.background.task === 'active') { return '已获后台任务'; }
    if (this.background.task === 'disabled') { return '后台运行已关闭'; }
    if (this.background.task === 'requesting') { return '正在申请后台任务'; }
    if (this.background.task === 'failed') { return '后台任务申请失败'; }
    if (this.background.task === 'revoked') { return '系统已撤销后台任务'; }
    if (this.background.task === 'user-stopped') { return '后台任务已由用户关闭'; }
    return this.background.suspended ? '后台任务已暂停' : '后台任务尚未确认';
  }

  private notificationLabel(): string {
    return this.background.notification === 'ready' ? '实况窗已发布' :
      (this.background.notification === 'failed' ? '实况窗发布失败' : '实况窗尚未确认');
  }

  build() {
    if (this.attention() || this.detailsOpen) {
    Column({ space: 8 }) {
    if (this.attention()) {
      Column({ space: 8 }) {
        Text(this.retryFailed ? '后台运行仍受限' : '后台运行受限').fontSize(14).fontColor(UI.error).width('100%')
        Row({ space: 12 }) {
          Button(this.busy ? '重试中…' : '重试').constraintSize({ minHeight: 44 }).layoutWeight(1)
            .enabled(!this.busy).backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.retry())
          Button('设置').constraintSize({ minHeight: 44 }).layoutWeight(1)
            .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.settings())
        }.width('100%')
      }.width('100%')
    }
    if (this.detailsOpen) {
      Text(this.taskLabel()).fontSize(13).fontColor(UI.muted).width('100%')
      Text(this.notificationLabel()).fontSize(13).fontColor(UI.muted).width('100%')
    }
    }.width('100%')
    }
  }
}
