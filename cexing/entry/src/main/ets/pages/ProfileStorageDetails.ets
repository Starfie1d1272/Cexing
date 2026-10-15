import { UiText } from '../lib/UiText';
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
    this.working = true; this.failure = ''; this.summary = '';
    const context = getContext(this) as common.UIAbilityContext;
    try {
      await ProfileTransactions.refreshStorage(context);
      if (!this.active || generation !== this.generation) { return; }
      const report = EffectiveVersions.storageReport(context);
      if (report === null) { this.summary = ''; this.failure = UiText.get($r('app.string.storage_no_stats')); return; }
      this.summary = report.complete ? UiText.get($r('app.string.storage_summary'), report.versions, (report.bytes / 1048576).toFixed(1)) : '';
      if (!report.complete) { this.failure = UiText.get($r('app.string.storage_incomplete')); }
    } catch (_) {
      if (this.active && generation === this.generation) { this.failure = UiText.get($r('app.string.storage_stats_failed')); }
    } finally { if (generation === this.generation) { this.working = false; } }
  }
  build() {
    Column({ space: 8 }) {
      Button(this.expanded ? UiText.get($r('app.string.storage_collapse')) : UiText.get($r('app.string.storage_details'))).backgroundColor(UI.soft).fontColor(UI.ink).width('100%').constraintSize({ minHeight: 48 }).accessibilityDescription(this.expanded ? UiText.get($r('app.string.storage_expanded')) : UiText.get($r('app.string.storage_collapsed'))).onClick(() => {
        this.expanded = !this.expanded;
        if (this.expanded) { this.refresh(); } else { this.generation++; this.working = false; }
      })
      if (this.expanded) {
        if (this.summary !== '') { Text(this.summary).fontSize(14).fontColor(UI.ink) }
        if (this.failure !== '') { Text(this.failure).fontSize(14).fontColor(UI.muted) }
        Button(this.working ? UiText.get($r('app.string.storage_working')) : UiText.get($r('app.string.storage_refresh'))).backgroundColor(UI.soft).fontColor(UI.ink).width('100%').constraintSize({ minHeight: 48 }).enabled(!this.working).accessibilityDescription(this.working ? UiText.get($r('app.string.storage_working')) : '').onClick(() => this.refresh())
      }
    }.width('100%').padding(14).backgroundColor(UI.surface).borderRadius(24)
  }
}
