// Cumulative counters only. Rates are never integrated into the durable ledger.
export class TrafficBucket {
  key: string = '';
  up: number = 0;
  down: number = 0;
  partial: boolean = false;
}
export class TrafficCheckpoint {
  session: string = '';
  up: number = 0;
  down: number = 0;
  at: number = 0;
  day: string = '';
  month: string = '';
  zone: number = 0;
}
export class TrafficState {
  version: number = 1;
  startedAt: number = 0;
  checkpoint: TrafficCheckpoint = new TrafficCheckpoint();
  current: TrafficBucket = new TrafficBucket();
  days: TrafficBucket[] = [];
  months: TrafficBucket[] = [];
}
export class TrafficPeriod {
  day: string = '';
  month: string = '';
  zone: number = 0;
}
export function trafficPeriod(at: number): TrafficPeriod {
  const date = new Date(at);
  const month = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
  return { day: `${month}-${String(date.getDate()).padStart(2, '0')}`, month: month, zone: date.getTimezoneOffset() };
}
export function trafficBucket(buckets: TrafficBucket[], key: string): TrafficBucket {
  let bucket = buckets.find((item: TrafficBucket) => item.key === key);
  if (bucket === undefined) {
    bucket = new TrafficBucket(); bucket.key = key;
    buckets.push(bucket);
  }
  return bucket;
}
function trim(buckets: TrafficBucket[], limit: number): void {
  // Retain the most recently visited periods, including after a clock rollback.
  while (buckets.length > limit) { buckets.shift(); }
}
export function validCounter(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}
export function recordTraffic(state: TrafficState, session: string, up: number, down: number,
  at: number, period: TrafficPeriod): boolean {
  if (session.length === 0 || !validCounter(up) || !validCounter(down) || !Number.isFinite(at) || at <= 0) { return false; }
  const day = trafficBucket(state.days, period.day);
  const month = trafficBucket(state.months, period.month);
  const previous = state.checkpoint;
  if (state.startedAt === 0) {
    state.startedAt = at;
    day.partial = true; month.partial = true;
  }
  if (previous.session !== session) {
    // A new VPN session can share the old Go process's counters. Never take
    // its initial total as this session's bytes, nor join different identities.
    if (previous.session.length > 0) {
      trafficBucket(state.days, previous.day).partial = true;
      trafficBucket(state.months, previous.month).partial = true;
    }
    state.current = new TrafficBucket(); state.current.key = session;
    state.current.partial = true;
    day.partial = true; month.partial = true;
  } else if (up < previous.up || down < previous.down) {
    state.current.partial = true; day.partial = true; month.partial = true;
    trafficBucket(state.days, previous.day).partial = true;
    trafficBucket(state.months, previous.month).partial = true;
  } else {
    const deltaUp = up - previous.up;
    const deltaDown = down - previous.down;
    state.current.up += deltaUp; state.current.down += deltaDown;
    const clockOK = at > previous.at && period.zone === previous.zone;
    if (clockOK && period.day === previous.day) { day.up += deltaUp; day.down += deltaDown; }
    else if (deltaUp + deltaDown > 0 || !clockOK) {
      day.partial = true; trafficBucket(state.days, previous.day).partial = true;
    }
    if (clockOK && period.month === previous.month) { month.up += deltaUp; month.down += deltaDown; }
    else if (deltaUp + deltaDown > 0 || !clockOK) {
      month.partial = true; trafficBucket(state.months, previous.month).partial = true;
    }
  }
  state.checkpoint = { session: session, up: up, down: down, at: at,
    day: period.day, month: period.month, zone: period.zone };
  trim(state.days, 35); trim(state.months, 14);
  return true;
}
export function markTrafficGap(state: TrafficState, at: number): void {
  if (state.checkpoint.session.length === 0) { return; }
  const period = trafficPeriod(at);
  state.current.partial = true;
  trafficBucket(state.days, period.day).partial = true;
  trafficBucket(state.months, period.month).partial = true;
  trafficBucket(state.days, state.checkpoint.day).partial = true;
  trafficBucket(state.months, state.checkpoint.month).partial = true;
  trim(state.days, 35); trim(state.months, 14);
}
function validBucket(bucket: TrafficBucket): boolean {
  return bucket !== null && typeof bucket === 'object' && typeof bucket.key === 'string' && bucket.key.length <= 100 &&
    validCounter(bucket.up) && validCounter(bucket.down) && typeof bucket.partial === 'boolean';
}
function validMonth(key: string): boolean {
  return /^\d{4}-(0[1-9]|1[0-2])$/.test(key);
}
function validDay(key: string): boolean {
  if (!/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(key)) { return false; }
  const parts = key.split('-');
  return Number(parts[2]) <= new Date(Number(parts[0]), Number(parts[1]), 0).getDate();
}
function uniqueBuckets(buckets: TrafficBucket[]): boolean {
  return buckets.every((bucket: TrafficBucket, index: number) =>
    buckets.findIndex((other: TrafficBucket) => other.key === bucket.key) === index);
}
export function restoreTraffic(text: string): TrafficState {
  if (text.length === 0) { return new TrafficState(); }
  if (text.length > 32000) { throw new Error('traffic ledger too large'); }
  const state = JSON.parse(text) as TrafficState;
  if (state === null || state.version !== 1 || !validCounter(state.startedAt) || !validBucket(state.current) ||
    !Array.isArray(state.days) || !Array.isArray(state.months) || state.days.length > 35 || state.months.length > 14 ||
    !state.days.every((b: TrafficBucket) => validBucket(b) && validDay(b.key)) ||
    !state.months.every((b: TrafficBucket) => validBucket(b) && validMonth(b.key)) ||
    !uniqueBuckets(state.days) || !uniqueBuckets(state.months)) { throw new Error('invalid traffic ledger'); }
  const p = state.checkpoint;
  if (p === null || typeof p !== 'object' || typeof p.session !== 'string' || p.session.length > 100 ||
    !validCounter(p.up) || !validCounter(p.down) || !validCounter(p.at) || typeof p.day !== 'string' ||
    typeof p.month !== 'string' || !Number.isInteger(p.zone) || Math.abs(p.zone) > 1440 ||
    (p.session.length > 0 && (!validDay(p.day) || !validMonth(p.month) || p.day.slice(0, 7) !== p.month ||
      p.session !== state.current.key || p.at <= 0 || state.startedAt <= 0)) ||
    (p.session.length === 0 && (state.startedAt !== 0 || state.current.key.length > 0))) { throw new Error('invalid traffic checkpoint'); }
  return state;
}
