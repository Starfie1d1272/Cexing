import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { CoreApi } from '../lib/CoreApi';
import { LiveViewStrategy } from '../lib/LiveViewStrategy';
import { LiveViewKeeper } from '../lib/LiveViewKeeper';
import { Settings } from '../lib/Settings';
import { VpnStatus } from '../lib/VpnController';
import { NativeTheme as UI } from './NativeTheme';

@Component
export struct LiveViewStrategyPicker {
  @Prop @Watch('cancel') status: VpnStatus = VpnStatus.Disconnected;
  @State private groups: string[] = [];
  @State private draft: string = '';
  @State private editing: boolean = false;
  @State private busy: boolean = false;
  @State private saving: boolean = false;
  @State private message: string = '';
  private active: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void { this.active = true; }
  aboutToDisappear(): void { this.active = false; this.cancel(); }

  private current(generation: number): boolean {
    return this.active && this.editing && this.status === VpnStatus.Connected && generation === this.generation;
  }

  private cancel(): void {
    this.generation++;
    this.editing = false; this.busy = false; this.saving = false; this.message = '';
  }

  private async open(): Promise<void> {
    if (!this.active || this.busy || this.status !== VpnStatus.Connected) { return; }
    const generation = ++this.generation;
    this.editing = true; this.busy = true; this.groups = []; this.message = '';
    try {
      const proxies = await CoreApi.getProxies();
      if (!this.current(generation)) { return; }
      if (proxies === null) { this.message = UiText.get($r('app.string.strategy_unavailable')); return; }
      this.groups = LiveViewStrategy.groups(proxies);
      this.draft = Settings.load(getContext(this) as common.UIAbilityContext).mainGroup;
    } catch (_) {
      if (this.current(generation)) { this.message = UiText.get($r('app.string.strategy_unavailable')); }
    } finally { if (this.current(generation)) { this.busy = false; } }
  }

  private async apply(): Promise<void> {
    if (this.busy || !this.current(this.generation)) { return; }
    const generation = this.generation;
    const chosen = this.draft;
    this.busy = true; this.saving = true;
    try {
      const proxies = await CoreApi.getProxies();
      if (!this.current(generation)) { return; }
      if (proxies === null || (chosen.length > 0 && !LiveViewStrategy.groups(proxies).includes(chosen))) {
        this.message = UiText.get($r('app.string.strategy_changed')); return;
      }
      const context = getContext(this) as common.UIAbilityContext;
      const settings = Settings.load(context);
      settings.mainGroup = chosen;
      // Uses the durable, failure-reporting Settings.save contract from #126.
      await Settings.save(context, settings, ['mainGroup']);
      await LiveViewKeeper.refreshDisplayGroup();
      if (this.current(generation)) { this.editing = false; this.message = UiText.get($r('app.string.strategy_updated')); }
    } catch (_) {
      if (this.current(generation)) { this.message = UiText.get($r('app.string.strategy_save_failed')); }
    } finally {
      if (this.active && generation === this.generation) { this.busy = false; this.saving = false; }
    }
  }

  private selectedIndex(): number {
    return this.draft.length === 0 ? 0 : (this.groups.includes(this.draft) ? this.groups.indexOf(this.draft) + 1 : -1);
  }

  build() {
    Column({ space: 8 }) {
      Button(UiText.get($r('app.string.strategy_display'))).constraintSize({ minHeight: 44 }).width('100%')
        .enabled(!this.busy && this.status === VpnStatus.Connected)
        .backgroundColor(UI.soft).fontColor(UI.accentText).onClick(() => this.open())
      if (this.editing) {
        if (this.groups.length > 0) {
          Select(([{ value: UiText.get($r('app.string.strategy_auto')) }] as SelectOption[]).concat(this.groups.map((name: string): SelectOption => ({ value: name })))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink)
            .selected(this.selectedIndex()).value(this.draft.length > 0 ? this.draft : UiText.get($r('app.string.strategy_auto')))
            .enabled(!this.busy).accessibilityText(UiText.get($r('app.string.strategy_display')))
            .onSelect((index: number) => {
              if (index >= 0 && index <= this.groups.length) { this.draft = index === 0 ? '' : this.groups[index - 1]; }
            })
        }
        Row({ space: 12 }) {
          Button(UiText.get($r('app.string.action_cancel'))).constraintSize({ minHeight: 44 }).layoutWeight(1).enabled(!this.saving)
            .backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => this.cancel())
          Button(this.saving ? UiText.get($r('app.string.action_saving')) : UiText.get($r('app.string.action_apply'))).constraintSize({ minHeight: 44 }).layoutWeight(1)
            .enabled(!this.busy).backgroundColor(UI.action).fontColor(UI.onAccent).onClick(() => this.apply())
        }.width('100%')
      }
      if (this.message.length > 0) { Text(this.message).fontSize(13).fontColor(UI.muted).width('100%') }
    }.width('100%')
  }
}
