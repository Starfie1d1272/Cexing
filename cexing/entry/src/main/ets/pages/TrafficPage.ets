import { common } from '@kit.AbilityKit';
import { LengthMetrics, promptAction } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { Settings, AppSettings, ApplicationAccessEdit } from '../lib/Settings';
import { SettingsReconnectButton } from './SettingsReconnectButton';
import { UiText } from '../lib/UiText';
import { CoreApi, TrafficMsg, formatRate, AppTrafficSummary, AppTrafficRow, AppTrafficRoutes, AppTrafficBytes, AppTrafficReason, AppTrafficPresentation } from '../lib/CoreApi';
import { TrafficStats, TrafficView, TrafficPoint } from '../lib/TrafficStats';
import { TrafficBucket } from '../lib/TrafficLedger';
import { VpnController, VpnStatus, excludeVpnApplication, undoVpnApplicationExclusion } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

function bytes(value: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
  return `${value.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

@Component
export struct TrafficPage {
  @State private snapshot: TrafficView = new TrafficView();
  @State private up: string = '—';
  @State private down: string = '—';
  @State private chartWidth: number = 280;
  @State private uploads: number[][] = [];
  @State private downloads: number[][] = [];
  @State private chartLevels: string[] = [];
  @State private chartUnit: string = 'KB/s';
  @State private appSummary: AppTrafficSummary | null = null;
  @State private appRows: AppTrafficRow[] = [];
  @State private presentations: Record<string, AppTrafficPresentation> = {};
  @State private selected: AppTrafficRow | null = null;
  @State private showApp: boolean = false;
  @State private showReasons: boolean = false;
  @State private appReadFailed: boolean = false;
  @State private appLoading: boolean = true;
  @State private savingAccess: boolean = false;
  @State private accessSettings: AppSettings = new AppSettings();
  @State private accessReady: boolean = false;
  @State private accessReceipt: ApplicationAccessEdit | null = null;
  private lifeRequest: number = 0;
  private detailRequest: number = 0;
  private appRequest: number = 0;
  private appBusy: boolean = false;
  private appSampleAt: number = 0;
  private presentationRequest: number = 0;
  private timer: number = -1;
  private lastRate: number = 0;
  private active: boolean = false;
  private watcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private settingsListener = (): void => { this.readAccess(); };
  private listener = (_status: VpnStatus): void => { this.openRates(); };

  aboutToAppear(): void {
    this.active = true; this.lifeRequest++;
    this.savingAccess = false;
    this.readAccess(); Settings.onChanged(this.settingsListener);
    VpnController.onChanged(this.listener);
    this.refresh(); this.openRates();
    this.timer = setInterval(() => {
      this.refresh();
      if (Date.now() - this.appSampleAt >= 5000) { this.refreshApps(); }
      if (Date.now() - this.lastRate > 4000) { this.up = '—'; this.down = '—'; }
    }, 1000);
  }
  aboutToDisappear(): void {
    this.active = false; this.lifeRequest++; this.appRequest++; this.showApp = false;
    this.releasePresentations(); Settings.offChanged(this.settingsListener);
    clearInterval(this.timer); this.timer = -1;
    this.watcher.stop(); VpnController.offChanged(this.listener);
  }
  private openRates(): void {
    this.appRequest++;
    this.appSummary = null; this.appRows = []; this.selected = null; this.showApp = false;
    this.appLoading = true;
    this.refreshApps();
    this.watcher.stop(); this.up = '—'; this.down = '—'; this.lastRate = 0;
    if (this.active && VpnController.status === VpnStatus.Connected) {
      this.watcher.start('/traffic', (sample: TrafficMsg) => {
        this.lastRate = Date.now(); this.up = formatRate(sample.up); this.down = formatRate(sample.down);
      });
    }
  }
  private refresh(): void {
    this.snapshot = TrafficStats.view();
    const points = this.snapshot.points;
    // Break rather than connect across missing samples; curve is a short,
    // bounded observation history, not a reconstructed daily timeline.
    const now = Date.now();
    let start = points.length - 1;
    while (start > 0 && points[start].at - points[start - 1].at <= 15000) { start--; }
    const recent = points.slice(Math.max(0, start)).filter((p: TrafficPoint) => now - p.at <= 300000);
    let peak = 0;
    recent.forEach((p: TrafficPoint) => { peak = Math.max(peak, p.up, p.down); });
    let max = 1024;
    while (max < peak) { max *= 2; }
    const units = ['KB/s', 'MB/s', 'GB/s', 'TB/s'];
    let unit = 1024;
    let unitIndex = 0;
    while (max / unit >= 1024 && unitIndex < units.length - 1) { unit *= 1024; unitIndex++; }
    this.chartUnit = units[unitIndex];
    this.chartLevels = [max, max * 0.75, max / 2, max / 4, 0].map((value: number) => `${Number((value / unit).toFixed(2))}`);
    const width = Math.max(0, this.chartWidth - 16);
    this.uploads = recent.map((p: TrafficPoint) => [8 + Math.max(0, width * (1 - (now - p.at) / 300000)), 112 - 104 * p.up / max]);
    this.downloads = recent.map((p: TrafficPoint) => [8 + Math.max(0, width * (1 - (now - p.at) / 300000)), 112 - 104 * p.down / max]);
  }
  private releasePresentations(): void {
    this.presentationRequest++;
    Object.keys(this.presentations).forEach((key: string) => {
      this.presentations[key].icon?.release();
    });
    this.presentations = {};
  }
  private async loadPresentations(rows: AppTrafficRow[]): Promise<void> {
    const request = this.presentationRequest;
    for (const row of rows) {
      if (!this.active || request !== this.presentationRequest) { return; }
      if (row.identityStatus !== 'known' || row.bundleName.length === 0 || this.presentations[row.bundleName] !== undefined) { continue; }
      this.presentations[row.bundleName] = { label: row.bundleName, icon: null };
      const value = await CoreApi.getAppTrafficPresentation(row.bundleName);
      if (!this.active || request !== this.presentationRequest) { value?.icon?.release(); return; }
      this.presentations[row.bundleName] = value ?? { label: row.bundleName, icon: null };
      const next: Record<string, AppTrafficPresentation> = {};
      Object.keys(this.presentations).forEach((key: string) => { next[key] = this.presentations[key]; });
      this.presentations = next;
    }
  }
  private async refreshApps(): Promise<void> {
    if (!this.active || this.appBusy) { return; }
    this.appBusy = true; this.appSampleAt = Date.now();
    const request = this.appRequest;
    const session = VpnController.trafficSession();
    try {
      const summary = await CoreApi.getAppTraffic();
      const coreSession = VpnController.status === VpnStatus.Connected ? await CoreApi.getControllerSession() : null;
      if (!this.active || request !== this.appRequest || session !== VpnController.trafficSession()) { return; }
      this.appLoading = false;
      this.appReadFailed = summary === null;
      if (summary === null) { return; }
      if (VpnController.status === VpnStatus.Connecting ||
        (VpnController.status === VpnStatus.Connected && (coreSession === null || summary.session !== coreSession))) {
        this.appSummary = null; this.appRows = []; return;
      }
      if (this.appSummary?.session !== summary.session) { this.releasePresentations(); }
      this.appSummary = summary;
      this.appRows = summary.apps.slice().sort((a: AppTrafficRow, b: AppTrafficRow) =>
        this.routeBytes(b.routes.proxy) - this.routeBytes(a.routes.proxy) || this.rowKey(a).localeCompare(this.rowKey(b)));
      if (this.selected !== null) {
        const key = this.rowKey(this.selected);
        this.selected = this.appRows.find((row: AppTrafficRow) => this.rowKey(row) === key) ?? null;
        if (this.selected === null) { this.showApp = false; }
      }
      this.loadPresentations(this.appRows);
    } catch (_) { if (this.active && request === this.appRequest) { this.appLoading = false; this.appReadFailed = true; } }
    finally { this.appBusy = false; }
  }
  private rowKey(row: AppTrafficRow): string { return `${row.identityStatus}:${row.uid}:${row.bundleName}`; }
  private routeBytes(route: AppTrafficBytes): number { return route.upload + route.download; }
  private total(routes: AppTrafficRoutes): number {
    return this.routeBytes(routes.proxy) + this.routeBytes(routes.direct) + this.routeBytes(routes.unclassified);
  }
  private upload(routes: AppTrafficRoutes): number { return routes.proxy.upload + routes.direct.upload + routes.unclassified.upload; }
  private download(routes: AppTrafficRoutes): number { return routes.proxy.download + routes.direct.download + routes.unclassified.download; }
  private appName(row: AppTrafficRow): string {
    return row.identityStatus === 'known' ? (this.presentations[row.bundleName]?.label || row.bundleName) : UiText.get($r('app.string.traffic_unknown_app'));
  }
  private sessionLabel(): string {
    if (this.appSummary === null) { return ''; }
    const time = new Date(this.appSummary.startedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return UiText.get($r('app.string.traffic_started_at'), time);
  }
  private appState(): string {
    if (this.appLoading) { return UiText.get($r('app.string.traffic_apps_loading')); }
    if (this.appReadFailed) { return UiText.get($r('app.string.traffic_apps_unavailable')); }
    if (this.appSummary === null) { return UiText.get($r('app.string.traffic_apps_empty')); }
    if (this.appSummary.state === 'closed') { return UiText.get($r('app.string.traffic_session_ended')); }
    return this.sessionLabel();
  }
  private openApp(row: AppTrafficRow): void { this.detailRequest++; this.selected = row; this.showReasons = false; this.showApp = true; }
  private readAccess(): void {
    try { this.accessSettings = Settings.load(getContext(this) as common.Context); this.accessReady = true; }
    catch (_) { this.accessReady = false; }
  }
  private isExcluded(bundleName: string): boolean {
    return this.accessSettings.accessMode === 'black' ? this.accessSettings.accessList.includes(bundleName) :
      this.accessSettings.accessMode === 'white' && !this.accessSettings.accessList.includes(bundleName);
  }
  private summaryStatus(): string {
    return this.appSummary?.partial ? UiText.get($r('app.string.traffic_partial')) : '';
  }
  private confirmExclusion(): void {
    const row = this.selected;
    if (row === null || row.identityStatus !== 'known' || row.bundleName.length === 0 || this.savingAccess || !this.accessReady || this.isExcluded(row.bundleName)) { return; }
    const request = this.appRequest;
    const detailRequest = ++this.detailRequest;
    const session = this.appSummary?.session;
    AlertDialog.show({ title: UiText.get($r('app.string.traffic_exclude_title'), this.appName(row)),
      message: UiText.get($r('app.string.traffic_exclude_warning')),
      primaryButton: { value: UiText.get($r('app.string.action_cancel')), action: () => {} },
      secondaryButton: { value: UiText.get($r('app.string.traffic_exclude_confirm')), action: () => {
        if (this.active && this.showApp && detailRequest === this.detailRequest && this.selected !== null && this.rowKey(this.selected) === this.rowKey(row) && request === this.appRequest && session === this.appSummary?.session) {
          this.changeAccess(row.bundleName);
        }
      } }
    });
  }
  private async changeAccess(bundleName: string = ''): Promise<void> {
    if (this.savingAccess || !this.active) { return; }
    const receipt = this.accessReceipt;
    const lifeRequest = this.lifeRequest;
    if (bundleName.length === 0 && receipt === null) { return; }
    this.savingAccess = true;
    try {
      const result = bundleName.length > 0 ? await excludeVpnApplication(getContext(this) as common.Context, bundleName) :
        await undoVpnApplicationExclusion(getContext(this) as common.Context, receipt!);
      if (this.active && lifeRequest === this.lifeRequest) {
        this.accessReceipt = bundleName.length > 0 ? result : null;
        promptAction.showToast({ message: UiText.get($r('app.string.network_saved')) });
      }
    } catch (error) {
      if (this.active && lifeRequest === this.lifeRequest) { promptAction.showToast({ message: (error as Error).message }); }
    } finally { if (this.active && lifeRequest === this.lifeRequest) { this.savingAccess = false; } }
  }
  @Builder
  Rate(upload: boolean) {
    Column({ space: 8 }) {
      Text(upload ? UiText.get($r('app.string.traffic_up_rate')) : UiText.get($r('app.string.traffic_down_rate'))).fontSize(13).fontColor(upload ? UI.accentText : UI.muted)
      Text(upload ? this.up : this.down).fontSize(24).fontWeight(FontWeight.Medium).fontColor(UI.ink).fontFeature('tnum')
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }
  private bucket(index: number): TrafficBucket {
    return index === 0 ? this.snapshot.current : (index === 1 ? this.snapshot.today : this.snapshot.month);
  }
  @Builder
  Period(index: number, label: string) {
    Column({ space: 16 }) {
      Row() {
        Text(label).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
      }.width('100%')
      Row() {
        Column({ space: 7 }) {
          Text(UiText.get($r('app.string.traffic_up'))).fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).up) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 7 }) {
          Text(UiText.get($r('app.string.traffic_down'))).fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).down) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 7 }) {
          Text(UiText.get($r('app.string.traffic_total'))).fontSize(12).fontColor(UI.muted)
          Text(this.snapshot.ready && (index !== 0 || this.snapshot.currentReady) ? bytes(this.bucket(index).up + this.bucket(index).down) : '—').fontSize(17).minFontSize(12).maxFontSize(17).maxLines(1).fontWeight(FontWeight.Medium)
            .fontColor(UI.ink).fontFeature('tnum')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
    }.width('100%').padding(20).borderRadius(24).backgroundColor(UI.surface)
  }
  @Builder
  AppIcon(row: AppTrafficRow, size: number) {
    if (row.identityStatus === 'known' && this.presentations[row.bundleName]?.icon) {
      Image(this.presentations[row.bundleName].icon!).width(size).height(size).borderRadius(12).objectFit(ImageFit.Contain).accessibilityLevel('no')
    } else {
      SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(size * 0.5).fontColor([UI.muted])
        .width(size).height(size).padding(size * 0.25).backgroundColor(UI.soft).borderRadius(12).accessibilityLevel('no')
    }
  }
  @Builder
  RouteBar(routes: AppTrafficRoutes) {
    if (this.total(routes) > 0) {
      Row({ space: 2 }) {
        if (this.routeBytes(routes.proxy) > 0) { Blank().layoutWeight(this.routeBytes(routes.proxy)).backgroundColor(UI.accentText) }
        if (this.routeBytes(routes.direct) > 0) { Blank().layoutWeight(this.routeBytes(routes.direct)).backgroundColor('#AEC3CB') }
        if (this.routeBytes(routes.unclassified) > 0) { Blank().layoutWeight(this.routeBytes(routes.unclassified)).backgroundColor(UI.line) }
      }.width('100%').height(5).borderRadius(3).clip(true).accessibilityLevel('no')
    }
  }
  @Builder
  RouteLegend(label: string, value: AppTrafficBytes, color: ResourceColor) {
    Row({ space: 5 }) {
      Circle().width(5).height(5).fill(color)
      Text(`${label} ${bytes(this.routeBytes(value))}`).fontSize(12).fontColor(UI.muted)
    }
  }
  @Builder
  SessionSummary(summary: AppTrafficSummary) {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Text($r('app.string.traffic_session')).fontSize(17).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
        Text(this.appState()).fontSize(12).fontColor(UI.accentText).padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(UI.soft).borderRadius(16)
      }.width('100%')
      Text(bytes(this.total(summary.totals))).fontSize(38).fontWeight(FontWeight.Medium).fontColor(UI.ink).fontFeature('tnum').width('100%')
      Text(`${UiText.get($r('app.string.traffic_up'))} ${bytes(this.upload(summary.totals))}   ${UiText.get($r('app.string.traffic_down'))} ${bytes(this.download(summary.totals))}`)
        .fontSize(13).fontColor(UI.muted).width('100%')
      this.RouteBar(summary.totals)
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(6) } }) {
        this.RouteLegend(UiText.get($r('app.string.traffic_proxy')), summary.totals.proxy, UI.accentText)
        this.RouteLegend(UiText.get($r('app.string.traffic_direct')), summary.totals.direct, '#AEC3CB')
        if (this.routeBytes(summary.totals.unclassified) > 0) {
          this.RouteLegend(UiText.get($r('app.string.traffic_unclassified')), summary.totals.unclassified, UI.line)
        }
      }.width('100%')
      if (summary.partial) {
        Text(this.summaryStatus()).fontSize(12).fontColor(UI.muted).width('100%')
      }
    }.width('100%').padding(20).borderRadius(24).backgroundColor(UI.surface)
  }
  @Builder
  AppUsage() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text($r('app.string.traffic_apps')).fontSize(18).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
        Text($r('app.string.traffic_proxy_order')).fontSize(11).fontColor(UI.muted)
      }.width('100%')
      if (this.appRows.length > 0) {
        Column() {
          ForEach(this.appRows, (row: AppTrafficRow, index: number) => {
            if (index > 0) { Divider().color(UI.line) }
            Row({ space: 12 }) {
              this.AppIcon(row, 40)
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(this.appName(row)).fontSize(16).fontColor(UI.ink).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  Text(bytes(this.routeBytes(row.routes.proxy))).fontSize(20).fontColor(UI.ink).fontFeature('tnum')
                }.width('100%')
                Row({ space: 6 }) {
                  Text(UiText.get($r('app.string.traffic_app_totals'), bytes(this.total(row.routes)), bytes(this.routeBytes(row.routes.direct))))
                    .fontSize(11).fontColor(UI.muted).layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([UI.muted]).accessibilityLevel('no')
                }.width('100%')
                this.RouteBar(row.routes)
              }.layoutWeight(1)
            }.width('100%').padding({ top: 16, bottom: 16 }).constraintSize({ minHeight: 80 })
              .accessibilityRole(AccessibilityRoleType.BUTTON).accessibilityGroup(true)
              .accessibilityText(`${this.appName(row)}, ${UiText.get($r('app.string.traffic_proxy'))} ${bytes(this.routeBytes(row.routes.proxy))}`)
              .onClick(() => this.openApp(row))
          }, (row: AppTrafficRow) => this.rowKey(row) + JSON.stringify(row.routes))
        }.padding({ left: 18, right: 18 }).width('100%').backgroundColor(UI.surface).borderRadius(24)
      } else {
        Text(this.appState()).fontSize(14).fontColor(UI.muted).width('100%').padding(24).backgroundColor(UI.surface).borderRadius(24)
      }
      if (deviceInfo.sdkApiVersion < 23) {
        Text($r('app.string.traffic_identity_unsupported')).fontSize(12).fontColor(UI.muted).width('100%')
      } else if (this.appReadFailed && this.appRows.length > 0) {
        Text($r('app.string.traffic_apps_unavailable')).fontSize(12).fontColor(UI.muted).width('100%')
      }
      Text($r('app.string.traffic_scope')).fontSize(12).fontColor(UI.muted).width('100%')
    }.width('100%').padding({ top: 12, bottom: 8 })
  }
  @Builder
  RouteDetail(label: string, route: AppTrafficBytes, color: ResourceColor) {
    Column({ space: 14 }) {
      Row({ space: 5 }) { Circle().width(6).height(6).fill(color); Text(label).fontSize(14).fontColor(UI.ink) }.width('100%')
      Text(bytes(this.routeBytes(route))).fontSize(25).minFontSize(18).maxFontSize(25).maxLines(1).fontColor(UI.ink).fontFeature('tnum').width('100%')
      Column({ space: 8 }) {
        Text(`${UiText.get($r('app.string.traffic_up'))} ${bytes(route.upload)}`).fontSize(12).fontColor(UI.muted).width('100%')
        Text(`${UiText.get($r('app.string.traffic_down'))} ${bytes(route.download)}`).fontSize(12).fontColor(UI.muted).width('100%')
      }
    }.layoutWeight(1).padding(16).borderRadius(20).backgroundColor(UI.surface)
  }
  @Builder
  AppDetail(row: AppTrafficRow) {
    Column({ space: 20 }) {
      Row({ space: 12 }) {
        this.AppIcon(row, 44)
        Column({ space: 5 }) {
          Text(this.appName(row)).fontSize(22).fontWeight(FontWeight.Medium).fontColor(UI.ink).maxLines(2)
          Text(this.appState()).fontSize(12).fontColor(UI.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      Column({ space: 10 }) {
        Text($r('app.string.traffic_app_total')).fontSize(13).fontColor(UI.muted).width('100%')
        Text(bytes(this.total(row.routes))).fontSize(40).fontColor(UI.ink).fontFeature('tnum').width('100%')
        Text(`${UiText.get($r('app.string.traffic_up'))} ${bytes(this.upload(row.routes))}   ${UiText.get($r('app.string.traffic_down'))} ${bytes(this.download(row.routes))}`)
          .fontSize(13).fontColor(UI.muted).width('100%')
      }.width('100%')
      if (this.summaryStatus().length > 0) { Text(this.summaryStatus()).fontSize(12).fontColor(UI.muted).width('100%') }
      Row({ space: 10 }) {
        this.RouteDetail(UiText.get($r('app.string.traffic_proxy')), row.routes.proxy, UI.accentText)
        this.RouteDetail(UiText.get($r('app.string.traffic_direct')), row.routes.direct, '#AEC3CB')
      }.width('100%').alignItems(VerticalAlign.Top)
      if (this.routeBytes(row.routes.unclassified) > 0 || row.routes.unclassified.connections > 0) {
        Row() { this.RouteDetail(UiText.get($r('app.string.traffic_unclassified')), row.routes.unclassified, UI.line) }.width('100%')
      }
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Text($r('app.string.traffic_recent_rules')).fontSize(16).fontWeight(FontWeight.Medium).fontColor(UI.ink).layoutWeight(1)
          SymbolGlyph(this.showReasons ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down')).fontSize(14).fontColor([UI.muted])
        }.width('100%').constraintSize({ minHeight: 44 }).accessibilityRole(AccessibilityRoleType.BUTTON)
          .accessibilityText(UiText.get($r('app.string.traffic_recent_rules'))).onClick(() => { this.showReasons = !this.showReasons; })
        if (this.showReasons) {
          if (row.recent.length === 0) { Text($r('app.string.traffic_no_rules')).fontSize(13).fontColor(UI.muted).width('100%') }
          ForEach(row.recent, (reason: AppTrafficReason) => {
            Divider().color(UI.line)
            Column({ space: 6 }) {
              Text(reason.rule || UiText.get($r('app.string.traffic_unclassified'))).fontSize(14).fontColor(UI.ink)
              Text(reason.policy.join(' → ')).fontSize(12).fontColor(UI.muted)
              Text(reason.route === 'proxy' ? UiText.get($r('app.string.traffic_proxy')) : reason.route === 'direct' ?
                UiText.get($r('app.string.traffic_direct')) : UiText.get($r('app.string.traffic_unclassified'))).fontSize(12).fontColor(UI.accentText)
            }.alignItems(HorizontalAlign.Start).width('100%')
          })
        }
      }.width('100%').padding(18).borderRadius(24).backgroundColor(UI.surface)
      if (row.identityStatus === 'known' && row.bundleName.length > 0) {
        Button(this.isExcluded(row.bundleName) ? $r('app.string.traffic_excluded') : $r('app.string.traffic_exclude_action')).width('100%').constraintSize({ minHeight: 56 }).fontSize(16)
          .fontColor(UI.ink).backgroundColor(UI.surface).borderRadius(20).enabled(this.accessReady && !this.savingAccess && !this.isExcluded(row.bundleName)).onClick(() => this.confirmExclusion())
      } else {
        Text($r('app.string.traffic_unknown_no_exclude')).fontSize(12).fontColor(UI.muted).width('100%')
      }
      this.AccessFeedback()
    }.width('100%').padding(24)
  }
  @Builder
  AccessFeedback() {
    if (this.accessReceipt !== null) {
      Button($r('app.string.traffic_exclusion_undo')).width('100%').constraintSize({ minHeight: 44 }).fontColor(UI.accentText)
        .backgroundColor(UI.soft).enabled(!this.savingAccess).onClick(() => this.changeAccess())
    }
    SettingsReconnectButton({ canApply: !this.savingAccess })
  }
  @Builder
  AppSheet() {
    Scroll() {
      if (this.selected !== null) { this.AppDetail(this.selected) }
    }.width('100%').height('100%').backgroundColor(UI.paper).scrollBar(BarState.Off)
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 16 }) {
          Row({ space: 12 }) { this.Rate(true); this.Rate(false) }.width('100%')
          if (this.uploads.length > 1) {
            Column({ space: 8 }) {
              Row({ space: 16 }) {
                Text(this.chartUnit).fontSize(10).fontColor(UI.muted).layoutWeight(1)
                Row({ space: 4 }) {
                  Circle().width(6).height(6).fill(UI.accentText)
                  Text(UiText.get($r('app.string.traffic_up'))).fontSize(11).fontColor(UI.muted)
                }
                Row({ space: 4 }) {
                  Circle().width(6).height(6).fill(UI.muted)
                  Text(UiText.get($r('app.string.traffic_down'))).fontSize(11).fontColor(UI.muted)
                }
              }.width('100%')
              Row({ space: 6 }) {
                Column() {
                  ForEach(this.chartLevels, (level: string) => {
                    Text(level).fontSize(10).minFontSize(8).maxFontSize(10).fontColor(UI.muted).maxLines(1)
                  })
                }.width(28).height(120).alignItems(HorizontalAlign.End).justifyContent(FlexAlign.SpaceBetween)
                Stack() {
                  Divider().color(UI.line).opacity(0.5).position({ x: 0, y: 34 })
                  Divider().color(UI.line).opacity(0.5).position({ x: 0, y: 60 })
                  Divider().color(UI.line).opacity(0.5).position({ x: 0, y: 86 })
                  Divider().vertical(true).height(120).color(UI.line).opacity(0.5).position({ x: '50%', y: 0 })
                  Polyline().width('100%').height(120).points(this.uploads).fill(Color.Transparent).stroke(UI.accentText).strokeWidth(2)
                  Polyline().width('100%').height(120).points(this.downloads).fill(Color.Transparent).stroke(UI.muted).strokeWidth(2)
                }.layoutWeight(1).height(120).border({ width: 1, color: UI.line }).borderRadius(8).clip(true)
                  .onAreaChange((_old: Area, area: Area) => { this.chartWidth = Number(area.width); })
              }.width('100%')
              Row() {
                Blank().width(34)
                Text(UiText.get($r('app.string.traffic_five_ago'))).layoutWeight(1).fontSize(10).fontColor(UI.muted)
                Text(UiText.get($r('app.string.traffic_half_ago'))).layoutWeight(1).textAlign(TextAlign.Center).fontSize(10).fontColor(UI.muted)
                Text(UiText.get($r('app.string.traffic_now'))).layoutWeight(1).textAlign(TextAlign.End).fontSize(10).fontColor(UI.muted)
              }.width('100%')
            }.width('100%').accessibilityGroup(true).accessibilityText(UiText.get($r('app.string.traffic_chart')))
          }
        }.width('100%').padding(20).borderRadius(24).backgroundColor(UI.surface)
        if (this.appSummary !== null) { this.SessionSummary(this.appSummary) }
        else { this.Period(0, UiText.get($r('app.string.traffic_session'))) }
        this.AppUsage()
        this.AccessFeedback()
        this.Period(1, UiText.get($r('app.string.traffic_today')))
        this.Period(2, UiText.get($r('app.string.traffic_month')))
        if (!this.snapshot.saved) {
          Text(UiText.get($r('app.string.traffic_unsaved'))).fontSize(12).fontColor(UI.muted).width('100%').padding({ bottom: 16 })
        }
      }.width('100%').constraintSize({ maxWidth: 640 }).padding(24)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor(UI.paper).scrollBar(BarState.Off)
      .bindSheet($$this.showApp, this.AppSheet(), { height: SheetSize.LARGE, showClose: true, onDisappear: () => { this.detailRequest++; },
        shouldDismiss: (dismiss: SheetDismiss) => { if (!this.savingAccess) { dismiss.dismiss(); } } })
  }
}
