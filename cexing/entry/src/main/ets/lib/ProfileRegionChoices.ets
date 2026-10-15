/* Selection effects for the shared publisher; no separate lifecycle or publisher. */
import { common } from '@kit.AbilityKit';
import { EditIntent } from './ConfigEditor';
import { EffectiveVersions, EffectiveVersion, RegionPlan } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { CoreApi } from './CoreApi';
import { RegionChoiceState, RegionChoiceTransition, RegionChoicePort,
  prepareRegionChoice, committedRegionChoice, resumeRegionChoice } from './TemplateRegionEffects';

export namespace ProfileRegionChoices {
  export function selector(intent: EditIntent | null, legacy: RegionPlan | null): string {
    const template = intent?.disabled !== true ? intent?.template : undefined;
    if (template !== undefined) {
      return template.templateId === 'region' && template.region?.enable === true &&
        template.region.disabled !== true ? template.region.selector : '';
    }
    return legacy?.enable === true && legacy.disabled !== true ? legacy.selector : '';
  }

  export function read(context: common.Context, file: string, version: EffectiveVersion | undefined,
    before: string): RegionChoiceState {
    if (version !== undefined) {
      const runtime = ProfileStore.runtimeRegionChoice(context, file, version.ID);
      if (runtime !== null) { return runtime; }
      const durable = EffectiveVersions.regionChoice(context, version);
      if (durable !== null) { return durable; }
    }
    // Legacy files have no version binding. Only migrate when provenance lacks
    // a canonical choice; never reuse a stale runtime record for a new version.
    const previous = ProfileStore.previousRegionSelection(context, file);
    const observed = ProfileStore.previousRegionObservation(context, file);
    return { pending: ProfileStore.pendingRegionSelection(context, file),
      previous: previous !== '' && before !== '' ? { selector: before, name: previous,
        observed: observed !== '' ? observed : undefined } : undefined };
  }

  export async function prepare(context: common.Context, file: string, version: EffectiveVersion | undefined,
    after: string, live: boolean): Promise<RegionChoiceTransition> {
    const before = version !== undefined ? selector(EffectiveVersions.editIntent(context, version),
      EffectiveVersions.regionPlan(context, version)) : '';
    return prepareRegionChoice(before, after, read(context, file, version, before),
      live ? await CoreApi.getProxies() ?? {} : {});
  }

  function port(context: common.Context, file: string, version: EffectiveVersion,
    current: () => boolean, sameSession: () => Promise<boolean>): RegionChoicePort {
    return { read: () => read(context, file, version,
      selector(EffectiveVersions.editIntent(context, version), EffectiveVersions.regionPlan(context, version))),
      write: (state: RegionChoiceState): void => {
        if (!current()) { throw new Error('连接已变化，请重试'); }
        ProfileStore.saveRuntimeRegionChoice(context, file, version.ID, state);
      }, groups: async () => await CoreApi.getProxies() ?? {}, current: current,
      select: async (group: string, name: string): Promise<boolean> => {
        if (!current() || !(await sameSession()) || !current()) { return false; }
        const selected = await CoreApi.selectProxy(group, name);
        return current() && await sameSession() && selected;
      } };
  }

  export async function committed(context: common.Context, file: string, version: EffectiveVersion,
    transition: RegionChoiceTransition, after: string, current: () => boolean,
    sameSession: () => Promise<boolean>): Promise<void> {
    const result = await committedRegionChoice(transition, after, port(context, file, version, current, sameSession));
    if (result === 'pending') { throw new Error('配置已保存，地区选择待重连恢复'); }
  }

  export async function resume(context: common.Context, file: string, version: EffectiveVersion,
    current: () => boolean, sameSession: () => Promise<boolean>): Promise<boolean> {
    const active = selector(EffectiveVersions.editIntent(context, version), EffectiveVersions.regionPlan(context, version));
    const result = await resumeRegionChoice(active, port(context, file, version, current, sameSession));
    return result === 'done' || result === 'manual';
  }
}
