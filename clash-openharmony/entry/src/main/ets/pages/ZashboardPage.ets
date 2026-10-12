import { webview } from '@kit.ArkWeb';
import { ZashboardPolicy } from '../lib/ZashboardPolicy';

// Security/configuration integration supplies an authenticated session, never URL credentials.
// Kept out of navigation until REST/WS authentication and configuration transactions pass.
@Component
export struct ZashboardPage {
  @Prop @Watch('sessionChanged') url: string = '';
  @Prop @Watch('sessionChanged') version: string = '';
  @Prop @Watch('sessionChanged') authenticated: boolean = false;
  @State private error: string = '';
  @State private open: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
  private reopenTimer: number = -1;

  private validSession(): boolean {
    return ZashboardPolicy.validSession(this.authenticated, this.url, this.version);
  }

  private allowedNavigation(target: string): boolean {
    return this.validSession() && ZashboardPolicy.navigation(this.url, target);
  }

  aboutToDisappear(): void {
    if (this.reopenTimer !== -1) { clearTimeout(this.reopenTimer); this.reopenTimer = -1; }
    try { this.controller.stop(); } catch (_) {}
  }

  private sessionChanged(): void { this.reopen(); }

  private reopen(): void {
    if (this.reopenTimer !== -1) { clearTimeout(this.reopenTimer); }
    try { this.controller.stop(); } catch (_) {}
    this.open = false;
    this.error = '';
    // Recreate the Web component to release old page-owned resources.
    this.reopenTimer = setTimeout(() => {
      this.controller = new webview.WebviewController();
      this.open = true;
      this.reopenTimer = -1;
    }, 0);
  }

  build() {
    Column({ space: 12 }) {
      Text(`Zashboard · ${this.version.substring(0, 12)}`).fontSize(14)
      if (!this.validSession()) {
        Text('面板尚未完成安全接入，请继续使用原生入口。').fontSize(16)
      } else {
        if (this.error !== '') { Text(this.error).fontColor(Color.Red) }
        Button('重新打开面板').onClick(() => this.reopen())
        if (this.open) {
          Web({ src: this.url, controller: this.controller })
            .javaScriptAccess(true)
            .fileAccess(false)
            .domStorageAccess(true)
            .databaseAccess(false)
            .mixedMode(MixedMode.None)
            .cacheMode(CacheMode.None)
            .multiWindowAccess(false)
            .onControllerAttached(() => {
              try { this.controller.removeCache(true); }
              catch (_) { this.error = '面板缓存清理失败，请关闭后重开。'; }
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
            .onErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.error = '面板加载失败，可重新打开；VPN 继续运行。'; }
            })
            .onHttpErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.error = '面板服务不可用，请检查会话后重开。'; }
            })
            .width('100%')
            .layoutWeight(1)
        }
      }
    }.width('100%').height('100%').padding(12)
  }
}
