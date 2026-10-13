import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { CoreApi, SmartStatus } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { SmartModelRestart } from '../lib/SmartModelRestart';
import { NativeTheme as UI } from './NativeTheme';

const MODEL_URL = 'https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model';
const MODEL_BYTES = 9345218;

@Component
export struct SmartPage {
  @Prop @Watch('onVisible') visible: boolean = false;
  @State private message: string = '连接 VPN 后查看 Smart 状态';
  @State private groupSummary: string = '尚未检查';
  @State private modelSummary: string = '尚未检查';
  @State private predictions: string = '尚无模型参与证据';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private restartRequired: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.onVisible();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.stopPolling();
  }

  private stopPolling(): void {
    this.generation++;
    clearTimeout(this.timer);
    this.timer = -1;
  }

  private onVisible(): void {
    this.stopPolling();
    if (this.active && this.visible) { this.refresh(this.generation); }
  }

  private current(generation: number): boolean {
    return this.active && this.visible && generation === this.generation;
  }

  private async refresh(generation: number): Promise<void> {
    const status: SmartStatus | null = VpnController.status === VpnStatus.Connected ?
      await CoreApi.getSmartStatus() : null;
    if (!this.current(generation)) { return; }
    this.ready = status !== null;
    if (status === null) {
      this.groupSummary = 'Controller 暂不可达';
      this.modelSummary = '尚未检查';
      this.predictions = '尚无模型参与证据';
      if (!this.busy) { this.message = '连接 VPN 后查看状态或导入模型'; }
    } else {
      this.restartRequired = this.restartRequired || status.model.restartRequired;
      const names = Object.keys(status.groups);
      this.groupSummary = names.length === 0 ? '当前配置没有 Smart 策略组' :
        names.map((name: string) => `${name} · ${status.groups[name].useLightGBM ? '请求模型' : '统计策略'}`).join('\n');
      const state = status.model.state;
      this.modelSummary = state === 'loaded' ? '模型已加载' :
        (state === 'missing' ? '模型缺失，使用统计策略' :
          (state === 'invalid' ? '模型无效，使用统计策略' :
            (state === 'loading' ? '模型加载中' : '尚未请求加载模型')));
      this.predictions = status.model.predictions > 0 ?
        `本进程有效预测 ${status.model.predictions} 次（全部 Smart 组累计）` : '尚无模型参与证据';
      if (!this.busy && !this.restartRequired) { this.message = status.message; }
    }
    this.timer = setTimeout(() => { this.refresh(generation); }, 3000);
  }

  private async openModelSource(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: MODEL_URL });
    } catch (_) { this.message = `请在浏览器打开 ${MODEL_URL}`; }
  }

  private async importModel(): Promise<void> {
    if (this.busy || !this.ready) { return; }
    this.busy = true;
    const generation = this.generation;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const uris = await new picker.DocumentViewPicker(context).select({
        maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FILE, fileSuffixFilters: ['.bin']
      });
      if (!this.current(generation) || uris.length === 0) { return; }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const bytes = new ArrayBuffer(MODEL_BYTES);
      try {
        if (fileIo.statSync(file.fd).size !== MODEL_BYTES) { throw new Error('模型大小须为 9,345,218 字节'); }
        let offset = 0;
        while (offset < MODEL_BYTES) {
          const chunk = new ArrayBuffer(Math.min(1024 * 1024, MODEL_BYTES - offset));
          const length = fileIo.readSync(file.fd, chunk);
          if (length <= 0) { throw new Error('模型文件未完整读取'); }
          new Uint8Array(bytes).set(new Uint8Array(chunk, 0, length), offset);
          offset += length;
        }
      } finally { fileIo.closeSync(file); }
      if (!this.current(generation)) { return; }
      const result = await CoreApi.importSmartModel(bytes);
      if (!this.current(generation)) { return; }
      if (result === null) { throw new Error('导入失败：请核对官方 Model.bin 版本、文件摘要和 VPN 连接'); }
      this.restartRequired = result.restartRequired;
      this.message = result.restartRequired ? '模型已校验安装，请重启应用使模型生效' :
        '模型已校验安装；在订阅编辑页将 Smart 组的 uselightgbm 改为 true 后重新连接';
    } catch (error) {
      if (this.current(generation)) { this.message = (error as Error).message; }
    } finally { this.busy = false; }
  }

  private confirmRestart(): void {
    const generation = this.generation;
    AlertDialog.show({
      title: '重启应用使模型生效？', message: '会断开 VPN 并重启整个应用；重新打开后请手动连接。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '重启应用', action: () => {
        if (!this.current(generation) || this.busy) { return; }
        this.busy = true;
        SmartModelRestart.restart(getContext(this) as common.UIAbilityContext).catch((error: Error) => {
          if (this.current(generation)) { this.message = error.message; }
        }).finally(() => { this.busy = false; });
      } }
    });
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 12 }) {
          Text('策略状态').fontSize(13).fontColor(UI.muted)
          Text(this.groupSummary).fontSize(17).fontColor(UI.ink)
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Column({ space: 12 }) {
          Text('离线模型').fontSize(13).fontColor(UI.muted)
          Text(this.modelSummary).fontSize(20).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.ink)
          Text(this.predictions).fontSize(14).fontColor(UI.muted)
          Text(this.message).fontSize(14).fontColor(UI.muted)
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Text('在订阅中配置 type: smart，引用至少两个节点并让规则引用该组。无模型可用统计策略。').fontSize(14).fontColor(UI.muted)
        Button('获取官方模型').width('100%').height(48).backgroundColor(UI.soft).fontColor(UI.accentText)
          .onClick(() => this.openModelSource())
        Text('下载官方 Model.bin 后导入，应用会校验文件。').fontSize(14).fontColor(UI.muted)
        Button(this.busy ? '处理中…' : '导入模型').width('100%').height(56)
          .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.ready && !this.busy).onClick(() => this.importModel())
        if (this.restartRequired) {
          Button('重启应用使模型生效').width('100%').height(56).enabled(!this.busy)
            .backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.confirmRestart())
        }
      }.width('100%').constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start).padding(24)
    }.width('100%').height('100%').backgroundColor(UI.paper)
  }
}
