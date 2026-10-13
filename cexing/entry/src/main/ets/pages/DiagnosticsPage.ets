import { CoreApi } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';
import { ConnectionFailures } from '../lib/ConnectionFailure';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';

@Component
export struct DiagnosticsPage {
  @Consume('nav') navStack: NavPathStack;
  @State status: VpnStatus = VpnController.status;
  @State control: string = '尚未检查本机服务';
  @State checkedAt: string = '';
  @State busy: boolean = false;
  @State detailsOpen: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    if (this.status === status) { return; }
    this.status = status;
    this.checkedAt = '';
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
    this.busy = false;
    this.control = '尚未检查本机服务';
    this.checkedAt = '';
    VpnController.offChanged(this.listener);
  }

  private async check(): Promise<void> {
    if (this.busy) { return; }
    const attempt = ++this.generation;
    this.busy = true;
    this.checkedAt = '';
    this.control = '正在检查…';
    let timeoutId: number = -1;
    const result = await Promise.race<string>([
      CoreApi.checkController().catch(() => 'failed'),
      new Promise<string>((resolve) => { timeoutId = setTimeout(() => resolve('timeout'), 5000); })
    ]);
    if (timeoutId >= 0) { clearTimeout(timeoutId); }
    if (!this.visible || attempt !== this.generation) { return; }
    this.control = result === 'reachable' ? '本机服务可达' :
      result === 'timeout' ? '检查超时' :
      result === 'credentials' ? '连接信息不可用，请重新连接' :
      result === 'authorization' ? '连接认证失败，请断开后重新连接' :
      '本机服务无响应，请确认连接后重试';
    this.checkedAt = new Date().toISOString();
    this.busy = false;
    promptAction.showToast({ message: result === 'reachable' ? '检查完成，本机服务响应正常' : this.control });
  }

  private connection(): string {
    if (this.status === VpnStatus.Connected) { return '已连接'; }
    if (this.status === VpnStatus.Connecting) { return '正在连接'; }
    if (this.status === VpnStatus.Disconnecting) { return '正在断开'; }
    return '未连接';
  }

  private async copySummary(): Promise<void> {
    const attempt = this.generation;
    const checkedAt = this.checkedAt;
    const states = ['disconnected', 'connecting', 'connected', 'disconnecting'];
    const control = this.control === '本机服务可达' ? 'reachable' :
      this.control === '检查超时' ? 'timeout' :
      this.control === '尚未检查本机服务' || this.busy ? 'not-run' : 'failed';
    try {
      const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (!this.visible || attempt !== this.generation) { return; }
      const version = `${bundle.versionName}+${bundle.versionCode}`;
      const system = /^[A-Za-z0-9 ._()+-]{1,128}$/.test(deviceInfo.osFullName) ? deviceInfo.osFullName : 'unknown';
      const text = ConnectionFailures.summary(states[this.status], control,
        VpnController.getLastStartFailure(), version, VpnController.getTunCreateObserved(),
        VpnController.getKernelReadyReported()) + `\nsystem_version=${system}\ncontroller_checked_at=${checkedAt || 'not-run'}`;
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

  private async openFeedback(): Promise<void> {
    try {
      await (getContext(this) as common.UIAbilityContext).startAbility({
        action: 'ohos.want.action.viewData',
        uri: 'https://github.com/Starfie1d1272/Cexing/issues/new?template=diagnostics.yml'
      });
    } catch (_) {
      promptAction.showToast({ message: '打开失败，请在 GitHub 仓库的问题页提交反馈' });
    }
  }

  build() {
    Column({ space: 20 }) {
      Scroll() {
        Column({ space: 16 }) {
          Text('连接检查').fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
          Column() {
            Row({ space: 16 }) {
              Text('连接状态').fontSize(15).fontColor(UI.ink).layoutWeight(1)
              Text(this.connection()).fontSize(14).fontColor(UI.muted).textAlign(TextAlign.End)
            }.width('100%').constraintSize({ minHeight: 64 }).padding(18)
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            Column({ space: 8 }) {
              Text('本机服务').fontSize(13).fontColor(UI.muted)
              Text(this.control).fontSize(17).fontColor(UI.ink).width('100%')
              if (this.checkedAt !== '') {
                Text(`检查时间：${this.checkedAt}`).fontSize(12).fontColor(UI.muted).width('100%')
              }
            }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
          }.width('100%').borderRadius(24).backgroundColor(UI.surface)
          if (this.control === '检查超时') {
            Text('请重试检查；若仍超时，请断开后重新连接。').fontSize(14).fontColor(UI.error).width('100%')
          }
          if (VpnController.getLastStartFailure() !== null) {
            Text(`最近启动失败：${ConnectionFailures.label(VpnController.getLastStartFailure()!)}`)
              .fontSize(14).fontColor(UI.error).width('100%')
          }
          Button(this.detailsOpen ? '收起技术详情' : '查看技术详情').height(48)
            .backgroundColor(UI.surface).fontColor(UI.accentText).onClick(() => { this.detailsOpen = !this.detailsOpen; })
          if (this.detailsOpen) {
            Text('本机服务响应正常后，请打开网站确认网络访问；访问异常时可在控制面板查看日志。')
              .fontSize(14).fontColor(UI.muted).width('100%')
            Text(VpnController.getKernelReadyReported() ? '内核已报告就绪' : '等待内核报告就绪')
              .fontSize(14).fontColor(UI.muted).width('100%')
          }
      Button(this.busy ? '检查中…' : '检查本机服务').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
      Button('复制脱敏摘要').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.copySummary())
      Text('复制摘要后，在 GitHub 模板中补充复现步骤，审核后提交。').fontSize(13).fontColor(UI.muted).width('100%')
      Button('打开 GitHub 反馈模板').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.openFeedback())
      Button('打开控制面板').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).enabled(this.status === VpnStatus.Connected)
        .onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
        }.width('100%')
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(24).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
