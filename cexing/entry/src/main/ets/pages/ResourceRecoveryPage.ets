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
  @State message: string = '';
  private epoch: number = 0;
  private active: boolean = false;
  private cancellation: ResourceCancellation = { cancelled: false };

  aboutToAppear(): void {
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
      if (this.active && epoch === this.epoch) { this.message = '无法查看资源，请重试'; }
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
      this.message = '已恢复';
      const resources = await ResourceRecovery.inspect(getContext(this) as common.UIAbilityContext);
      if (this.active && epoch === this.epoch) { this.resources = resources; }
    } catch (error) {
      if (this.active && epoch === this.epoch) { this.message = (error as Error).message; }
    } finally {
      if (this.active && epoch === this.epoch) { this.busy = false; }
    }
  }

  build() {
    Column({ space: 16 }) {
      ForEach(this.resources, (item: ResourceStatus) => {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(item.label).fontSize(17).fontColor(UI.ink)
            Text(item.state === 'ready' ? '可用' : item.state === 'missing' ? '未安装' : '需要恢复')
              .fontSize(14).fontColor(UI.muted)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('恢复').enabled(!this.busy).onClick(() => this.restore(item.id))
            .accessibilityText(`恢复${item.label}`)
        }.width('100%').padding(16).backgroundColor(UI.surface).borderRadius(16)
      }, (item: ResourceStatus) => item.id)
      if (this.busy) { LoadingProgress().width(24).height(24) }
      if (this.message !== '') { Text(this.message).fontSize(14).fontColor(UI.muted) }
      if (this.resources.length === 0 && !this.busy) {
        Button('重试').onClick(() => this.refresh())
      }
    }.width('100%').padding(20).backgroundColor(UI.paper)
  }
}
