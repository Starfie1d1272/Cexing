import { UiText } from '../lib/UiText';
import { NativeTheme as UI } from './NativeTheme';
import { webview } from '@kit.ArkWeb';
import { ZashboardPolicy } from '../lib/ZashboardPolicy';
import { common } from '@kit.AbilityKit';
import { ZashboardSession, ZashboardSessionView } from '../lib/ZashboardSession';
import { VpnController, VpnStatus } from '../lib/VpnController';

@Component
export struct ZashboardPage {
  @Prop @Watch('visibilityChanged') visible: boolean = true;
  @State private url: string = '';
  @State private version: string = '';
  @State private error: string = '';
  @State private open: boolean = false;
  private bootstrap: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private session: ZashboardSession = new ZashboardSession();
  private reopenTimer: number = -1;
  private active: boolean = false;
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    if (status !== VpnStatus.Connected) { this.releaseWeb(); }
    if (this.active) { this.reopen(); }
  };

  private validSession(): boolean {
    return this.open && ZashboardPolicy.validSession(true, this.url, this.version);
  }

  private allowedNavigation(target: string): boolean {
    return this.validSession() && ZashboardPolicy.navigation(this.url, this.version, target);
  }

  aboutToAppear(): void {
    VpnController.onChanged(this.listener);
    this.visibilityChanged();
  }

  aboutToDisappear(): void {
    this.active = false;
    VpnController.offChanged(this.listener);
    this.session.stop();
    this.releaseWeb();
  }

  private visibilityChanged(): void {
    this.active = this.visible;
    if (this.active) { this.reopen(); }
    else { this.session.stop(); this.releaseWeb(); }
  }

  private releaseWeb(): void {
    if (this.reopenTimer !== -1) { clearTimeout(this.reopenTimer); this.reopenTimer = -1; }
    // Explicitly revoke reconnecting WS/HTTP before destroying the page. No native JS bridge.
    try { this.controller.runJavaScript('window.__OHOS_PANEL_REVOKE__?.()').catch(() => {}); } catch (_) {}
    try { this.controller.stop(); } catch (_) {}
    this.open = false;
    this.bootstrap = '';
    this.url = '';
    this.version = '';
  }

  private changed(view: ZashboardSessionView | null, error: string): void {
    if (!this.active) { return; }
    this.releaseWeb();
    this.error = error === '' ? '' : UiText.get($r('app.string.panel_unavailable'));
    if (view === null) { return; }
    // One render without Web releases the old component before creating the next controller.
    this.reopenTimer = setTimeout(() => {
      this.reopenTimer = -1;
      if (!this.active) { return; }
      this.controller = new webview.WebviewController();
      this.url = view.url;
      this.version = view.version;
      this.bootstrap = view.bootstrap;
      this.open = true;
    }, 0);
  }

  private reopen(): void {
    this.releaseWeb();
    this.error = UiText.get($r('app.string.panel_preparing'));
    const context = getContext(this) as common.UIAbilityContext;
    this.session.start(context, (view: ZashboardSessionView | null, error: string) => this.changed(view, error));
  }

  build() {
    Column({ space: 12 }) {
      Text('Zashboard').fontSize(12).fontColor(UI.muted).width('100%')
      if (!this.validSession()) {
        Scroll() {
          Column({ space: 20 }) {
            Text(UiText.get($r('app.string.panel_open'))).fontSize(24).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.ink)
            Text(this.error || UiText.get($r('app.string.panel_preparing'))).fontSize(16).fontColor(UI.muted)
            Button(UiText.get($r('app.string.panel_reopen'))).width('100%').constraintSize({ minHeight: 56 }).backgroundColor(UI.action).fontColor(UI.onAccent)
              .onClick(() => this.reopen())
          }.padding(24).width('100%').constraintSize({ maxWidth: 760 })
            .borderRadius(24).backgroundColor(UI.surface).alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1)
      } else {
        if (this.error !== '') {
          Column({ space: 12 }) {
            Text(this.error).fontSize(14).fontColor(UI.error).width('100%')
            Button(UiText.get($r('app.string.action_retry'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.accentText)
              .onClick(() => this.reopen())
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.open) {
          Web({ src: `${this.url}versions/${this.version}/`, controller: this.controller })
            .darkMode(WebDarkMode.Auto)
            .forceDarkAccess(false)
            .backgroundColor(UI.paper)
            .javaScriptAccess(true)
            .javaScriptOnDocumentStart([{ script: this.bootstrap, scriptRules: ['http://127.0.0.1:9090'] }])
            .fileAccess(false)
            .domStorageAccess(true)
            .databaseAccess(false)
            .mixedMode(MixedMode.None)
            .cacheMode(CacheMode.None)
            .multiWindowAccess(false)
            .onControllerAttached(() => {
              try { this.controller.removeCache(true); }
              catch (_) { this.releaseWeb(); this.error = UiText.get($r('app.string.panel_cache_failed')); }
            })
            .onInterceptRequest((event) => {
              const target = event.request.getRequestUrl();
              if (this.validSession() && ZashboardPolicy.request(this.url, target)) {
                return undefined;
              }
              const response = new WebResourceResponse();
              response.setResponseData('Blocked by host');
              response.setResponseCode(403);
              response.setReasonMessage('Forbidden');
              response.setResponseMimeType('text/plain');
              return response;
            })
            .onLoadIntercept((event) => !this.allowedNavigation(event.data.getRequestUrl()))
            .onOverrideUrlLoading((request) => !this.allowedNavigation(request.getRequestUrl()))
            .onConsole(() => true)
            .onRenderExited(() => { this.releaseWeb(); this.error = UiText.get($r('app.string.panel_exited')); })
            .onErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.error = UiText.get($r('app.string.panel_load_failed')); }
            })
            .onHttpErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.error = UiText.get($r('app.string.panel_service_failed')); }
            })
            .width('100%')
            .layoutWeight(1)
        }
      }
    }.width('100%').height('100%').padding(12).backgroundColor(UI.paper)
  }
}
