import { UiText } from '../lib/UiText';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { EffectiveVersions } from '../lib/EffectiveVersions';
import { ProfileEditBus } from './ProfileEditPage';
import { NativeTheme as UI } from './NativeTheme';

/** Explicit local inspection of the last published result. Never stages or applies. */
@Component
export struct ProfileGeneratedPage {
  @State content: string = '';
  @State error: string = '';
  @State loading: boolean = true;
  private generation: number = 0;

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.generation++; }

  private async load(): Promise<void> {
    const request = ++this.generation;
    const file = ProfileEditBus.current;
    this.loading = true;
    this.content = '';
    this.error = '';
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const version = EffectiveVersions.read(context)?.Profiles[file];
      if (version === undefined) {
        if (request === this.generation) { this.error = UiText.get($r('app.string.generated_missing')); }
        return;
      }
      const content = await fileIo.readText(version.Path);
      if (request === this.generation) { this.content = content; }
    } catch (_) {
      if (request === this.generation) { this.error = UiText.get($r('app.string.generated_read_failed')); }
    } finally {
      if (request === this.generation) { this.loading = false; }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text(UiText.get($r('app.string.generated_readonly'))).fontSize(13).fontColor(UI.muted).width('100%')
      if (this.loading) {
        LoadingProgress().width(36).height(36)
      } else if (this.error.length > 0) {
        Text(this.error).fontSize(15).fontColor(UI.error).width('100%')
        Button(UiText.get($r('app.string.action_retry'))).constraintSize({ minHeight: 48 }).backgroundColor(UI.soft).fontColor(UI.ink).onClick(() => { this.load(); })
      } else {
        Scroll() {
          Text(this.content).fontSize(14).fontFamily('HarmonyOS Sans Mono')
            .fontColor(UI.ink).copyOption(CopyOptions.None).width('100%')
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').padding(16).backgroundColor(UI.paper)
  }
}
