import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppRuntime } from '../lib/AppRuntime';
import { Logger } from '../lib/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    AppRuntime.initialize(this.context);
  }

  onForeground(): void {
    AppRuntime.foreground();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error('entry', 'loadContent failed: ' + JSON.stringify(err));
      }
    });
  }

  onDestroy(): void {
    AppRuntime.abilityDestroyed(this.context);
  }
}
