import { common } from '@kit.AbilityKit';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { ProfileTransactions } from '../lib/ProfileTransactions';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct ProfileStorageDetails {
  @Consume('tab') @Watch('onVisibilityChanged') tab: number = 2;
  @Consume('rootVisible') @Watch('onVisibilityChanged') rootVisible: boolean = true;
  @State expanded: boolean = false;
  @State working: boolean = false;
  @State summary: string = '';
  @State failure: string = '';
  private generation: number = 0;
  private active: boolean = false;
  aboutToAppear(): void { this.active = true; }
  aboutToDisappear(): void { this.active = false; this.generation++; this.working = false; }
  private onVisibilityChanged(): void {
    this.generation++; this.active = this.tab === 2 && this.rootVisible; this.working = false;
  }
  private async refresh(): Promise<void> {
    if (!this.active || this.working) { return; }
    const generation = ++this.generation;
    this.working = true; this.failure = '';
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await ProfileTransactions.refreshStorage(context);
      if (!this.active || generation !== this.generation) { return; }
      const report = EffectiveVersions.storageReport(context);
      if (report === null) { this.summary = ''; this.failure = '暂无统计，请重试'; return; }
      this.summary = `${report.versions} 个版本 · ${(report.bytes / 1048576).toFixed(1)} MiB`;
      if (!report.complete) { this.failure = '暂无法整理，请稍后重试'; }
    } catch (_) {
      if (this.active && generation === this.generation) { this.failure = '暂无法统计，请稍后重试'; }
    } finally { if (generation === this.generation) { this.working = false; } }
  }
  build() {
    Column({ space: 8 }) {
      Button(this.expanded ? '收起存储详情' : '存储详情').width('100%').height(48).onClick(() => {
        this.expanded = !this.expanded;
        if (this.expanded) { this.refresh(); } else { this.generation++; this.working = false; }
      })
      if (this.expanded) {
        if (this.summary !== '') { Text(this.summary).fontSize(14).fontColor(UI.ink) }
        if (this.failure !== '') { Text(this.failure).fontSize(14).fontColor(UI.muted) }
        Button(this.working ? '正在统计' : '刷新').width('100%').height(48).enabled(!this.working).onClick(() => this.refresh())
      }
    }.width('100%').padding(14).backgroundColor(UI.surface).borderRadius(24)
  }
}
