import { UiText } from '../lib/UiText';
import { SettingsReconnectButton } from './SettingsReconnectButton';
import { NativeTheme as UI } from './NativeTheme';
/*
 * NetworkSettingsPage.ets - 网络设置（设置 → 网络设置）
 * IPv6 / 系统 VPN 范围。改动在下次 VPN 启动时生效。
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings } from '../lib/Settings';
import { vpnRouteExceptions } from '../lib/VpnController';

const ACCESS_VALUES: string[] = ['all', 'white', 'black'];

@Component
export struct NetworkSettingsPage {
  @Consume('nav') navStack: NavPathStack;
  @State saving: boolean = false;
  @State ipv6: boolean = false;
  @State accessIndex: number = 0;
  @State accessList: string[] = [];
  private pageActive: boolean = false;
  @State ready: boolean = false;
  private saveGeneration: number = 0;
  @State showRouteDetails: boolean = false;

  aboutToAppear(): void {
    this.pageActive = true;
    this.saving = false;
    this.saveGeneration++;
    const generation = this.saveGeneration;
    this.ready = false;
    this.readSettings();
    Settings.idle().then(() => {
      if (!this.pageActive || generation !== this.saveGeneration) { return; }
      this.readSettings(); this.ready = true;
    }).catch(() => {
      if (this.pageActive && generation === this.saveGeneration) {
        promptAction.showToast({ message: UiText.get($r('app.string.network_read_failed')) });
      }
    });
  }

  aboutToDisappear(): void { this.pageActive = false; this.saveGeneration++; this.showRouteDetails = false; }

  private readSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.ipv6 = s.ipv6;
    this.accessList = s.accessList;
    const idx = ACCESS_VALUES.indexOf(s.accessMode);
    this.accessIndex = idx >= 0 ? idx : 0;
  }

  private async persist(fields: string[]): Promise<void> {
    if (!this.pageActive || !this.ready || this.saving) { return; }
    this.saving = true;
    const generation = ++this.saveGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.ipv6 = this.ipv6;
    s.accessMode = ACCESS_VALUES[this.accessIndex];
    s.accessList = this.accessList;
    try {
      await Settings.save(context, s, fields);
      if (this.pageActive && generation === this.saveGeneration) { this.changedHint(); }
    } catch (_) {
      if (!this.pageActive || generation !== this.saveGeneration) { return; }
      this.aboutToAppear();
      promptAction.showToast({ message: UiText.get($r('app.string.network_save_failed')), duration: 2000 });
    } finally { if (this.pageActive && generation === this.saveGeneration) { this.saving = false; } }
  }

  private changedHint(): void {
    promptAction.showToast({ message: UiText.get($r('app.string.network_saved')), duration: 1500 });
  }

  private onNetworkPage(): boolean {
    const paths = this.navStack.getAllPathName();
    return this.pageActive && this.ready && paths[paths.length - 1] === 'network';
  }

  private restoreAll(): void {
    if (!this.onNetworkPage() || this.saving || this.accessIndex === 0) { return; }
    const generation = this.saveGeneration;
    AlertDialog.show({
      title: UiText.get($r('app.string.network_restore_all')),
      message: UiText.get($r('app.string.network_restore_all_confirm')),
      primaryButton: { value: UiText.get($r('app.string.action_cancel')), action: () => {} },
      secondaryButton: { value: UiText.get($r('app.string.network_restore_all')), action: () => {
        if (!this.onNetworkPage() || this.saving || generation !== this.saveGeneration) { return; }
        this.accessIndex = 0;
        this.persist(['accessMode']);
      } }
    });
  }

  private openTraffic(): void {
    if (!this.onNetworkPage() || this.saving) { return; }
    this.navStack.pushPath({ name: 'traffic' });
  }

  @Builder
  ToggleRow(title: string, sub: string, isOn: boolean, onFlip: (v: boolean) => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(UI.ink)
        if (sub.length > 0) {
          Text(sub)
            .fontSize(13)
            .fontColor(UI.muted)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(UI.accent)
        .onChange((v: boolean) => onFlip(v))
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
  }

  @Builder
  RouteDetails() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.network_routes'))).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink)
      Text(UiText.get($r('app.string.network_route_help')))
        .fontSize(13).fontColor(UI.muted).width('100%')
      ForEach(vpnRouteExceptions(), (cidr: string) => {
        Text(cidr).fontSize(14).fontColor(UI.ink).width('100%')
      }, (cidr: string) => cidr)
      Text(UiText.get($r('app.string.network_route_defaults'))).fontSize(13).fontColor(UI.muted).width('100%')
      Button(UiText.get($r('app.string.network_done'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.action).fontColor(UI.onAccent)
        .onClick(() => { this.showRouteDetails = false; })
    }.padding(20).backgroundColor(UI.surface)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        SettingsReconnectButton()
        Column() {
          this.ToggleRow('IPv6', UiText.get($r('app.string.network_next_start')), this.ipv6, (v: boolean) => {
            if (!this.onNetworkPage() || this.saving) { return; }
            this.ipv6 = v;
            this.persist(['ipv6']);
          })
        }
        .width('100%')
        .backgroundColor(UI.surface)
        .borderRadius(24)

        Column({ space: 12 }) {
          Text(UiText.get($r('app.string.network_sources'))).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink).width('100%')
          Button(UiText.get($r('app.string.network_open_sources'))).constraintSize({ minHeight: 48 }).width('100%').backgroundColor(UI.action).fontColor(UI.onAccent)
            .onClick(() => this.openTraffic())
          if (this.accessIndex > 0) {
            Text(UiText.get(this.accessIndex === 1 ? $r('app.string.network_scope_only') : $r('app.string.network_scope_except'), this.accessList.length))
              .fontSize(14).fontColor(UI.ink).width('100%')
            Button(UiText.get($r('app.string.network_restore_all'))).constraintSize({ minHeight: 48 }).width('100%').backgroundColor(UI.soft).fontColor(UI.accentText)
              .onClick(() => this.restoreAll())
          }
        }.padding(20).width('100%').backgroundColor(UI.surface).borderRadius(24)

        Button(UiText.get($r('app.string.network_routes'))).constraintSize({ minHeight: 48 }).width('100%').backgroundColor(UI.soft).fontColor(UI.ink)
          .onClick(() => { this.showRouteDetails = true; })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 8 })
    }
    .width('100%').height('100%').enabled(this.ready && !this.saving).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
    .bindSheet($$this.showRouteDetails, this.RouteDetails(), { height: SheetSize.MEDIUM })
  }
}
