import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { ProfileRecovery } from '../lib/ProfileRecovery';
import { ProfileStore } from '../lib/ProfileStore';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct SettingsReconnectButton {
  @Prop canApply: boolean = true;
  @Consume('nav') navStack: NavPathStack;
  @Consume('tab') @Watch('onVisibilityChanged') currentVisibleTab: number = 2;
  @Consume('rootVisible') @Watch('onVisibilityChanged') rootVisible: boolean = true;
  @State connected: boolean = false;
  @State working: boolean = false;
  @State confirming: boolean = false;
  private active: boolean = false;
  private request: number = 0;
  private listener: (() => void) | null = null;

  private onVisibilityChanged(): void { this.request++; this.confirming = false; this.working = false; }

  aboutToAppear(): void {
    this.active = true;
    this.connected = VpnController.status === VpnStatus.Connected;
    this.listener = () => { this.connected = VpnController.status === VpnStatus.Connected; };
    VpnController.onChanged(this.listener);
  }
  aboutToDisappear(): void {
    this.active = false; this.request++; this.working = false; this.confirming = false;
    if (this.listener !== null) { VpnController.offChanged(this.listener); this.listener = null; }
  }
  private confirm(): void {
    if (!this.canApply || this.working || this.confirming) { return; }
    const context = getContext(this) as common.UIAbilityContext;
    const request = ++this.request;
    const epoch = VpnController.configurationEpoch();
    const paths = this.navStack.getAllPathName().slice();
    const tab = this.currentVisibleTab;
    const root = this.rootVisible;
    let file = '';
    try { file = ProfileStore.getActiveFile(context); }
    catch (_) { promptAction.showToast({ message: UiText.get($r('app.string.failure_config_read')) }); return; }
    const current = (): boolean => {
      try {
        const now = this.navStack.getAllPathName();
        return this.canApply && this.active && request === this.request && tab === this.currentVisibleTab && root === this.rootVisible &&
          paths.length === now.length && paths.every((value: string, index: number) => value === now[index]) &&
          ProfileStore.getActiveFile(context) === file;
      }
      catch (_) { return false; }
    };
    this.confirming = true;
    AlertDialog.show({
      title: UiText.get($r('app.string.settings_reconnect_title')), message: UiText.get($r('app.string.settings_reconnect_warning')),
      cancel: () => { if (request === this.request) { this.request++; this.confirming = false; } },
      primaryButton: { value: UiText.get($r('app.string.action_cancel')), action: () => { if (request === this.request) { this.request++; this.confirming = false; } } },
      secondaryButton: { value: UiText.get($r('app.string.action_reconnect')), action: async () => {
        if (request === this.request) { this.confirming = false; }
        if (!current() || epoch !== VpnController.configurationEpoch() || this.working) { return; }
        this.working = true;
        try {
          const accepted = await ProfileRecovery.reconnect(context, current);
          if (current() && !accepted) { promptAction.showToast({ message: UiText.get($r('app.string.failure_connect_not_started')) }); }
        } catch (error) {
          if (current()) { promptAction.showToast({ message: (error as Error).message }); }
        } finally { if (this.active && request === this.request) { this.working = false; } }
      } }
    });
  }
  build() {
    if (this.connected) {
      Button(this.working ? UiText.get($r('app.string.settings_reconnecting')) : UiText.get($r('app.string.settings_reconnect_apply')))
        .width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
        .accessibilityDescription(!this.canApply ? UiText.get($r('app.string.a11y_unsaved_settings')) :
          (this.working || this.confirming ? UiText.get($r('app.string.settings_reconnecting')) : ''))
        .enabled(this.canApply && !this.working && !this.confirming).onClick(() => this.confirm())
    }
  }
}
