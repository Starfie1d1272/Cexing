/* Selection effects for the shared publisher; no separate lifecycle or publisher. */
import { common } from '@kit.AbilityKit';
import { ConfigEditor, EditIntent } from './ConfigEditor';
import { EffectiveVersions, EffectiveVersion, RegionPlan } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { CoreApi } from './CoreApi';
import { RegionChoiceState, RegionChoiceTransition, RegionChoicePort, RegionChoiceGroup,
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

  // Stored choices keep their source identity. Resolve only the live API names
  // through the existing compiler projection of the immutable published version.
  async function aliases(context: common.Context, version: EffectiveVersion | undefined): Promise<Record<string, string>> {
    const names: Record<string, string> = {};
    if (version === undefined) { return names; }
    const intent = EffectiveVersions.editIntent(context, version);
    if (intent === null || intent.disabled === true || !intent.operations.some(op =>
      (op.section === 'proxy-groups' || op.section === 'proxies') && op.kind === 'rename')) { return names; }
    const expected = EffectiveVersions.read(context)?.Current?.ID ?? '';
    const view = await ConfigEditor.list(context, EffectiveVersions.original(context, version),
      EffectiveVersions.overlay(context, version), expected, EffectiveVersions.globalMerge(context, version),
      intent, EffectiveVersions.regionPlan(context, version) ?? undefined);
    if ((EffectiveVersions.read(context)?.Current?.ID ?? '') !== expected) { throw new Error('配置已变化，请重试'); }
    const groups = view.sections.filter(section => section.section === 'proxy-groups' || section.section === 'proxies').flatMap(section => section.items);
    groups.forEach(item => {
      if (item.sourceName !== undefined && item.name !== undefined) { names[item.sourceName] = item.name; }
    });
    const baseline = intent.template?.baseline?.entries ?? [];
    const mine = intent.template?.mine?.entries ?? [];
    baseline.forEach(entry => {
      if (entry.section !== 'proxy-groups') { return; }
      const before = (entry.value as Record<string, Object>)['name'];
      const next = mine.find(item => item.id === entry.id && item.section === 'proxy-groups');
      const after = next !== undefined ? (next.value as Record<string, Object>)['name'] : undefined;
      if (typeof before === 'string' && typeof after === 'string') { names[before] = after; }
    });
    return names;
  }

  function logicalGroups(groups: Record<string, RegionChoiceGroup>, names: Record<string, string>): Record<string, RegionChoiceGroup> {
    const logical: Record<string, string> = {};
    for (const source of Object.keys(names)) { logical[names[source]] = source; }
    if (Object.keys(names).some(source => names[source] !== source &&
      groups[source] !== undefined && logical[source] === undefined)) { throw new Error('REGION_PREVIOUS_UNAVAILABLE'); }
    const result: Record<string, RegionChoiceGroup> = {};
    for (const name of Object.keys(groups)) {
      const group = groups[name];
      result[logical[name] ?? name] = { now: logical[group.now] ?? group.now,
        all: group.all?.map(member => logical[member] ?? member) ?? [] };
    }
    return result;
  }

  function logicalState(state: RegionChoiceState, names: Record<string, string>): RegionChoiceState {
    const result = JSON.parse(JSON.stringify(state)) as RegionChoiceState;
    if (result.sourceNames !== true && result.previous !== undefined) {
      const sources = Object.keys(names);
      const sourceName = (name: string): string => {
        const source = sources.find(item => names[item] === name);
        if (source !== undefined && source !== name && names[name] !== undefined) {
          throw new Error('REGION_PREVIOUS_UNAVAILABLE');
        }
        return source ?? name;
      };
      result.previous.name = sourceName(result.previous.name);
      if (result.previous.observed !== undefined) { result.previous.observed = sourceName(result.previous.observed); }
    }
    result.sourceNames = true;
    return result;
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
    try {
      const names = await aliases(context, version);
      const observing = live && ProfileStore.getActiveFile(context) === file;
      const groups = observing ? await CoreApi.getProxies() ?? {} : {};
      const saved = read(context, file, version, before);
      try {
        return prepareRegionChoice(before, after, logicalState(saved, names), logicalGroups(groups, names));
      } catch (error) {
        const group = groups[names[before] ?? before];
        const smart = names[`Cexing Smart ${before}`] ?? `Cexing Smart ${before}`;
        if ((error as Error).message !== 'REGION_PREVIOUS_UNAVAILABLE' || before === after ||
          group === undefined || group.now === smart || !group.all.includes(group.now)) { throw error as Error; }
        // The current API value is known to be a runtime name, unlike the old
        // record. Carry its source identity across the upcoming reload.
        const source = Object.keys(names).find(name => names[name] === group.now);
        if (source === undefined && names[group.now] !== undefined && names[group.now] !== group.now) {
          throw error as Error;
        }
        return { state: { pending: after, sourceNames: true,
          previous: { selector: before, name: source ?? group.now } }, observeRemoved: before };
      }
    } catch (error) {
      if ((error as Error).message === 'REGION_PREVIOUS_UNAVAILABLE') {
        throw new Error('请先在代理面板选择可用节点，再关闭或切换地区策略');
      }
      throw error as Error;
    }
  }

  function port(context: common.Context, file: string, version: EffectiveVersion,
    current: () => boolean, sameSession: () => Promise<boolean>, names: Record<string, string>): RegionChoicePort {
    return { read: () => logicalState(read(context, file, version,
      selector(EffectiveVersions.editIntent(context, version), EffectiveVersions.regionPlan(context, version))), names),
      write: (state: RegionChoiceState): void => {
        if (!current()) { throw new Error('连接已变化，请重试'); }
        ProfileStore.saveRuntimeRegionChoice(context, file, version.ID, state);
      }, groups: async () => logicalGroups(await CoreApi.getProxies() ?? {}, names), current: current,
      select: async (group: string, name: string): Promise<boolean> => {
        if (!current() || !(await sameSession()) || !current()) { return false; }
        const mapped = names;
        if (!current() || !(await sameSession()) || !current()) { return false; }
        const selected = await CoreApi.selectProxy(mapped[group] ?? group, mapped[name] ?? name);
        return current() && await sameSession() && selected;
      } };
  }

  export async function committed(context: common.Context, file: string, version: EffectiveVersion,
    transition: RegionChoiceTransition, after: string, current: () => boolean,
    sameSession: () => Promise<boolean>): Promise<void> {
    const result = await committedRegionChoice(transition, after, port(context, file, version, current, sameSession, await aliases(context, version)));
    if (result === 'pending') { throw new Error('配置已保存，地区选择待重连恢复'); }
  }

  export async function resume(context: common.Context, file: string, version: EffectiveVersion,
    current: () => boolean, sameSession: () => Promise<boolean>): Promise<boolean> {
    const active = selector(EffectiveVersions.editIntent(context, version), EffectiveVersions.regionPlan(context, version));
    const result = await resumeRegionChoice(active, port(context, file, version, current, sameSession, await aliases(context, version)));
    return result === 'done' || result === 'manual';
  }
}
