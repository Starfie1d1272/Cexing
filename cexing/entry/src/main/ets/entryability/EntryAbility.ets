import { UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppRuntime } from '../lib/AppRuntime';
import { Logger } from '../lib/Logger';
import { ConnectionEntry } from '../lib/ConnectionEntry';
import { ProfileImportInput } from '../lib/ProfileImportInput';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want): void {
    ConnectionEntry.bind(this.context);
    AppRuntime.initialize(this.context, () => ConnectionEntry.recovered(this.context));
    if (want.action === 'ohos.want.action.viewData' || want.action === 'ohos.want.action.sendData') {
      ProfileImportInput.receive(want);
    } else { ConnectionEntry.receive(want); }
  }

  onNewWant(want: Want): void {
    if (want.action === 'ohos.want.action.viewData' || want.action === 'ohos.want.action.sendData') {
      ProfileImportInput.receive(want);
    } else { ConnectionEntry.receive(want); }
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
    ConnectionEntry.destroyed(this.context);
    AppRuntime.abilityDestroyed(this.context);
  }
}
