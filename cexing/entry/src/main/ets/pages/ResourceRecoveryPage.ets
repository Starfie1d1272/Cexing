import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { NativeTheme as UI } from './NativeTheme';
import { ResourceRecovery, ResourceStatus, RecoverableResource } from '../lib/ResourceRecovery';
import { ResourceCancellation } from '../lib/GeoDataAssets';
import { VpnController, VpnStatus } from '../lib/VpnController';

@Component
export struct ResourceRecoveryPage {
  @Prop @Watch('visibilityChanged') visible: boolean = true;
  @State resources: ResourceStatus[] = [];
  @State busy: boolean = false;
  @State private vpnStatus: VpnStatus = VpnController.status;
  @State private stopUnknown: boolean = VpnController.needsStop();
  private listener: (status: VpnStatus) => void = (status: VpnStatus) => {
    this.vpnStatus = status; this.stopUnknown = VpnController.needsStop();
  };
  @State message: string = '';
  private epoch: number = 0;
  private active: boolean = false;
  private cancellation: ResourceCancellation = { cancelled: false };

  aboutToAppear(): void {
    this.vpnStatus = VpnController.status; this.stopUnknown = VpnController.needsStop();
    VpnController.onChanged(this.listener);
    this.active = this.visible;
    if (this.active) { this.refresh(); }
  }

  private visibilityChanged(): void {
    if (this.active === this.visible) { return; }
    if (this.visible) {
      this.active = true;
      this.refresh();
    } else { this.suspend(); }
  }

  aboutToDisappear(): void {
    VpnController.offChanged(this.listener);
    this.suspend();
  }

  private suspend(): void {
    this.active = false;
    this.epoch++;
    this.cancellation.cancelled = true;
    this.busy = false;
  }

  private async refresh(): Promise<void> {
    const epoch = ++this.epoch;
    this.busy = true;
    try {
      const resources = await ResourceRecovery.inspect(getContext(this) as common.UIAbilityContext);
      if (this.active && epoch === this.epoch) { this.resources = resources; }
    } catch (_) {
      if (this.active && epoch === this.epoch) { this.message = UiText.get($r('app.string.resource_read_failed')); }
    } finally {
      if (this.active && epoch === this.epoch) { this.busy = false; }
    }
  }

  private async restore(id: RecoverableResource): Promise<void> {
    if (this.busy || !this.active) { return; }
    const epoch = ++this.epoch;
    this.busy = true;
    this.message = '';
    const cancellation: ResourceCancellation = { cancelled: false };
    this.cancellation = cancellation;
    try {
      await ResourceRecovery.restore(getContext(this) as common.UIAbilityContext, id,
        cancellation, () => VpnController.status === VpnStatus.Disconnected && !VpnController.needsStop());
      if (!this.active || epoch !== this.epoch) { return; }
      this.message = UiText.get($r('app.string.resource_restored'));
      const resources = await ResourceRecovery.inspect(getContext(this) as common.UIAbilityContext);
      if (this.active && epoch === this.epoch) { this.resources = resources; }
    } catch (error) {
      if (this.active && epoch === this.epoch) { this.message = (error as Error).message; }
    } finally {
      if (this.active && epoch === this.epoch) { this.busy = false; }
    }
  }

  private resourceLabel(id: RecoverableResource): string {
    return id === 'model' ? UiText.get($r('app.string.resource_model')) :
      (id === 'geodata' ? UiText.get($r('app.string.resource_geodata')) : UiText.get($r('app.string.nav_panel')));
  }

  build() {
    Scroll() {
    Column({ space: 16 }) {
      ForEach(this.resources, (item: ResourceStatus) => {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(this.resourceLabel(item.id)).fontSize(17).fontColor(UI.ink)
            Text(item.state === 'ready' ? UiText.get($r('app.string.resource_ready')) : item.state === 'missing' ? UiText.get($r('app.string.resource_missing')) : UiText.get($r('app.string.resource_invalid')))
              .fontSize(14).fontColor(UI.muted)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(UiText.get($r('app.string.action_restore'))).backgroundColor(UI.soft).fontColor(UI.ink).constraintSize({ minHeight: 44 })
            .enabled(!this.busy && this.vpnStatus === VpnStatus.Disconnected && !this.stopUnknown)
            .accessibilityDescription(this.vpnStatus !== VpnStatus.Disconnected || this.stopUnknown ?
              UiText.get($r('app.string.a11y_restore_stopped')) : (this.busy ? UiText.get($r('app.string.action_working')) : ''))
            .onClick(() => this.restore(item.id))
            .accessibilityText(UiText.get($r('app.string.resource_restore_name'), this.resourceLabel(item.id)))
        }.width('100%').padding(16).backgroundColor(UI.surface).borderRadius(16)
      }, (item: ResourceStatus) => item.id)
      if (this.busy) { LoadingProgress().width(24).height(24) }
      if (this.message !== '') { Text(this.message).fontSize(14).fontColor(UI.muted) }
      if (this.resources.length === 0 && !this.busy) {
        Button(UiText.get($r('app.string.action_retry'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.refresh())
      }
    }.width('100%').padding(20).backgroundColor(UI.paper)
    }.width('100%').height('100%').backgroundColor(UI.paper)
  }
}
