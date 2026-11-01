import { AppTrafficBytes, AppTrafficReason, AppTrafficRow, AppTrafficSummary } from './CoreApi';
import { TrafficPeriod, trafficPeriod, validCounter } from './TrafficLedger';

export const SOURCE_LIMIT: number = 2048;
export const SOURCE_JSON_LIMIT: number = 2 * 1024 * 1024;
export class SourceEntry {
  uid: number = -1;
  // Upload, download and connection count for proxy, direct and unclassified.
  counts: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0];
}
export class SourceBucket {
  key: string = '';
  partial: boolean = false;
  rows: SourceEntry[] = [];
}
export class SourceIdentity {
  uid: number = -1;
  number: number = 0;
  label: string = '';
  lastSeen: number = 0;
  recent: AppTrafficReason[] = [];
}
export class SourceCheckpoint {
  host: string = '';
  session: string = '';
  startedAt: number = 0;
  at: number = 0;
  day: string = '';
  month: string = '';
  zone: number = 0;
  partial: boolean = false;
  rows: SourceEntry[] = [];
}
export class SourceTrafficState {
  version: number = 1;
  startedAt: number = 0;
  nextNumber: number = 1;
  identities: SourceIdentity[] = [];
  all: SourceBucket = new SourceBucket();
  days: SourceBucket[] = [];
  months: SourceBucket[] = [];
  checkpoint: SourceCheckpoint = new SourceCheckpoint();
}
function counts(value: AppTrafficBytes): number[] { return [value.upload, value.download, value.connections]; }
function entries(summary: AppTrafficSummary): SourceEntry[] {
  return summary.apps.map((row: AppTrafficRow): SourceEntry => ({ uid: row.uid,
    counts: counts(row.routes.proxy).concat(counts(row.routes.direct), counts(row.routes.unclassified)) }));
}
function validEntry(row: SourceEntry): boolean {
  return row !== null && typeof row === 'object' && Number.isInteger(row.uid) && row.uid >= -1 && row.uid <= 2147483647 &&
    Array.isArray(row.counts) && row.counts.length === 9 && row.counts.every((value: number) => validCounter(value));
}
function validEntries(rows: SourceEntry[], limit: number): boolean {
  return Array.isArray(rows) && rows.length <= limit && rows.every((row: SourceEntry, index: number) =>
    validEntry(row) && rows.findIndex((other: SourceEntry) => other.uid === row.uid) === index);
}
function sum(rows: SourceEntry[], index: number): number { return rows.reduce((total: number, row: SourceEntry) => total + row.counts[index], 0); }
function bucket(buckets: SourceBucket[], key: string): SourceBucket {
  let result = buckets.find((item: SourceBucket) => item.key === key);
  if (result === undefined) { result = new SourceBucket(); result.key = key; buckets.push(result); }
  return result;
}
function trim(buckets: SourceBucket[], limit: number, keep: string): void {
  while (buckets.length > limit) { buckets.splice(buckets.findIndex((item: SourceBucket) => item.key !== keep), 1); }
}
function difference(next: SourceEntry[], previous: SourceEntry[]): SourceEntry[] {
  const result = next.map((row: SourceEntry): SourceEntry => ({ uid: row.uid, counts: row.counts.slice() }));
  previous.forEach((row: SourceEntry) => {
    let target = result.find((item: SourceEntry) => item.uid === row.uid);
    if (target === undefined) { target = new SourceEntry(); target.uid = row.uid; result.push(target); }
    target.counts = target.counts.map((value: number, index: number) => value - row.counts[index]);
  });
  return result;
}
function canApply(target: SourceBucket, delta: SourceEntry[]): boolean {
  return delta.every((row: SourceEntry) => {
    const prior = target.rows.find((item: SourceEntry) => item.uid === row.uid);
    return row.counts.every((value: number, index: number) => validCounter(value + (prior?.counts[index] ?? 0)));
  }) && [0, 1, 2, 3, 4, 5, 6, 7, 8].every((index: number) => validCounter(sum(target.rows, index) + sum(delta, index)));
}
function apply(target: SourceBucket, delta: SourceEntry[]): void {
  delta.forEach((row: SourceEntry) => {
    let prior = target.rows.find((item: SourceEntry) => item.uid === row.uid);
    if (prior === undefined) { prior = new SourceEntry(); prior.uid = row.uid; target.rows.push(prior); }
    prior.counts = prior.counts.map((value: number, index: number) => value + row.counts[index]);
  });
}
function validRecent(recent: AppTrafficReason[]): boolean {
  return Array.isArray(recent) && recent.length <= 4 && recent.every((reason: AppTrafficReason) => reason !== null &&
    typeof reason === 'object' && validCounter(reason.at) && typeof reason.target === 'string' && reason.target.length <= 1024 &&
    typeof reason.rule === 'string' && reason.rule.length <= 256 && typeof reason.route === 'string' && reason.route.length <= 32 &&
    Array.isArray(reason.policy) && reason.policy.length <= 8 && reason.policy.every((value: string) => typeof value === 'string' && value.length <= 256));
}
function allocate(target: SourceBucket, delta: SourceEntry[], reliable: boolean): void {
  if (reliable && canApply(target, delta)) { apply(target, delta); }
  else if (delta.some((row: SourceEntry) => row.counts.some((value: number) => value !== 0))) { target.partial = true; }
}
function updateSourceTraffic(state: SourceTrafficState, host: string, summary: AppTrafficSummary, at: number,
  period: TrafficPeriod = trafficPeriod(at)): boolean {
  const next = entries(summary);
  if (host.length === 0 || host.length > 128 || !/^[0-9a-f]{32}$/.test(summary.session) ||
    !validCounter(summary.startedAt) || summary.startedAt === 0 || !validCounter(at) || at === 0 || !validEntries(next, 129) ||
    !summary.apps.every((row: AppTrafficRow) => validCounter(row.lastSeen) && validRecent(row.recent))) { return false; }
  const total = counts(summary.totals.proxy).concat(counts(summary.totals.direct), counts(summary.totals.unclassified));
  if (!total.every((value: number, index: number) => validCounter(value) && value === sum(next, index))) { return false; }
  const previous = state.checkpoint;
  const same = previous.session === summary.session && previous.startedAt === summary.startedAt;
  // Controller identity pins the same cumulative session even if the host binding was recovered.
  if (same && total.some((value: number, index: number) => value < sum(previous.rows, index))) {
    markSourceGap(state, at); return false;
  }
  const added = next.filter((row: SourceEntry) => !state.identities.some((item: SourceIdentity) => item.uid === row.uid));
  if (state.identities.filter((item: SourceIdentity) => item.uid >= 0).length + added.filter((item: SourceEntry) => item.uid >= 0).length > SOURCE_LIMIT) { markSourceGap(state, at); return false; }
  const delta = difference(next, same ? previous.rows : []);
  if (!canApply(state.all, delta)) { markSourceGap(state, at); return false; }
  const day = bucket(state.days, period.day); const month = bucket(state.months, period.month);
  const start = trafficPeriod(summary.startedAt);
  const clockOK = same ? at >= previous.at && period.zone === previous.zone : at >= summary.startedAt;
  const negative = delta.some((row: SourceEntry) => row.counts.some((value: number) => value < 0));
  const dayOK = clockOK && (same ? period.day === previous.day : period.day === start.day) && (!negative || period.day === start.day);
  const monthOK = clockOK && (same ? period.month === previous.month : period.month === start.month) && (!negative || period.month === start.month);
  if (!same && previous.session.length > 0) {
    state.all.partial = true;
    bucket(state.days, previous.day).partial = true; bucket(state.months, previous.month).partial = true;
  }
  apply(state.all, delta);
  allocate(day, delta, dayOK); allocate(month, delta, monthOK);
  if (same && (!dayOK || !clockOK)) { bucket(state.days, previous.day).partial = true; day.partial = true; }
  if (same && (!monthOK || !clockOK)) { bucket(state.months, previous.month).partial = true; month.partial = true; }
  if (summary.partial) { state.all.partial = true; day.partial = true; month.partial = true; }
  if (state.startedAt === 0) { state.startedAt = at; day.partial = true; month.partial = true; }
  next.forEach((entry: SourceEntry) => {
    let identity = state.identities.find((item: SourceIdentity) => item.uid === entry.uid);
    if (identity === undefined) {
      identity = new SourceIdentity(); identity.uid = entry.uid;
      if (entry.uid >= 0) { identity.number = state.nextNumber++; }
      state.identities.push(identity);
    }
    const row = summary.apps.find((item: AppTrafficRow) => item.uid === entry.uid);
    if (row !== undefined) {
      identity.lastSeen = Math.max(identity.lastSeen, row.lastSeen);
      const recent = identity.recent.concat(row.recent);
      identity.recent = recent.filter((reason: AppTrafficReason, index: number) =>
        recent.findIndex((other: AppTrafficReason) => other.at === reason.at && other.target === reason.target &&
          other.route === reason.route && other.rule === reason.rule && JSON.stringify(other.policy) === JSON.stringify(reason.policy)) === index)
        .sort((a: AppTrafficReason, b: AppTrafficReason) => b.at - a.at).slice(0, 4)
        .map((reason: AppTrafficReason): AppTrafficReason => ({ at: reason.at, target: reason.target,
          route: reason.route, rule: reason.rule, policy: reason.policy.slice() }));
    }
  });
  state.checkpoint = { host: host, session: summary.session, startedAt: summary.startedAt, at: at,
    day: period.day, month: period.month, zone: period.zone, partial: summary.partial, rows: next };
  trim(state.days, 35, period.day); trim(state.months, 14, period.month);
  return true;
}
export function recordSourceTraffic(state: SourceTrafficState, host: string, summary: AppTrafficSummary, at: number,
  period: TrafficPeriod = trafficPeriod(at)): boolean {
  // Keep the checkpoint and accumulated rows atomic, including at the storage capacity boundary.
  const next = JSON.parse(JSON.stringify(state)) as SourceTrafficState;
  const accepted = updateSourceTraffic(next, host, summary, at, period);
  if (JSON.stringify(next).length > SOURCE_JSON_LIMIT) { markSourceGap(state, at); return false; }
  state.startedAt = next.startedAt; state.nextNumber = next.nextNumber; state.identities = next.identities;
  state.all = next.all; state.days = next.days; state.months = next.months; state.checkpoint = next.checkpoint;
  return accepted;
}
export function markSourceGap(state: SourceTrafficState, at: number): void {
  if (state.startedAt === 0) { return; }
  state.all.partial = true; state.checkpoint.partial = true;
  state.days.forEach((item: SourceBucket) => { if (item.key === state.checkpoint.day || item.key === trafficPeriod(at).day) { item.partial = true; } });
  state.months.forEach((item: SourceBucket) => { if (item.key === state.checkpoint.month || item.key === trafficPeriod(at).month) { item.partial = true; } });
}
export function sourceRows(state: SourceTrafficState, rows: SourceEntry[]): AppTrafficRow[] {
  return rows.map((row: SourceEntry): AppTrafficRow => {
    const identity = state.identities.find((item: SourceIdentity) => item.uid === row.uid);
    return { uid: row.uid, identityStatus: row.uid >= 0 ? 'uid' : 'unknown', bundleName: '', bundleVerified: false,
      routeTarget: '', lastSeen: identity?.lastSeen ?? 0, recent: identity?.recent ?? [], routes: {
        proxy: { upload: row.counts[0], download: row.counts[1], connections: row.counts[2], active: 0 },
        direct: { upload: row.counts[3], download: row.counts[4], connections: row.counts[5], active: 0 },
        unclassified: { upload: row.counts[6], download: row.counts[7], connections: row.counts[8], active: 0 } } };
  });
}
function validDay(key: string): boolean {
  if (!/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(key)) { return false; }
  const parts = key.split('-'); return Number(parts[2]) <= new Date(Number(parts[0]), Number(parts[1]), 0).getDate();
}
function validBucket(value: SourceBucket): boolean {
  return value !== null && typeof value === 'object' && typeof value.key === 'string' && typeof value.partial === 'boolean' &&
    validEntries(value.rows, SOURCE_LIMIT + 1) && [0, 1, 2, 3, 4, 5, 6, 7, 8].every((index: number) => validCounter(sum(value.rows, index)));
}
export function restoreSourceTraffic(text: string): SourceTrafficState {
  if (text.length === 0) { return new SourceTrafficState(); }
  if (text.length > SOURCE_JSON_LIMIT) { throw new Error('source ledger too large'); }
  const state = JSON.parse(text) as SourceTrafficState;
  if (state === null || typeof state !== 'object' || state.version !== 1 || !validCounter(state.startedAt) ||
    !validCounter(state.nextNumber) || state.nextNumber < 1 || state.nextNumber > SOURCE_LIMIT + 1 ||
    !Array.isArray(state.identities) || state.identities.length > SOURCE_LIMIT + 1 || !validBucket(state.all) || state.all.key !== '' ||
    !Array.isArray(state.days) || state.days.length > 35 || !Array.isArray(state.months) || state.months.length > 14) { throw new Error('invalid source ledger'); }
  if (!state.identities.every((item: SourceIdentity, index: number) => item !== null && typeof item === 'object' &&
    Number.isInteger(item.uid) && item.uid >= -1 && item.uid <= 2147483647 && validCounter(item.number) &&
    (item.uid === -1 ? item.number === 0 && item.label === '' : item.number > 0 && item.number < state.nextNumber) &&
    typeof item.label === 'string' && item.label.length <= 40 && validCounter(item.lastSeen) && validRecent(item.recent) &&
    state.identities.findIndex((other: SourceIdentity) => other.uid === item.uid) === index &&
    state.identities.findIndex((other: SourceIdentity) => other.number === item.number) === index)) { throw new Error('invalid source identities'); }
  const periods = state.days.concat(state.months);
  if (!state.days.every((item: SourceBucket, index: number) => validBucket(item) && validDay(item.key) && state.days.findIndex((other: SourceBucket) => other.key === item.key) === index) ||
    !state.months.every((item: SourceBucket, index: number) => validBucket(item) && /^\d{4}-(0[1-9]|1[0-2])$/.test(item.key) && state.months.findIndex((other: SourceBucket) => other.key === item.key) === index) ||
    !periods.concat([state.all]).every((item: SourceBucket) => item.rows.every((row: SourceEntry) => state.identities.some((identity: SourceIdentity) => identity.uid === row.uid)))) { throw new Error('invalid source periods'); }
  const cp = state.checkpoint;
  if (cp === null || typeof cp !== 'object' || typeof cp.host !== 'string' || cp.host.length > 128 || typeof cp.session !== 'string' ||
    !validCounter(cp.startedAt) || !validCounter(cp.at) || typeof cp.partial !== 'boolean' || !validEntries(cp.rows, 129) ||
    !Number.isInteger(cp.zone) || Math.abs(cp.zone) > 1440 || typeof cp.day !== 'string' || typeof cp.month !== 'string') { throw new Error('invalid source checkpoint'); }
  if (state.startedAt === 0) {
    if (cp.session !== '' || cp.host !== '' || cp.rows.length > 0 || state.identities.length > 0 || state.all.rows.length > 0 || periods.length > 0) { throw new Error('invalid empty source state'); }
  } else if (!/^[0-9a-f]{32}$/.test(cp.session) || cp.host.length === 0 || cp.startedAt === 0 || cp.at === 0 ||
    !validDay(cp.day) || cp.month !== cp.day.slice(0, 7) || !state.days.some((item: SourceBucket) => item.key === cp.day) ||
    !state.months.some((item: SourceBucket) => item.key === cp.month) || !cp.rows.every((row: SourceEntry) => {
      const total = state.all.rows.find((item: SourceEntry) => item.uid === row.uid);
      return total !== undefined && row.counts.every((value: number, index: number) => value <= total.counts[index]);
    })) { throw new Error('inconsistent source checkpoint'); }
  return state;
}
