import { connection } from '@kit.NetworkKit';
import { AiProbeService, AiServiceResult } from '../lib/AiProbeService';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct AiProbeStatus {
  // Supply only the successfully published/applied AI template's revision.
  @Prop @Watch('revisionChanged') revision: string = '';
  @State private results: AiServiceResult[] = [];
  @State private checking: boolean = false;
  @State private expanded: boolean = false;
  private service: AiProbeService | null = null;
  private network: connection.NetConnection | null = null;
  private visible: boolean = false;
  private online: boolean = false;
  private onVpn: (status: VpnStatus) => void = (status: VpnStatus): void => {
    if (status !== VpnStatus.Connected) { this.clear(); }
    else { this.service?.check(this.revision); }
  };

  aboutToAppear(): void {
    this.visible = true;
    this.service = new AiProbeService(() => this.visible && this.online && VpnController.status === VpnStatus.Connected,
      (results: AiServiceResult[], checking: boolean): void => { this.results = results; this.checking = checking; });
    VpnController.onChanged(this.onVpn);
    // Read-only observation: no bearer/network requests, bindings or system
    // settings. GET_NETWORK_INFO is a normal app permission supplied by host.
    const observer = connection.createNetConnection();
    this.network = observer;
    observer.on('netLost', () => { if (this.network === observer) { this.online = false; this.clear(); } });
    observer.on('netUnavailable', () => { if (this.network === observer) { this.online = false; this.clear(); } });
    observer.on('netAvailable', () => {
      if (this.visible && this.network === observer) { this.online = true; this.service?.check(this.revision); }
    });
    try {
      observer.register((error): void => {
        if (!this.visible || this.network !== observer) { try { observer.unregister(() => {}); } catch (_) {} return; }
        if (error !== undefined) { this.online = false; this.clear(); }
      });
    } catch (_) { this.online = false; this.clear(); }
  }
  aboutToDisappear(): void {
    this.visible = false;
    this.service?.cancel(); this.service = null;
    VpnController.offChanged(this.onVpn);
    const observer = this.network; this.network = null;
    try { observer?.unregister(() => {}); } catch (_) {}
  }
  private clear(): void { this.service?.cancel(); this.checking = false; this.results = []; }
  private revisionChanged(): void { this.clear(); if (this.visible) { this.service?.check(this.revision); } }
  private status(state: string): string {
    if (state === 'reachable') { return '可达'; }
    if (state === 'region_restricted') { return '地区限制'; }
    if (state === 'limited') { return '稍后重试'; }
    if (state === 'timeout') { return '超时'; }
    if (state === 'network_failed') { return '连接失败'; }
    return '未确认';
  }
  private summary(): string {
    if (this.checking) { return '检查中'; }
    if (this.results.length === 0) { return '未检查'; }
    const available = this.results.filter((r: AiServiceResult) => r.state === 'reachable').length;
    if (available === 3) { return '可达'; }
    if (this.results.some((r: AiServiceResult) => r.state === 'region_restricted')) { return '部分地区限制'; }
    if (this.results.some((r: AiServiceResult) => r.state === 'limited')) { return '稍后重试'; }
    return available > 0 ? `${available}/3 可达` : '未确认';
  }
  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Button(this.summary()).backgroundColor(UI.soft).fontColor(UI.muted)
          .onClick(() => { this.expanded = !this.expanded; })
        if (this.results.length > 0) {
          Text(new Date(this.results[0].at).toLocaleTimeString()).fontSize(12).fontColor(UI.muted)
        }
        Blank()
        Button('重试').backgroundColor(UI.soft).fontColor(UI.ink).enabled(!this.checking)
          .onClick(() => this.service?.check(this.revision, true))
      }.width('100%')
      if (this.expanded) {
        ForEach(this.results, (result: AiServiceResult) => {
          Row() {
            Text(result.service === 'chatgpt' ? 'ChatGPT' : result.service === 'claude' ? 'Claude' : 'Gemini').fontSize(13)
            Blank()
            Text(this.status(result.state)).fontSize(13).fontColor(UI.muted)
          }.width('100%')
        }, (result: AiServiceResult) => result.service)
      }
    }.width('100%')
  }
}
