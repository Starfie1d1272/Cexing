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
        promptAction.showToast({ message: '设置读取失败，请重试' });
      }
    });
  }

  private readSettings(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.mixedPort = String(s.mixedPort);
    this.logLevel = s.logLevel;
    this.allowLan = s.allowLan;
  }

  private async persist(): Promise<void> {
    if (!this.pageActive || !this.ready) { return; }
    const generation = ++this.saveGeneration;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    const port = Number(this.mixedPort);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      this.portError = '端口须为 1–65535';
      return;
    }
    this.portError = '';
    s.mixedPort = port;
    s.logLevel = this.logLevel;
    try { await Settings.save(context, s, ['mixedPort', 'logLevel']); }
    catch (_) { if (!this.pageActive || generation !== this.saveGeneration) { return; } this.portError = '保存失败，请重试'; return; }
    if (!this.pageActive || generation !== this.saveGeneration) { return; }
    promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
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
      promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
    } catch (_) {
      if (!this.pageActive || generation !== this.lanDialogGeneration) { return; }
      this.allowLan = Settings.load(context).allowLan;
      this.lanError = enabled ? '开启保存失败，请重试' :
        '撤销保存失败，原授权仍可能有效，请再次关闭重试；当前共享不会自动停止';
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
      title: '允许同网设备使用代理？',
      message: '开启后，同一局域网设备可能无需认证即可使用手机代理，消耗手机网络和代理流量。请仅在可信网络主动共享。此操作不会开放局域网 DNS；下次启动 VPN 生效。',
      cancel: () => { this.lanDialogGeneration++; this.allowLan = false; },
      primaryButton: { value: '取消', action: () => {
        this.lanDialogGeneration++; this.allowLan = false;
      } },
      secondaryButton: { value: '确认开启', action: () => {
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
              Text('混合代理端口')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .layoutWeight(1)
              TextInput({ text: this.mixedPort })
                .width(110)
                .height(48)
                .textAlign(TextAlign.End)
                .onChange((v: string) => {
                  this.mixedPort = v;
                })
                .type(InputType.Number)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8, left: 14, right: 14 })

            Divider().color(UI.line).margin({ left: 14 })

            Row() {
              Text('允许局域网连接')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.allowLan })
                .selectedColor(UI.accent)
                .onChange((v: boolean) => {
                  this.changeAllowLan(v);
                })
            }
            .width('100%')
            .padding({ top: 13, bottom: 13, left: 14, right: 14 })

            Divider().color(UI.line).margin({ left: 14 })

            Column({ space: 8 }) {
              Text('日志等级')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(UI.ink)
                .width('100%')
              Select(LOG_OPTIONS)
                .selected(LOG_LEVELS.indexOf(this.logLevel)).value(this.logLevel)
                .font({ size: 14 }).height(48).width('100%')
                .onSelect((index: number) => { this.logLevel = LOG_LEVELS[index]; })
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
      SettingsReconnectButton()
      Button('保存').width('100%').height(56).backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.persist())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
    .enabled(this.ready).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
