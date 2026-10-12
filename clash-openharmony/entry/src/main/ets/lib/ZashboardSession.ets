import { common } from '@kit.AbilityKit';
import { CoreApi } from './CoreApi';
import { VpnController, VpnStatus } from './VpnController';
import { ZashboardAssets } from './ZashboardAssets';
import { ZASHBOARD_VERSION } from './ZashboardPin';

export interface ZashboardSessionView {
  url: string;
  version: string;
  bootstrap: string;
}

// Page-owned observer. Never starts/stops the VPN or changes Controller credentials.
export class ZashboardSession {
  private generation: number = 0;
  private timer: number = -1;
  private controllerSession: string = '';

  static bootstrap(secret: string, version: string): string {
    if (!/^[a-f0-9]{64}$/.test(secret) || !/^[a-f0-9]{64}$/.test(version)) { return ''; }
    // ArkWeb scriptRules match origins, so guard the exact pinned top-level document too.
    return `(() => { if (window.top !== window || location.origin !== 'http://127.0.0.1:9090' || ` +
      `location.pathname !== '/ui/versions/${version}/' || location.search) return; ` +
      `Object.defineProperty(window, '__OHOS_PANEL_BOOTSTRAP__', { configurable: true, ` +
      `value: { secret: '${secret}', version: '${version}' } }); })();`;
  }

  start(context: common.Context, changed: (view: ZashboardSessionView | null, error: string) => void): void {
    this.stop();
    const generation = this.generation;
    this.poll(context, generation, changed);
  }

  stop(): void {
    this.generation++;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.controllerSession = '';
  }

  private async poll(context: common.Context, generation: number,
    changed: (view: ZashboardSessionView | null, error: string) => void): Promise<void> {
    try {
      if (VpnController.status !== VpnStatus.Connected) { throw new Error('not ready'); }
      CoreApi.bindContext(context);
      const session = await CoreApi.getControllerSession(); // authenticated REST, not static /ui/ 200
      const ui = await CoreApi.getControllerUiStatus();
      if (session === null || ui === null || !ui.available) { throw new Error('not ready'); }
      if (generation !== this.generation) { return; }
      if (session !== this.controllerSession) {
        const deployment = await ZashboardAssets.prepare(context);
        if (deployment.directory === '' || deployment.version !== ZASHBOARD_VERSION) {
          throw new Error('untrusted resources');
        }
        const access = CoreApi.getControllerAccess();
        if (access === null || generation !== this.generation || VpnController.status !== VpnStatus.Connected) {
          throw new Error('not ready');
        }
        const bootstrap = ZashboardSession.bootstrap(access.secret, deployment.version);
        if (bootstrap === '') { throw new Error('not ready'); }
        this.controllerSession = session;
        changed({ url: `${access.httpBase}/ui/`, version: deployment.version, bootstrap }, '');
      }
    } catch (_) {
      if (generation !== this.generation) { return; }
      this.controllerSession = '';
      changed(null, '面板会话或资源不可用，正在重试；VPN 状态由原生宿主管理。');
    } finally {
      if (generation === this.generation) {
        this.timer = setTimeout(() => {
          this.timer = -1;
          this.poll(context, generation, changed);
        }, 3000);
      }
    }
  }
}
