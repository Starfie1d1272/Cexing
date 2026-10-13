import { CoreApi } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct DiagnosticsPage {
  @State status: VpnStatus = VpnController.status;
  @State control: string = '尚未检查本机服务';
  @State busy: boolean = false;
  @State detailsOpen: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    this.status = status;
    this.control = '尚未检查本机服务';
    this.generation++;
    this.busy = false;
  };

  aboutToAppear(): void {
    this.visible = true;
    this.status = VpnController.status;
    VpnController.onChanged(this.listener);
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.generation++;
    VpnController.offChanged(this.listener);
  }

  private async check(): Promise<void> {
    if (this.busy) { return; }
    const attempt = ++this.generation;
    this.busy = true;
    const alive = await CoreApi.isAlive();
    if (!this.visible || attempt !== this.generation) { return; }
    this.control = alive ? '本机服务有响应' : '本机服务无响应，请确认连接后重试';
    this.busy = false;
  }

  private connection(): string {
    if (this.status === VpnStatus.Connected) { return '应用报告已连接'; }
    if (this.status === VpnStatus.Connecting) { return '正在连接'; }
    if (this.status === VpnStatus.Disconnecting) { return '正在断开'; }
    return '未连接';
  }

  @Builder
  Fact(title: string, value: string) {
    Row({ space: 16 }) {
      Text(title).fontSize(15).fontColor(UI.ink).layoutWeight(1)
      Text(value).fontSize(14).fontColor(UI.muted).textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '60%' })
    }.width('100%').constraintSize({ minHeight: 64 }).padding(18)
  }

  build() {
    Column({ space: 20 }) {
      Scroll() {
        Column({ space: 16 }) {
          Text('连接检查').fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
          Column() {
            this.Fact('连接状态', this.connection())
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            this.Fact('本机服务', this.control)
          }.width('100%').borderRadius(24).backgroundColor(UI.surface)
          Text('这项检查只查看应用状态和本机服务。要确认网站能否打开，请在连接后用设备访问网页。')
            .fontSize(14).fontColor(UI.muted).width('100%')
          Button(this.detailsOpen ? '收起技术详情' : '查看技术详情').height(48)
            .backgroundColor(UI.surface).fontColor(UI.accentText).onClick(() => { this.detailsOpen = !this.detailsOpen; })
          if (this.detailsOpen) {
            Column() {
              this.Fact('VPN 系统会话', '此页无法独立确认')
              Divider().color(UI.line).margin({ left: 18, right: 18 })
              this.Fact('内核就绪', this.status === VpnStatus.Connected ? '扩展报告已就绪' : '尚未报告就绪')
              Divider().color(UI.line).margin({ left: 18, right: 18 })
              this.Fact('Controller', this.control)
              Divider().color(UI.line).margin({ left: 18, right: 18 })
              this.Fact('真实转发', '此页未测试')
            }.width('100%').borderRadius(24).backgroundColor(UI.surface)
          }
        }.width('100%')
      }.width('100%').layoutWeight(1)
      Button(this.busy ? '检查中…' : '检查本机服务').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
    }.width('100%').height('100%').padding(24).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
