import { application } from '@kit.AbilityKit';

// String-only API boundaries use the same platform resources as visible widgets.
export namespace UiText {
  export function get(resource: Resource, ...args: (string | number)[]): string {
    return application.getApplicationContext().resourceManager.getStringSync(resource.id, ...args);
  }
}
