import { common } from '@kit.AbilityKit';
import { ConnectionEntry } from '../lib/ConnectionEntry';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct ConnectionEntryPage {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tabJump') tabJump: number;
  @StorageLink('connectionEntryRequest') @Watch('refresh') entryRequest: number = 0;
  @StorageLink('connectionStateRevision') @Watch('refresh') stateRevision: number = 0;
  @State label: string = '';
  @State desired: string = '';
  @State canSubmit: boolean = false;
  @State message: string = '';
  private displayedRequest: number = 0;
  private displayedRevision: number = 0;
  private visible: boolean = false;

  aboutToAppear(): void { this.visible = true; this.refresh(); }
  aboutToDisappear(): void { this.visible = false; }

  private refresh(): void {
    this.displayedRequest = ConnectionEntry.request;
    this.displayedRevision = ConnectionEntry.revision;
    this.label = ConnectionEntry.label();
    this.desired = ConnectionEntry.action === 'connect' ? '连接 VPN' : '断开 / 取消连接';
    this.canSubmit = ConnectionEntry.canConfirm();
    this.message = '';
  }

  private async confirm(): Promise<void> {
    const request = this.displayedRequest;
    const revision = this.displayedRevision;
    this.canSubmit = false;
    const message = await ConnectionEntry.confirm(getContext(this) as common.UIAbilityContext, request, revision);
    if (this.visible && request === ConnectionEntry.request) {
      this.refresh();
      this.message = message;
    }
  }

  build() {
    Column({ space: 24 }) {
      Text(this.label).fontSize(28).fontWeight(FontWeight.Medium).fontColor(UI.ink).width('100%')
      Text('请核对当前状态，再确认操作。连接时可能需要系统授权；停止结果未知时请检查系统 VPN。')
        .fontSize(16).fontColor(UI.muted).width('100%')
      Button(`确认${this.desired}`).width('100%').height(56).backgroundColor(UI.action)
        .fontColor(UI.onAccent).enabled(this.canSubmit).onClick(() => this.confirm())
      if (!this.canSubmit) {
        Text('操作已提交、状态正在变化或尚未确认。请打开连接页查看状态与订阅。')
          .fontSize(14).fontColor(UI.muted).width('100%')
      }
      if (this.message.length > 0) { Text(this.message).fontSize(14).fontColor(UI.ink).width('100%') }
      Button('打开连接页').width('100%').height(56).backgroundColor(UI.soft).fontColor(UI.accentText)
        .onClick(() => { this.tabJump = 0; this.navStack.clear(); })
    }.padding(24).width('100%').height('100%').backgroundColor(UI.paper)
  }
}
