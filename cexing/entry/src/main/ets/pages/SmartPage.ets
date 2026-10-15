import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { CoreApi, SmartStatus } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { SmartModelRestart } from '../lib/SmartModelRestart';
import { BoundedFileReader } from '../lib/BoundedFileReader';
import { Settings } from '../lib/Settings';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { NativeTheme as UI } from './NativeTheme';

const MODEL_URL = 'https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model';
const MODEL_BYTES = 9345218;

@Component
export struct SmartPage {
  @Consume('nav') navStack: NavPathStack;
  @State private detailsOpen: boolean = false;
  @State private usage: string = UiText.get($r('app.string.smart_after_connect'));
  @State private nextStep: string = UiText.get($r('app.string.smart_connect_first'));
  @State private predictionNote: string = '';
  @Prop @Watch('onVisible') visible: boolean = false;
  @State private message: string = '';
  @State private groupSummary: string = UiText.get($r('app.string.state_not_checked'));
  @State private modelSummary: string = UiText.get($r('app.string.state_not_checked'));
  @State private predictions: string = UiText.get($r('app.string.smart_no_evidence'));
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private restartRequired: boolean = false;
  @State private autoConvert: boolean = true;
  private generation: number = 0;
  private importGeneration: number = 0;
  private timer: number = -1;
  private active: boolean = false;
  private operationSequence: number = 0;
  private activeOperation: number = 0;
  private statusListener: (status: VpnStatus) => void = (_status: VpnStatus) => { this.onVisible(); };

  private beginOperation(): number {
    this.activeOperation = ++this.operationSequence;
    this.busy = true;
    return this.activeOperation;
  }

  private ownsOperation(operation: number): boolean { return this.active && operation === this.activeOperation; }

  private finishOperation(operation: number): void {
    if (this.ownsOperation(operation)) { this.activeOperation = 0; this.busy = false; }
  }

  private cancelOperation(): void { this.activeOperation = 0; this.busy = false; }

  aboutToAppear(): void {
    this.active = true;
    VpnController.onChanged(this.statusListener);
    this.autoConvert = Settings.load(getContext(this) as common.UIAbilityContext).smartAutoConvert;
    this.onVisible();
  }

  aboutToDisappear(): void {
    this.importGeneration++;
    this.active = false;
    VpnController.offChanged(this.statusListener);
    this.cancelOperation();
    this.stopPolling();
  }

  private stopPolling(): void {
    this.generation++;
    clearTimeout(this.timer);
    this.timer = -1;
  }

