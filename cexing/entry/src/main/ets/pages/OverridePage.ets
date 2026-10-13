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
  @State allowLan: boolean = true;
  @State portError: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.mixedPort = String(s.mixedPort);
    this.logLevel = s.logLevel;
    this.allowLan = s.allowLan;
  }

  private persist(): void {
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
    s.allowLan = this.allowLan;
    Settings.save(context, s);
    promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
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
                  this.allowLan = v;
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

          Text('下次启动生效 · 订阅 Merge 尚未接入')
            .fontSize(13).fontColor(UI.muted).width('100%')
          if (this.portError.length > 0) {
            Text(this.portError).fontSize(14).fontColor(UI.error).width('100%')
          }
        }.width('100%')
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
      Button('保存').width('100%').height(56).backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.persist())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 16 })
    .backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
