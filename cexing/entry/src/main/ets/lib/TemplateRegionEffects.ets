/** Selection side effects for the existing profile transaction. This module
 * owns no files, version pointer, Controller client or publish operation. */
export interface RegionPreviousChoice { selector: string; name: string; observed?: string; }
export interface RegionChoiceState { sourceNames?: boolean; pending: string; previous?: RegionPreviousChoice; }
export interface RegionChoiceGroup { now: string; all: string[]; }
export interface RegionChoiceTransition {
  state: RegionChoiceState;
  // Only a newly committed removal/switch may observe the reload fallback.
  observeRemoved: string;
}
export interface RegionChoicePort {
  read: () => RegionChoiceState;
  write: (state: RegionChoiceState) => void;
  groups: () => Promise<Record<string, RegionChoiceGroup>>;
  // The owner checks active profile/version and holds its existing gate.
  current: () => boolean;
  select: (selector: string, name: string) => Promise<boolean>;
}
export type RegionChoiceResult = 'done' | 'pending' | 'manual' | 'stale';

function copy(state: RegionChoiceState): RegionChoiceState {
  return JSON.parse(JSON.stringify(state)) as RegionChoiceState;
}
function smart(selector: string): string { return `Cexing Smart ${selector}`; }

/** Call before publication, using enabled selectors from successful old/new
 * TemplatePlan (empty means disabled/original/AI). Persist returned state in
 * the SAME transaction as the successful version; discard it on failure.
 * A same-selector rebase must never requeue a user's completed choice. */
export function prepareRegionChoice(before: string, after: string, saved: RegionChoiceState,
  groups: Record<string, RegionChoiceGroup>): RegionChoiceTransition {
  const state = copy(saved);
  if (before !== '' && state.previous !== undefined && state.previous.selector.length === 0) {
    state.previous.selector = before;
  }
  if (before === after) { return { state: state, observeRemoved: '' }; }
  let observe = '';
  if (before !== '') {
    const group = groups[before];
    if (group !== undefined && group.now === smart(before)) {
      const previous = state.previous;
      if (previous === undefined || previous.selector !== before || previous.name.length === 0 ||
        !group.all.includes(previous.name)) { throw new Error('REGION_PREVIOUS_UNAVAILABLE'); }
      observe = before;
    } else if (group !== undefined && state.previous?.selector === before) {
      // A manual selection made while enabled belongs to the user.
      state.previous = undefined;
    } else if (state.previous?.selector === before) {
      observe = before;
    }
  }
  if (observe !== '' && state.previous !== undefined) {
    // An observation made before the removal belongs to the old runtime. It
    // cannot authorize overwriting the fallback of an unseen offline reload.
    state.previous.observed = undefined;
  }
  state.pending = after;
  return { state: state, observeRemoved: observe };
}

/** After successful commit, capture the reload fallback once. On reconnect
 * call resumeRegionChoice directly: never infer a new fallback there. */
export async function committedRegionChoice(transition: RegionChoiceTransition,
  activeSelector: string, port: RegionChoicePort): Promise<RegionChoiceResult> {
  if (!port.current()) { return 'stale'; }
  const state = copy(transition.state);
  if (transition.observeRemoved !== '' && state.previous?.selector === transition.observeRemoved) {
    const groups = await port.groups();
    if (!port.current()) { return 'stale'; }
    const group = groups[transition.observeRemoved];
    if (group !== undefined) { state.previous.observed = group.now; }
  }
  port.write(state);
  return await resumeRegionChoice(activeSelector, port);
}

/** Use the existing pending/previous files. A disappeared target stays pending;
 * a different observed choice yields to the user. Restore old group before a
 * requested new group, including after an offline switch to AI/original. */
export async function resumeRegionChoice(activeSelector: string,
  port: RegionChoicePort): Promise<RegionChoiceResult> {
  if (!port.current()) { return 'stale'; }
  let state = copy(port.read());
  if (state.previous === undefined && state.pending === '') { return 'done'; }
  let groups = await port.groups();
  if (!port.current()) { return 'stale'; }
  if (state.previous !== undefined && state.previous.selector !== activeSelector) {
    const previous = state.previous;
    const group = groups[previous.selector];
    if (group === undefined || !group.all.includes(previous.name)) { return 'pending'; }
    if (group.now !== previous.name) {
      if (group.now !== smart(previous.selector) &&
        (previous.observed === undefined || group.now !== previous.observed)) {
        // Offline reload without an observed fallback cannot prove ownership.
        if (previous.observed === undefined) { return 'pending'; }
        state.previous = undefined;
        // A later manual choice also cancels the queued switch.
        state.pending = ''; port.write(state); return 'manual';
      }
      const restored = await port.select(previous.selector, previous.name);
      if (!port.current()) { return 'stale'; }
      if (!restored) { return 'pending'; }
    }
    state.previous = undefined; port.write(state);
  }
  if (state.pending === '') { return 'done'; }
  if (activeSelector === '' || state.pending !== activeSelector) {
    state.pending = ''; port.write(state); return 'done';
  }
  groups = await port.groups();
  if (!port.current()) { return 'stale'; }
  const group = groups[activeSelector];
  const target = smart(activeSelector);
  if (group === undefined || !group.all.includes(target)) { return 'pending'; }
  if (group.now !== target) {
    if (group.now.length === 0 || !group.all.includes(group.now)) { return 'pending'; }
    if (state.previous?.selector === activeSelector && state.previous.observed !== undefined &&
      group.now !== state.previous.observed) {
      state.pending = ''; state.previous = undefined; port.write(state); return 'manual';
    }
    // Durable before selecting Smart; a disconnect can retry without losing it.
    if (state.previous?.selector !== activeSelector) {
      state.previous = { selector: activeSelector, name: group.now, observed: group.now };
    }
    port.write(state);
    const selected = await port.select(activeSelector, target);
    if (!port.current()) { return 'stale'; }
    if (!selected) { return 'pending'; }
  }
  state.pending = ''; port.write(state); return 'done';
}