  private onVisible(): void {
    if (!this.visible && this.active) {
      const routes = this.navStack.getAllPathName();
      if (routes.length === 0 || routes[routes.length - 1] !== 'smart') {
        this.importGeneration++; this.cancelOperation();
      }
    }
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
      this.usage = VpnController.status === VpnStatus.Connected ? UiText.get($r('app.string.state_unavailable')) : UiText.get($r('app.string.smart_after_connect'));
      this.groupSummary = UiText.get($r('app.string.smart_wait_config'));
      this.nextStep = VpnController.status === VpnStatus.Connected ? UiText.get($r('app.string.smart_retry_status')) : UiText.get($r('app.string.smart_connect_first'));
      this.predictionNote = '';
      this.modelSummary = UiText.get($r('app.string.state_not_checked'));
      this.predictions = UiText.get($r('app.string.smart_wait_predictions'));
    } else {
      this.restartRequired = this.restartRequired || status.model.restartRequired;
      const names = Object.keys(status.groups);
      this.usage = names.length === 0 ? UiText.get($r('app.string.smart_not_used')) : UiText.get($r('app.string.smart_enabled'));
      this.nextStep = names.length === 0 ?
        UiText.get($r('app.string.smart_profile_strategy')) :
        UiText.get($r('app.string.smart_panel_strategy'));
      this.groupSummary = names.length === 0 ? UiText.get($r('app.string.smart_choose_strategy')) :
        names.map((name: string) => UiText.get($r('app.string.smart_group'), name, status.groups[name].useLightGBM ? UiText.get($r('app.string.smart_model_strategy')) : UiText.get($r('app.string.smart_statistics')))).join('\n');
      const state = status.model.state;
      this.modelSummary = state === 'loaded' ? UiText.get($r('app.string.smart_model_loaded')) :
        (state === 'missing' ? UiText.get($r('app.string.smart_model_missing')) :
          (state === 'invalid' ? UiText.get($r('app.string.smart_model_invalid')) :
            (state === 'loading' ? UiText.get($r('app.string.smart_model_loading')) : UiText.get($r('app.string.smart_model_not_requested')))));
      this.predictions = status.model.predictions > 0 ?
        UiText.get($r('app.string.smart_predictions'), status.model.predictions) : UiText.get($r('app.string.smart_predictions_zero'));
      this.predictionNote = status.model.predictions > 0 ?
        UiText.get($r('app.string.smart_prediction_evidence')) :
        UiText.get($r('app.string.smart_prediction_none'));
    }
    this.timer = setTimeout(() => { this.refresh(generation); }, 3000);
  }

  private async openModelSource(): Promise<void> {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: MODEL_URL });
    } catch (_) { this.message = UiText.get($r('app.string.smart_source_fallback'), MODEL_URL); }
  }

  private async changeAutoConvert(on: boolean): Promise<void> {
    if (this.busy) { return; }
    const operation = this.beginOperation();
    const before = this.autoConvert;
    this.autoConvert = on;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const result = await ProfileTransactions.setSmartAutoConvert(context, on);
      if (!this.ownsOperation(operation)) { return; }
      this.message = result === 'applied' ? UiText.get($r('app.string.smart_applied')) : UiText.get($r('app.string.smart_saved_next'));
      this.stopPolling();
      this.refresh(this.generation);
    } catch (error) {
      if (this.ownsOperation(operation)) { this.autoConvert = before; this.message = (error as Error).message; }
    } finally { this.finishOperation(operation); }
  }

  private importCurrent(generation: number): boolean {
    return this.active && this.visible && VpnController.status === VpnStatus.Connected && generation === this.importGeneration;
  }

  private async importModel(): Promise<void> {
    if (this.busy || !this.ready) { return; }
    const operation = this.beginOperation();
    // 系统文件选择器可触发页面隐藏和恢复；轮询重启不撤销仍在本页的导入。
    const generation = this.importGeneration;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const uris = await new picker.DocumentViewPicker(context).select({
        maxSelectNumber: 1, selectMode: picker.DocumentSelectMode.FILE, fileSuffixFilters: ['.bin']
      });
      if (!this.importCurrent(generation) || uris.length === 0) { return; }
      const bytes = await BoundedFileReader.bytes(uris[0], MODEL_BYTES,
        () => this.importCurrent(generation), MODEL_BYTES);
      if (!this.importCurrent(generation)) { return; }
      const result = await CoreApi.importSmartModel(bytes);
      if (!this.importCurrent(generation)) { return; }
      if (result === null) { throw new Error(UiText.get($r('app.string.smart_import_failed'))); }
      this.restartRequired = result.restartRequired;
      this.message = result.restartRequired ? UiText.get($r('app.string.smart_installed_restart')) :
        UiText.get($r('app.string.smart_installed'));
    } catch (error) {
      if (this.importCurrent(generation)) { this.message = (error as Error).message; }
    } finally { this.finishOperation(operation); }
  }

  private confirmRestart(): void {
    const generation = this.generation;
    AlertDialog.show({
      title: UiText.get($r('app.string.smart_restart_title')), message: UiText.get($r('app.string.smart_restart_warning')),
      primaryButton: { value: UiText.get($r('app.string.action_cancel')), action: () => {} },
      secondaryButton: { value: UiText.get($r('app.string.smart_restart')), action: () => {
        if (!this.current(generation) || this.busy) { return; }
        const operation = this.beginOperation();
        SmartModelRestart.restart(getContext(this) as common.UIAbilityContext).catch((error: Error) => {
          if (this.ownsOperation(operation)) { this.message = error.message; }
        }).finally(() => { this.finishOperation(operation); });
      } }
    });
  }

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Column({ space: 12 }) {
          Text(this.usage).fontSize(20).fontWeight(600).fontColor(UI.ink)
          Button(UiText.get($r('app.string.action_open_panel'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.accentText)
            .enabled(this.ready).onClick(() => { this.navStack.pushPath({ name: 'zashboard' }); })
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Row({ space: 12 }) {
          Text(UiText.get($r('app.string.smart_auto_enable'))).fontSize(17).fontWeight(600).fontColor(UI.ink).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoConvert })
            .selectedColor(UI.accent).accessibilityChecked(this.autoConvert).enabled(!this.busy).accessibilityText(UiText.get($r('app.string.smart_auto_enable')))
            .onChange((on: boolean) => { this.changeAutoConvert(on); })
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
        if (this.message !== '') {
          Text(this.message).fontSize(14).fontColor(UI.muted)
        }
        if (this.restartRequired) {
          Button(UiText.get($r('app.string.smart_restart_apply'))).width('100%').constraintSize({ minHeight: 56 }).enabled(!this.busy)
            .backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.confirmRestart())
        }
        Button(this.detailsOpen ? UiText.get($r('app.string.action_collapse_details')) : UiText.get($r('app.string.action_details'))).width('100%').constraintSize({ minHeight: 48 })
          .backgroundColor(UI.soft).fontColor(UI.accentText)
          .accessibilityDescription(this.detailsOpen ? UiText.get($r('app.string.a11y_expanded')) : UiText.get($r('app.string.a11y_collapsed')))
          .onClick(() => { this.detailsOpen = !this.detailsOpen; })
        if (this.detailsOpen) {
        Column({ space: 12 }) {
          Text(UiText.get($r('app.string.smart_current_config'))).fontSize(13).fontColor(UI.muted)
          Text(this.groupSummary).fontSize(15).fontColor(UI.ink)
          Text(this.nextStep).fontSize(14).fontColor(UI.muted)
          Text(UiText.get($r('app.string.smart_region_details')))
            .fontSize(14).fontColor(UI.muted)
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Column({ space: 12 }) {
          Text(UiText.get($r('app.string.resource_model'))).fontSize(13).fontColor(UI.muted)
          Text(this.modelSummary).fontSize(20).fontWeight(600, { enableVariableFontWeight: true }).fontColor(UI.ink)
          Text(this.predictions).fontSize(14).fontColor(UI.muted)
          Text(this.predictionNote).fontSize(14).fontColor(UI.muted)
        }.padding(20).width('100%').borderRadius(24).backgroundColor(UI.surface)
          .alignItems(HorizontalAlign.Start)
        Text(UiText.get($r('app.string.smart_bundled_model'))).fontSize(14).fontColor(UI.muted)
        Button(UiText.get($r('app.string.smart_official_model'))).width('100%').constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.accentText)
          .onClick(() => this.openModelSource())
        Text(UiText.get($r('app.string.smart_manual_hint'))).fontSize(14).fontColor(UI.muted)
        Button(this.busy ? UiText.get($r('app.string.action_working')) : UiText.get($r('app.string.smart_import_recovery'))).width('100%').constraintSize({ minHeight: 56 })
          .backgroundColor(UI.action).fontColor(UI.onAccent).enabled(this.ready && !this.busy).onClick(() => this.importModel())
        }
      }.width('100%').constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start).padding(24)
    }.width('100%').height('100%').backgroundColor(UI.paper)
  }
}
