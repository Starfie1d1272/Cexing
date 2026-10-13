import { CoreApi } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';
import { ConnectionFailures } from '../lib/ConnectionFailure';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';

@Component
export struct DiagnosticsPage {
  @Consume('nav') navStack: NavPathStack;
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
    let timeoutId: number = -1;
    const result = await Promise.race<string>([
      CoreApi.isAlive().then((alive: boolean) => alive ? 'reachable' : 'failed').catch(() => 'failed'),
      new Promise<string>((resolve) => { timeoutId = setTimeout(() => resolve('timeout'), 5000); })
    ]);
    if (timeoutId >= 0) { clearTimeout(timeoutId); }
    if (!this.visible || attempt !== this.generation) { return; }
    this.control = result === 'reachable' ? '本机服务可达' :
      result === 'timeout' ? '检查超时' : '检查失败';
    this.busy = false;
  }

  private kernel(): string {
    if (this.status === VpnStatus.Connected) { return '宿主报告已就绪'; }
    if (this.status === VpnStatus.Connecting) { return '启动中'; }
    if (this.status === VpnStatus.Disconnecting) { return '停止中'; }
    return '未连接';
  }

  private async copySummary(): Promise<void> {
    const attempt = this.generation;
    const states = ['disconnected', 'connecting', 'connected', 'disconnecting'];
    const control = this.control === '本机服务可达' ? 'reachable' :
      this.control === '检查超时' ? 'timeout' :
      this.control === '检查失败' ? 'failed' : 'not-run';
    try {
      const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (!this.visible || attempt !== this.generation) { return; }
      const version = `${bundle.versionName}+${bundle.versionCode}`;
      const text = ConnectionFailures.summary(states[this.status], control,
        VpnController.getLastStartFailure(), version);
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      if (this.visible && attempt === this.generation) {
        promptAction.showToast({ message: '脱敏摘要已复制' });
      }
    } catch (_) {
      if (this.visible && attempt === this.generation) {
        promptAction.showToast({ message: '复制失败，请重试' });
      }
    }
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
          if (VpnController.getLastStartFailure() !== null) {
            Text(`最近启动失败：${ConnectionFailures.label(VpnController.getLastStartFailure()!)}`)
              .fontSize(14).fontColor(UI.error).width('100%')
          }
        }.width('100%')
      }.width('100%').layoutWeight(1)
      Button(this.busy ? '检查中…' : '检查控制面').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
      Button('复制脱敏摘要').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.copySummary())
      Button('打开面板查看日志').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).enabled(this.status === VpnStatus.Connected)
        .onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
    }.width('100%').height('100%').padding(24).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
