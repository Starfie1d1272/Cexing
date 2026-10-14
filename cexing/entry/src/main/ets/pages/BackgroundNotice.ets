import { UiText } from '../lib/UiText';
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
  @State private backgroundObservation: BackgroundState = AppRuntime.backgroundState();
  @State private busy: boolean = false;
  @State private retryFailed: boolean = false;
  private active: boolean = false;
  private generation: number = 0;
  private off: (() => void) | null = null;

  aboutToAppear(): void {
    this.active = true;
    this.backgroundObservation = AppRuntime.backgroundState();
    this.off = AppRuntime.onBackgroundChanged((value: BackgroundState) => {
      this.backgroundObservation = value;
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
    return this.visible && this.status === VpnStatus.Connected && LiveViewKeeper.needsAttention(this.backgroundObservation);
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
    if (this.backgroundObservation.task === 'active') { return UiText.get($r('app.string.background_acquired')); }
    if (this.backgroundObservation.task === 'disabled') { return UiText.get($r('app.string.background_disabled')); }
    if (this.backgroundObservation.task === 'requesting') { return UiText.get($r('app.string.background_requesting')); }
    if (this.backgroundObservation.task === 'failed') { return UiText.get($r('app.string.background_failed')); }
    if (this.backgroundObservation.task === 'revoked') { return UiText.get($r('app.string.background_revoked')); }
    if (this.backgroundObservation.task === 'user-stopped') { return UiText.get($r('app.string.background_user_stopped')); }
    return this.backgroundObservation.suspended ? UiText.get($r('app.string.background_suspended')) : UiText.get($r('app.string.background_unknown'));
  }

  private notificationLabel(): string {
    return this.backgroundObservation.notification === 'ready' ? UiText.get($r('app.string.background_notification_ready')) :
      (this.backgroundObservation.notification === 'failed' ? UiText.get($r('app.string.background_notification_failed')) : UiText.get($r('app.string.background_notification_unknown')));
  }

  build() {
    if (this.attention() || this.detailsOpen) {
    Column({ space: 8 }) {
    if (this.attention()) {
      Column({ space: 8 }) {
        Text(this.retryFailed ? UiText.get($r('app.string.background_still_limited')) : UiText.get($r('app.string.background_limited'))).fontSize(14).fontColor(UI.error).width('100%')
        Row({ space: 12 }) {
          Button(this.busy ? UiText.get($r('app.string.action_retrying')) : UiText.get($r('app.string.action_retry'))).constraintSize({ minHeight: 44 }).layoutWeight(1)
            .enabled(!this.busy).backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.retry())
          Button(UiText.get($r('app.string.action_settings'))).constraintSize({ minHeight: 44 }).layoutWeight(1)
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
