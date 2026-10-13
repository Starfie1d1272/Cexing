import { CoreApi } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';
import { ConnectionFailures } from '../lib/ConnectionFailure';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { DiagnosticsService, DiagnosticCheckKind, DiagnosticCheckResult } from '../lib/DiagnosticsService';
import { DiagnosticsBundleView } from '../lib/DiagnosticsBundleView';

@Component
export struct DiagnosticsPage {
  @Consume('nav') navStack: NavPathStack;
  @State status: VpnStatus = VpnController.status;
  @State control: string = '尚未检查本机服务';
  @State checkedAt: string = '';
  @State busy: boolean = false;
  @State detailsOpen: boolean = false;
  @State checkLines: string[] = [];
  @State bundleFacts: string[] = [];
  @State exportMessage: string = '';
  @State proxyNames: string[] = [];
  @State proxyName: string = '';
  private results: DiagnosticCheckResult[] = [];
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

  private async check(kind: DiagnosticCheckKind = 'controller'): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const attempt = ++this.generation;
    this.busy = true;
    if (kind === 'controller') { this.checkedAt = ''; this.control = '正在检查…'; }
    const context = getContext(this) as common.UIAbilityContext;
    let timeoutId: number = -1;
    const fallback: DiagnosticCheckResult = { kind: kind, stage: 'host_deadline', outcome: 'unknown',
      at: new Date().toISOString(), durationMs: 15000, reason: 'page_check_timeout' };
    const result = await Promise.race<DiagnosticCheckResult>([
      DiagnosticsService.check(context, kind, this.proxyName).catch(() => {
        return { kind: kind, stage: 'host_check', outcome: 'failed', at: new Date().toISOString(), durationMs: 0 } as DiagnosticCheckResult;
      }),
      new Promise<DiagnosticCheckResult>((resolve) => { timeoutId = setTimeout(() => resolve(fallback), 15000); })
    ]);
    if (timeoutId >= 0) { clearTimeout(timeoutId); }
    if (result.reason === 'page_check_timeout') {
      DiagnosticsService.record(context, { operation: `check_${kind}`, stage: 'host_deadline', outcome: 'unknown',
        reason: 'page_check_timeout', durationMs: 15000 }).catch(() => {});
    }
    if (!this.visible || attempt !== this.generation) { return; }
    const label = DiagnosticsBundleView.result(result);
    if (kind === 'controller') { this.control = label; this.checkedAt = result.at; }
    this.results = this.results.filter((item: DiagnosticCheckResult) => item.kind !== kind).concat([result]);
    this.checkLines = this.results.map((item: DiagnosticCheckResult) =>
      `${DiagnosticsBundleView.title(item.kind)}：${DiagnosticsBundleView.result(item)} · ${item.at} · ${item.durationMs} ms`);
    if (result.details?.['evidencePersisted'] === false) { this.exportMessage = '本次检查证据未保存成功，请重试导出'; }
    this.busy = false;
    promptAction.showToast({ message: label });
  }

  private async chooseProxy(): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const attempt = this.generation;
    this.busy = true;
    const proxies = await CoreApi.getProxies().catch(() => null);
    if (!this.visible || attempt !== this.generation) { return; }
    this.proxyNames = proxies === null ? [] : Object.keys(proxies);
    this.busy = false;
    if (this.proxyNames.length === 0) { this.exportMessage = '测试代理列表未读取到，请连接后重试'; }
  }

  private async exportSupport(share: boolean): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const attempt = this.generation;
    this.busy = true;
    const context = getContext(this) as common.UIAbilityContext;
    this.exportMessage = '正在准备诊断支持包…';
    try {
      const bundle = await DiagnosticsService.exportBundle(context);
      if (!this.visible || attempt !== this.generation) { return; }
      this.bundleFacts = DiagnosticsBundleView.facts(bundle.json);
      if (share) {
        // File URI avoids ShareKit's 200 KB text IPC limit and preserves the
        // reviewed snapshot if another export replaces the service cache file.
        const snapshot = `${context.cacheDir}/cexing-support-share.json`;
        fileIo.copyFileSync(bundle.path, snapshot);
        const data = new systemShare.SharedData({ utd: uniformTypeDescriptor.UniformDataType.FILE,
          uri: fileUri.getUriFromPath(snapshot), title: '策星诊断支持包', label: 'FILE' });
        await new systemShare.ShareController(data).show(context, {});
        if (this.visible && attempt === this.generation) { this.exportMessage = '已打开系统分享面板，请审核内容后选择接收应用'; }
      } else {
        const uris = await new picker.DocumentViewPicker(context).save({
          newFileNames: [bundle.fileName], fileSuffixChoices: ['诊断支持包|.json']
        });
        if (!this.visible || attempt !== this.generation) { return; }
        if (uris.length === 0) { this.exportMessage = '保存已取消，诊断包保留在应用中'; return; }
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try { fileIo.copyFileSync(bundle.path, file.fd); } finally { fileIo.closeSync(file); }
        this.exportMessage = '诊断支持包已保存，请审核证据范围后提交';
      }
    } catch (_) {
      if (this.visible && attempt === this.generation) { this.exportMessage = '诊断包保存或分享未完成，可重试；历史证据保留'; }
    } finally { if (attempt === this.generation) { this.busy = false; } }
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
            Text('这些检查分别验证本机 API、配置的 DNS 和所选代理；网站访问与系统隧道转发仍需单独确认。')
              .fontSize(14).fontColor(UI.muted).width('100%')
            Button('检查 DNS').height(48).enabled(!this.busy).onClick(() => this.check('dns'))
            Button('读取测试代理列表').height(48).enabled(!this.busy).onClick(() => this.chooseProxy())
            if (this.proxyNames.length > 0) {
              Select(this.proxyNames.map((name: string): SelectOption => ({ value: name })))
                .selected(this.proxyNames.indexOf(this.proxyName)).value(this.proxyName || '请选择测试代理')
                .onSelect((index: number) => { this.proxyName = this.proxyNames[index]; })
            }
            Button('检查代理连接').height(48).enabled(!this.busy).onClick(() => this.check('connection'))
            Button('检查代理延迟').height(48).enabled(!this.busy).onClick(() => this.check('delay'))
            ForEach(this.checkLines, (line: string) => { Text(line).fontSize(13).fontColor(UI.muted).width('100%') })
            Text('带宽测速在本页未执行。').fontSize(13).fontColor(UI.muted).width('100%')
            Text('本机服务响应正常后，请打开网站确认网络访问；访问异常时可在控制面板查看日志。')
              .fontSize(14).fontColor(UI.muted).width('100%')
            Text(VpnController.getKernelReadyReported() ? '内核已报告就绪' : '等待内核报告就绪')
              .fontSize(14).fontColor(UI.muted).width('100%')
          }
      Button(this.busy ? '检查中…' : '检查本机服务').width('100%').height(56)
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
      Button('保存诊断支持包').width('100%').height(48).enabled(!this.busy)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.exportSupport(false))
      Button('分享诊断包文件').width('100%').height(48).enabled(!this.busy)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.exportSupport(true))
      if (this.exportMessage !== '') { Text(this.exportMessage).fontSize(14).fontColor(UI.muted).width('100%') }
      if (this.bundleFacts.length > 0) {
        Text('本次诊断包的证据范围').fontSize(16).fontColor(UI.ink).width('100%')
        ForEach(this.bundleFacts, (fact: string) => { Text(fact).fontSize(13).fontColor(UI.muted).width('100%') })
      }
      Button('复制简短脱敏摘要').width('100%').height(48)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.copySummary())
      Text('保存诊断支持包，在 GitHub 模板中补充复现步骤，审核后提交；简短摘要仅用于快速说明。').fontSize(13).fontColor(UI.muted).width('100%')
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
