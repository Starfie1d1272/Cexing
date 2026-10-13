import { CoreApi } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct DiagnosticsPage {
  @State status: VpnStatus = VpnController.status;
  @State control: string = '尚未检查';
  @State busy: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    this.status = status;
    this.control = '尚未检查';
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
    this.control = alive ? 'Controller 可达' : 'Controller 不可达';
    this.busy = false;
  }

  private kernel(): string {
    if (this.status === VpnStatus.Connected) { return '宿主报告已就绪'; }
    if (this.status === VpnStatus.Connecting) { return '启动中'; }
    if (this.status === VpnStatus.Disconnecting) { return '停止中'; }
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
          Column() {
            this.Fact('系统会话', '需设备确认')
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            this.Fact('内核', this.kernel())
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            this.Fact('控制面', this.control)
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            this.Fact('真实转发', '需设备验证')
          }.width('100%').borderRadius(24).backgroundColor(UI.surface)
          Text('就绪与控制面可达不代表流量已通过系统隧道。')
            .fontSize(13).fontColor(UI.muted).width('100%')
        }.width('100%')
      }.width('100%').layoutWeight(1)
      Button(this.busy ? '检查中…' : '检查控制面').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
    }.width('100%').height('100%').padding(24).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
