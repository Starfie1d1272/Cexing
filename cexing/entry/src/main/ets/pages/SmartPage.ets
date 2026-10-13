import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { CoreApi, SmartStatus } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { SmartModelRestart } from '../lib/SmartModelRestart';
import { Settings } from '../lib/Settings';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { NativeTheme as UI } from './NativeTheme';

const MODEL_URL = 'https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model';
const MODEL_BYTES = 9345218;

@Component
export struct SmartPage {
  @Consume('nav') navStack: NavPathStack;
  @State private detailsOpen: boolean = false;
  @State private usage: string = '连接后查看当前配置';
  @State private nextStep: string = '先连接 VPN，再查看 Smart 策略组。';
  @State private predictionNote: string = '';
  @Prop @Watch('onVisible') visible: boolean = false;
  @State private message: string = '';
  @State private groupSummary: string = '尚未检查';
  @State private modelSummary: string = '尚未检查';
  @State private predictions: string = '尚无模型参与证据';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private restartRequired: boolean = false;
  @State private autoConvert: boolean = true;
  private generation: number = 0;
  private timer: number = -1;
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.autoConvert = Settings.load(getContext(this) as common.UIAbilityContext).smartAutoConvert;
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
      this.usage = VpnController.status === VpnStatus.Connected ? '暂时无法读取 Smart 状态' : '连接后查看当前配置';
      this.groupSummary = '等待读取运行配置';
      this.nextStep = VpnController.status === VpnStatus.Connected ? '请稍后重试；仍无法读取时可检查本机服务。' : '先连接 VPN，再查看 Smart 策略组。';
      this.predictionNote = '';
      this.modelSummary = '尚未检查';
      this.predictions = '等待读取有效预测次数';
    } else {
      this.restartRequired = this.restartRequired || status.model.restartRequired;
      const names = Object.keys(status.groups);
      this.usage = names.length === 0 ? '当前运行配置没有 Smart 组' : `当前运行配置有 ${names.length} 个 Smart 组`;
      this.nextStep = names.length === 0 ?
        '自动转换适用于 URL Test 和负载均衡组。仅有手动选择组的订阅，可在订阅详情预览地区策略。' :
        '在控制面板查看策略组入口和当前选项；需要手动选择时切换到 Smart 入口，再访问网站并观察预测次数。';
      this.groupSummary = names.length === 0 ? '请按订阅的组类型选择策略' :
        names.map((name: string) => `${name} · ${status.groups[name].useLightGBM ? '已请求模型' : '统计策略'}`).join('\n');
      const state = status.model.state;
      this.modelSummary = state === 'loaded' ? '模型已加载' :
        (state === 'missing' ? '模型缺失，使用统计策略' :
          (state === 'invalid' ? '模型无效，使用统计策略' :
            (state === 'loading' ? '模型加载中' : '尚未请求加载模型')));
      this.predictions = status.model.predictions > 0 ?
        `本进程有效预测 ${status.model.predictions} 次（全部 Smart 组累计）` : '本进程有效预测 0 次';
      this.predictionNote = status.model.predictions > 0 ?
        '已记录有效预测；计数由全部 Smart 组累计，不对应某一次网站访问。' :
        '尚未记录有效预测。模型加载后，仍需 Smart 组被使用并产生符合条件的样本。';
    }
    this.timer = setTimeout(() => { this.refresh(generation); }, 3000);
  }

  private async openModelSource(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: MODEL_URL });
    } catch (_) { this.message = `请在浏览器打开 ${MODEL_URL}`; }
  }

  private async changeAutoConvert(on: boolean): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    const before = this.autoConvert;
    this.autoConvert = on;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.setSmartAutoConvert(context, on);
      this.message = result === 'applied' ? '已应用到当前运行配置' : '已保存，下次连接时生效';
      this.stopPolling();
      this.refresh(this.generation);
    } catch (error) {
      this.autoConvert = before;
      this.message = (error as Error).message;
    } finally { this.busy = false; }
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
        '模型已校验安装，可查看 Smart 组的模型策略状态';
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
          Text(this.usage).fontSize(20).fontWeight(600).fontColor(UI.ink)
          Text(this.groupSummary).fontSize(15).fontColor(UI.ink)
          Text(this.nextStep).fontSize(14).fontColor(UI.muted)
          Button('打开控制面板').width('100%').height(48).backgroundColor(UI.soft).fontColor(UI.accentText)
            .enabled(this.ready).onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('自动转换为 Smart').fontSize(17).fontWeight(600).fontColor(UI.ink)
            Text('全局默认：将 URL Test 和负载均衡组转换为 Smart；原始订阅保持不变。开关应用到当前配置，并在切换、更新和重新连接时继续生效。')
              .fontSize(13).fontColor(UI.muted)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.autoConvert })
            .selectedColor(UI.accent).enabled(!this.busy)
            .onChange((on: boolean) => { this.changeAutoConvert(on); })
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
        Text('地区策略在订阅详情中单独设置，仅作用于对应订阅；已有 Smart 组保留原有设置。')
          .fontSize(14).fontColor(UI.muted)
        if (this.message !== '') {
          Text(this.message).fontSize(14).fontColor(UI.muted)
        }
        if (this.restartRequired) {
          Button('重启应用使模型生效').width('100%').height(56).enabled(!this.busy)
            .backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.confirmRestart())
        }
        Button(this.detailsOpen ? '收起模型详情' : '查看模型详情').width('100%').height(48)
          .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => { this.detailsOpen = !this.detailsOpen; })
        if (this.detailsOpen) {
        Column({ space: 12 }) {
          Text('离线模型').fontSize(13).fontColor(UI.muted)
          Text(this.modelSummary).fontSize(20).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.ink)
          Text(this.predictions).fontSize(14).fontColor(UI.muted)
          Text(this.predictionNote).fontSize(14).fontColor(UI.muted)
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Text('官方模型已随安装包提供。模型加载与有效预测分别展示；模型不可用时使用统计策略。').fontSize(14).fontColor(UI.muted)
        Button('查看官方模型来源').width('100%').height(48).backgroundColor(UI.soft).fontColor(UI.accentText)
          .onClick(() => this.openModelSource())
        Text('仅在需要手动恢复时导入官方 Model.bin；应用会校验文件。').fontSize(14).fontColor(UI.muted)
        Button(this.busy ? '处理中…' : '手动导入模型（恢复用）').width('100%').height(56)
          .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.ready && !this.busy).onClick(() => this.importModel())
        }
      }.width('100%').constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start).padding(24)
    }.width('100%').height('100%').backgroundColor(UI.paper)
  }
}
