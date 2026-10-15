import { UiText } from '../lib/UiText';
import { LiveViewStrategyPicker } from './LiveViewStrategyPicker';
import { BackgroundNotice } from './BackgroundNotice';
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
import { DiagnosticExportSnapshots, DiagnosticExportSnapshot } from '../lib/DiagnosticExportSnapshots';
import { DiagnosticsBundleView } from '../lib/DiagnosticsBundleView';

@Component
export struct DiagnosticsPage {
  @Consume('nav') navStack: NavPathStack;
  @State status: VpnStatus = VpnController.status;
  @State control: string = UiText.get($r('app.string.diag_not_checked'));
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
  private exportEpoch: number = 0;
  private exportAction: number = 0;
  private operationSequence: number = 0;
  private activeOperation: number = 0;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    if (this.status === status) { return; }
    this.status = status;
    this.checkedAt = '';
    this.control = UiText.get($r('app.string.diag_not_checked'));
    this.generation++;
    this.cancelOperation();
  };

  aboutToAppear(): void {
    this.visible = true;
    this.status = VpnController.status;
    VpnController.onChanged(this.listener);
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.exportEpoch++;
    this.generation++;
    this.cancelOperation();
    this.control = UiText.get($r('app.string.diag_not_checked'));
    this.checkedAt = '';
    VpnController.offChanged(this.listener);
  }

  private beginOperation(): number {
    const operation = ++this.operationSequence;
    this.activeOperation = operation;
    this.busy = true;
    return operation;
  }

  private ownsOperation(operation: number): boolean {
    return this.activeOperation === operation;
  }

  private finishOperation(operation: number): void {
    if (!this.ownsOperation(operation)) { return; }
    this.activeOperation = 0;
    this.busy = false;
  }

  private cancelOperation(): void {
    this.activeOperation = 0;
    this.busy = false;
  }

  private async check(kind: DiagnosticCheckKind = 'controller'): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const attempt = ++this.generation;
    const operation = this.beginOperation();
    if (kind === 'controller') { this.checkedAt = ''; this.control = UiText.get($r('app.string.diag_checking')); }
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
    if (!this.visible || attempt !== this.generation || !this.ownsOperation(operation)) { return; }
    const label = DiagnosticsBundleView.result(result);
    if (kind === 'controller') { this.control = label; this.checkedAt = result.at; }
    this.results = this.results.filter((item: DiagnosticCheckResult) => item.kind !== kind).concat([result]);
    this.checkLines = this.results.map((item: DiagnosticCheckResult) =>
      `${DiagnosticsBundleView.title(item.kind)}：${DiagnosticsBundleView.result(item)} · ${item.at} · ${item.durationMs} ms`);
    if (result.details?.['evidencePersisted'] === false) { this.exportMessage = UiText.get($r('app.string.diag_evidence_failed')); }
    this.finishOperation(operation);
    promptAction.showToast({ message: label });
  }

  private async chooseProxy(): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const attempt = this.generation;
    const operation = this.beginOperation();
    const proxies = await CoreApi.getProxies().catch(() => null);
    if (!this.visible || attempt !== this.generation || !this.ownsOperation(operation)) { return; }
    this.proxyNames = proxies === null ? [] : Object.keys(proxies);
    this.finishOperation(operation);
    if (this.proxyNames.length === 0) { this.exportMessage = UiText.get($r('app.string.diag_proxy_unavailable')); }
  }

  private async exportSupport(share: boolean): Promise<void> {
    if (this.busy || !this.visible) { return; }
    const epoch = this.exportEpoch;
    const action = ++this.exportAction;
    const operation = this.beginOperation();
    const context = getContext(this) as common.UIAbilityContext;
    this.exportMessage = UiText.get($r('app.string.diag_preparing_export'));
    let snapshot: DiagnosticExportSnapshot | null = null;
    let handedToShare = false;
    try {
      const bundle = await DiagnosticsService.exportBundle(context);
      if (!this.visible || epoch !== this.exportEpoch || action !== this.exportAction || !this.ownsOperation(operation)) { return; }
      const facts = DiagnosticsBundleView.facts(bundle.json);
      // Snapshot the returned JSON, not bundle.path: another service export can
      // replace that cache even before the picker or share callback resolves.
      snapshot = DiagnosticExportSnapshots.create(context, bundle.json, share);
      this.bundleFacts = facts;
      if (share) {
        const captured = snapshot;
        const data = new systemShare.SharedData({ utd: uniformTypeDescriptor.UniformDataType.FILE,
          uri: fileUri.getUriFromPath(captured.path), title: UiText.get($r('app.string.diag_bundle_name')), label: 'FILE' });
        const controller = new systemShare.ShareController(data);
        const dismiss = (): void => {
          DiagnosticExportSnapshots.release(captured, true);
          try { controller.off('dismiss', dismiss); } catch (_) {}
        };
        controller.on('dismiss', dismiss);
        handedToShare = true;
        try { await controller.show(context, {}); }
        catch (error) {
          DiagnosticExportSnapshots.release(captured, true);
          try { controller.off('dismiss', dismiss); } catch (_) {}
          throw error as Error;
        }
        if (this.visible && epoch === this.exportEpoch && action === this.exportAction && this.ownsOperation(operation)) {
          this.exportMessage = UiText.get($r('app.string.diag_share_open'));
        }
      } else {
        const uris = await new picker.DocumentViewPicker(context).save({
          newFileNames: [bundle.fileName], fileSuffixChoices: [UiText.get($r('app.string.diag_picker_type'))]
        });
        if (!this.visible || epoch !== this.exportEpoch) { return; }
        if (uris.length === 0) {
          if (action === this.exportAction && this.ownsOperation(operation)) { this.exportMessage = UiText.get($r('app.string.diag_save_cancelled')); }
          return;
        }
        const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try { fileIo.copyFileSync(snapshot.path, file.fd); } finally { fileIo.closeSync(file); }
        if (action === this.exportAction && this.ownsOperation(operation)) { this.exportMessage = UiText.get($r('app.string.diag_saved')); }
      }
    } catch (error) {
      if (this.visible && epoch === this.exportEpoch && action === this.exportAction && this.ownsOperation(operation)) {
        this.exportMessage = (error as Error).message === 'snapshot_capacity' ?
          UiText.get($r('app.string.diag_files_pending')) :
          UiText.get($r('app.string.diag_export_failed'));
      }
    } finally {
      if (snapshot !== null && !handedToShare) { DiagnosticExportSnapshots.release(snapshot, false); }
      this.finishOperation(operation);
    }
  }

  private connection(): string {
    if (this.status === VpnStatus.Connected) { return UiText.get($r('app.string.state_connected')); }
    if (this.status === VpnStatus.Connecting) { return UiText.get($r('app.string.diag_connecting')); }
    if (this.status === VpnStatus.Disconnecting) { return UiText.get($r('app.string.diag_disconnecting')); }
    return UiText.get($r('app.string.state_disconnected'));
  }

  private async copySummary(): Promise<void> {
    const attempt = this.generation;
    const checkedAt = this.checkedAt;
    const states = ['disconnected', 'connecting', 'connected', 'disconnecting'];
    const control = this.control === UiText.get($r('app.string.diag_reachable')) ? 'reachable' :
      this.control === UiText.get($r('app.string.diag_timeout')) ? 'timeout' :
      this.control === UiText.get($r('app.string.diag_not_checked')) || this.busy ? 'not-run' : 'failed';
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
        promptAction.showToast({ message: UiText.get($r('app.string.diag_summary_copied')) });
      }
    } catch (_) {
      if (this.visible && attempt === this.generation) {
        promptAction.showToast({ message: UiText.get($r('app.string.diag_copy_failed')) });
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
      promptAction.showToast({ message: UiText.get($r('app.string.diag_feedback_failed')) });
    }
  }

  build() {
    Column({ space: 20 }) {
      Scroll() {
        Column({ space: 16 }) {
          BackgroundNotice({ status: this.status, detailsOpen: this.detailsOpen })
          Text(UiText.get($r('app.string.diag_connection_check'))).fontSize(26).fontWeight(FontWeight.Bold).fontColor(UI.ink).width('100%')
          Column() {
            Row({ space: 16 }) {
              Text(UiText.get($r('app.string.home_connection_state'))).fontSize(15).fontColor(UI.ink).layoutWeight(1)
              Text(this.connection()).fontSize(14).fontColor(UI.muted).textAlign(TextAlign.End)
            }.width('100%').constraintSize({ minHeight: 64 }).padding(18)
            Divider().color(UI.line).margin({ left: 18, right: 18 })
            Column({ space: 8 }) {
              Text(UiText.get($r('app.string.diag_local_service'))).fontSize(13).fontColor(UI.muted)
              Text(this.control).fontSize(17).fontColor(UI.ink).width('100%')
            }.width('100%').padding(18).alignItems(HorizontalAlign.Start)
          }.width('100%').borderRadius(24).backgroundColor(UI.surface)
          if (this.control === UiText.get($r('app.string.diag_timeout'))) {
            Text(UiText.get($r('app.string.diag_retry_timeout'))).fontSize(14).fontColor(UI.error).width('100%')
          }
          if (VpnController.getLastStartFailure() !== null) {
            Text(UiText.get($r('app.string.diag_last_failure'), ConnectionFailures.label(VpnController.getLastStartFailure()!)))
              .fontSize(14).fontColor(UI.error).width('100%')
          }
          Button(this.detailsOpen ? UiText.get($r('app.string.diag_collapse')) : UiText.get($r('app.string.diag_details'))).constraintSize({ minHeight: 48 })
            .backgroundColor(UI.surface).fontColor(UI.accentText).accessibilityDescription(this.detailsOpen ? UiText.get($r('app.string.a11y_expanded')) : UiText.get($r('app.string.a11y_collapsed')))
            .onClick(() => { this.detailsOpen = !this.detailsOpen; })
          if (this.detailsOpen) {
            LiveViewStrategyPicker({ status: this.status })
            if (this.checkedAt !== '') {
              Text(UiText.get($r('app.string.diag_checked_at'), this.checkedAt)).fontSize(12).fontColor(UI.muted).width('100%')
            }
            Text(UiText.get($r('app.string.diag_check_scope')))
              .fontSize(14).fontColor(UI.muted).width('100%')
            Button(UiText.get($r('app.string.diag_check_dns'))).constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick(() => this.check('dns'))
            Button(UiText.get($r('app.string.diag_read_proxies'))).constraintSize({ minHeight: 48 }).enabled(!this.busy).onClick(() => this.chooseProxy())
            if (this.proxyNames.length > 0) {
              Select(this.proxyNames.map((name: string): SelectOption => ({ value: name })))
                .accessibilityText(UiText.get($r('app.string.diag_choose_proxy')))
                .selected(this.proxyNames.indexOf(this.proxyName)).value(this.proxyName || UiText.get($r('app.string.diag_choose_proxy')))
                .onSelect((index: number) => { this.proxyName = this.proxyNames[index]; })
            }
            Button(UiText.get($r('app.string.diag_check_proxy'))).constraintSize({ minHeight: 48 }).enabled(!this.busy && this.status === VpnStatus.Connected && this.proxyName.length > 0)
              .accessibilityDescription(this.status !== VpnStatus.Connected ? UiText.get($r('app.string.diag_connect_first')) :
                (this.proxyName.length === 0 ? UiText.get($r('app.string.diag_proxy_first')) : ''))
              .onClick(() => this.check('connection'))
            Button(UiText.get($r('app.string.diag_check_delay'))).constraintSize({ minHeight: 48 }).enabled(!this.busy && this.status === VpnStatus.Connected && this.proxyName.length > 0)
              .accessibilityDescription(this.status !== VpnStatus.Connected ? UiText.get($r('app.string.diag_connect_first')) :
                (this.proxyName.length === 0 ? UiText.get($r('app.string.diag_proxy_first')) : ''))
              .onClick(() => this.check('delay'))
            ForEach(this.checkLines, (line: string) => { Text(line).fontSize(13).fontColor(UI.muted).width('100%') })
            Text(UiText.get($r('app.string.diag_bandwidth_not_run'))).fontSize(13).fontColor(UI.muted).width('100%')
            Text(UiText.get($r('app.string.diag_visit_site')))
              .fontSize(14).fontColor(UI.muted).width('100%')
            Text(VpnController.getKernelReadyReported() ? UiText.get($r('app.string.diag_kernel_ready')) : UiText.get($r('app.string.diag_kernel_waiting')))
              .fontSize(14).fontColor(UI.muted).width('100%')
      Button(UiText.get($r('app.string.diag_share'))).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.exportSupport(true))
      Button(UiText.get($r('app.string.diag_copy_summary'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.copySummary())
      Button(UiText.get($r('app.string.diag_feedback'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.openFeedback())
          }
      Button(this.busy ? UiText.get($r('app.string.action_working')) : UiText.get($r('app.string.diag_check_service'))).width('100%').constraintSize({ minHeight: 56 })
        .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(!this.busy).onClick(() => this.check())
      Button(UiText.get($r('app.string.diag_save_bundle'))).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.exportSupport(false))
      if (this.exportMessage !== '') { Text(this.exportMessage).fontSize(14).fontColor(UI.muted).width('100%') }
      if (this.detailsOpen && this.bundleFacts.length > 0) {
        Text(UiText.get($r('app.string.diag_evidence_scope'))).fontSize(16).fontColor(UI.ink).width('100%')
        ForEach(this.bundleFacts, (fact: string) => { Text(fact).fontSize(13).fontColor(UI.muted).width('100%') })
      }
      Button(UiText.get($r('app.string.action_open_panel'))).width('100%').constraintSize({ minHeight: 48 })
        .backgroundColor(UI.soft).fontColor(UI.accentText).enabled(this.status === VpnStatus.Connected)
        .onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
        }.width('100%')
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').padding(24).backgroundColor(UI.paper).constraintSize({ maxWidth: 760 }).alignSelf(ItemAlign.Center)
  }
}
