import { UiText } from '../lib/UiText';
import { SettingsReconnectButton } from './SettingsReconnectButton';
import { NativeTheme as UI } from './NativeTheme';
/*
 * OverridePage.ets - 覆写（设置 → 覆写）
 * 合并进内核配置的本地覆写项，下次 VPN 启动生效
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings } from '../lib/Settings';

const LOG_LEVELS: string[] = ['silent', 'error', 'warning', 'info', 'debug'];
const LOG_OPTIONS: SelectOption[] = [
  { value: 'silent' }, { value: 'error' }, { value: 'warning' }, { value: 'info' }, { value: 'debug' }
];

@Component
export struct OverridePage {
  @State mixedPort: string = '7890';
  @State logLevel: string = 'info';
  @State allowLan: boolean = false;
  @State portError: string = '';
  @State lanError: string = '';
  @State dirty: boolean = false;
  private lanDialogGeneration: number = 0;
  private saveGeneration: number = 0;
  private pageActive: boolean = false;
  @State ready: boolean = false;

  aboutToAppear(): void {
    this.pageActive = true;
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

  private readSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.mixedPort = String(s.mixedPort);
    this.logLevel = s.logLevel;
    this.allowLan = s.allowLan;
    this.dirty = false;
  }

  private async persist(): Promise<void> {
    if (!this.pageActive || !this.ready) { return; }
    const generation = ++this.saveGeneration;
    const lanGeneration = this.lanDialogGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    const port = Number(this.mixedPort);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      this.portError = UiText.get($r('app.string.core_port_invalid'));
      return;
    }
    this.portError = '';
    s.mixedPort = port;
    s.logLevel = this.logLevel;
    try { await Settings.save(context, s, ['mixedPort', 'logLevel']); }
    catch (_) { if (!this.pageActive || generation !== this.saveGeneration) { return; } this.portError = UiText.get($r('app.string.network_save_failed')); return; }
    if (!this.pageActive || generation !== this.saveGeneration || this.mixedPort !== String(port) || this.logLevel !== s.logLevel) { return; }
    this.dirty = false;
    if (lanGeneration === this.lanDialogGeneration) { this.allowLan = Settings.load(context).allowLan; this.lanError = ''; }
    promptAction.showToast({ message: UiText.get($r('app.string.network_saved')), duration: 1500 });
  }

  aboutToDisappear(): void {
    this.pageActive = false; this.saveGeneration++;
    this.lanDialogGeneration++;
  }

  private async saveAllowLan(enabled: boolean): Promise<void> {
    const generation = this.lanDialogGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await Settings.setAllowLan(context, enabled);
      if (!this.pageActive || generation !== this.lanDialogGeneration) { return; }
      this.allowLan = enabled;
      this.lanError = '';
      promptAction.showToast({ message: UiText.get($r('app.string.network_saved')), duration: 1500 });
    } catch (_) {
      if (!this.pageActive || generation !== this.lanDialogGeneration) { return; }
      this.allowLan = Settings.load(context).allowLan;
      this.lanError = enabled ? UiText.get($r('app.string.core_enable_failed')) :
        UiText.get($r('app.string.core_revoke_failed'));
      promptAction.showToast({ message: this.lanError, duration: 4000 });
    }
  }

  private changeAllowLan(enabled: boolean): void {
    if (!this.pageActive || !this.ready) { return; }
    const generation = ++this.lanDialogGeneration;
    if (!enabled) {
      this.allowLan = false;
      this.saveAllowLan(false);
      return;
    }
    this.allowLan = true;
    AlertDialog.show({
      title: UiText.get($r('app.string.core_lan_title')),
      message: UiText.get($r('app.string.core_lan_risk')),
      cancel: () => { this.lanDialogGeneration++; this.allowLan = false; },
      primaryButton: { value: UiText.get($r('app.string.network_cancel')), action: () => {
        this.lanDialogGeneration++; this.allowLan = false;
      } },
      secondaryButton: { value: UiText.get($r('app.string.core_confirm_enable')), action: () => {
        if (generation === this.lanDialogGeneration) {
          this.lanDialogGeneration++;
          this.saveAllowLan(true);
        }
      } }
    });
  }

  build() {
    Column({ space: 12 }) {
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 0 }) {
            Row() {
              Text(UiText.get($r('app.string.core_port')))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .layoutWeight(1)
              TextInput({ text: this.mixedPort }).accessibilityText(UiText.get($r('app.string.core_port')))
                .width(110)
                .constraintSize({ minHeight: 48 })
                .textAlign(TextAlign.End)
                .onChange((v: string) => {
                  this.mixedPort = v; this.dirty = true;
                })
                .type(InputType.Number)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8, left: 14, right: 14 })

            Divider().color(UI.line).margin({ left: 14 })

            Row() {
              Text(UiText.get($r('app.string.core_allow_lan')))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.allowLan }).accessibilityText(UiText.get($r('app.string.core_allow_lan'))).accessibilityChecked(this.allowLan)
                .selectedColor(UI.accent)
                .onChange((v: boolean) => {
                  this.changeAllowLan(v);
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13, left: 14, right: 14 })

            Divider().color(UI.line).margin({ left: 14 })

            Column({ space: 8 }) {
              Text(UiText.get($r('app.string.core_log_level')))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .width('100%')
              Select(LOG_OPTIONS).backgroundColor(UI.soft).fontColor(UI.ink).accessibilityText(UiText.get($r('app.string.core_log_level')))
                .selected(LOG_LEVELS.indexOf(this.logLevel)).value(this.logLevel)
                .font({ size: 14 }).constraintSize({ minHeight: 48 }).width('100%')
                .onSelect((index: number) => { this.logLevel = LOG_LEVELS[index]; this.dirty = true; })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 13, bottom: 13, left: 14, right: 14 })
          }
          .width('100%')
          .backgroundColor(UI.surface)
          .borderRadius(24)

          if (this.portError.length > 0) {
            Text(this.portError).fontSize(14).fontColor(UI.error).width('100%')
          }
          if (this.lanError.length > 0) {
            Text(this.lanError).fontSize(14).fontColor(UI.error).width('100%')
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      SettingsReconnectButton({ canApply: !this.dirty })
      Button(UiText.get($r('app.string.core_save'))).width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.persist())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
    .enabled(this.ready).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
