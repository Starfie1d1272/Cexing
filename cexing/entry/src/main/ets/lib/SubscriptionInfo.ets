import { SubInfo, SubValidity } from './ProfileStore';
import { UiText } from './UiText';

export interface SubscriptionView {
  summary: string;
  usage: string;
  remaining: string;
  expiry: string;
  updated: string;
}

/** Pure response/state helpers: bytes, Unix seconds and an explicit observation clock. */
export namespace SubscriptionInfo {
  const FIELDS: string[] = ['upload', 'download', 'total', 'expire'];
  const MAX_DATE_SECONDS: number = 8640000000000;

  function valid(value: number, field: string): boolean {
    return Number.isSafeInteger(value) && value >= 0 &&
      (field !== 'expire' || value <= MAX_DATE_SECONDS);
  }

  export function parse(headers: Record<string, Object>, fetchedAt: number): SubInfo {
    const values: Record<string, number> = {};
    const seen: Record<string, boolean> = {};
    const rejected: Record<string, boolean> = {};
    const records: string[] = [];
    let malformed = false;
    const source: Record<string, Object> = headers ?? {};
    for (const key of Object.keys(source)) {
      if (key.toLowerCase() !== 'subscription-userinfo') { continue; }
      const raw = source[key];
      if (typeof raw === 'string') { records.push(raw); } else { malformed = true; }
    }
    for (const record of records) {
      for (const part of record.split(';')) {
        const eq = part.indexOf('=');
        const field = (eq < 0 ? part : part.substring(0, eq)).trim().toLowerCase();
        if (!FIELDS.includes(field)) { continue; }
        const raw = eq < 0 ? '' : part.substring(eq + 1).trim();
        // Whole decimal byte/second counts only: no empty, exponent, Infinity or precision loss.
        const number = /^\d+$/.test(raw) ? Number(raw) : -1;
        if (!valid(number, field) || (seen[field] && values[field] !== number)) { rejected[field] = true; }
        values[field] = number; seen[field] = true;
      }
    }
    const flags: SubValidity = {
      upload: !malformed && seen['upload'] === true && !rejected['upload'],
      download: !malformed && seen['download'] === true && !rejected['download'],
      total: !malformed && seen['total'] === true && !rejected['total'],
      expire: !malformed && seen['expire'] === true && !rejected['expire'],
      header: 'missing', fetchedAt: 0
    };
    const any = flags.upload || flags.download || flags.total || flags.expire;
    flags.header = records.length === 0 && !malformed ? 'missing' : any ? 'present' : 'invalid';
    flags.fetchedAt = any && valid(fetchedAt, 'expire') ? fetchedAt : 0;
    return { upload: flags.upload ? values['upload'] : 0, download: flags.download ? values['download'] : 0,
      total: flags.total ? values['total'] : 0, expire: flags.expire ? values['expire'] : 0, validity: flags };
  }

  /** Legacy zero has no provenance. Positive finite counts remain usable without inventing freshness. */
  export function known(sub: SubInfo | undefined, field: string): boolean {
    if (sub === undefined) { return false; }
    let value = 0;
    let flag = false;
    switch (field) {
      case 'upload': value = sub.upload; flag = sub.validity?.upload === true; break;
      case 'download': value = sub.download; flag = sub.validity?.download === true; break;
      case 'total': value = sub.total; flag = sub.validity?.total === true; break;
      case 'expire': value = sub.expire; flag = sub.validity?.expire === true; break;
      default: return false;
    }
    return valid(value, field) && (sub.validity === undefined ? value > 0 :
      sub.validity?.header === 'present' && flag);
  }

  export function bytes(value: number): string {
    if (value === 0) { return '0 MiB'; }
    if (value < 1024) { return `${value} B`; }
    if (value < 1024 * 1024) { return `${(value / 1024).toFixed(1)} KiB`; }
    if (value < 1024 * 1024 * 1024) { return `${(value / 1024 / 1024).toFixed(1)} MiB`; }
    return `${(value / 1024 / 1024 / 1024).toFixed(1)} GiB`;
  }

  export function view(sub: SubInfo | undefined, remote: boolean, now: number): SubscriptionView {
    const missing = UiText.get($r('app.string.subscription_not_provided'));
    if (!remote) { return { summary: '', usage: '', remaining: '', expiry: '', updated: '' }; }
    const totalKnown = known(sub, 'total');
    const usageKnown = known(sub, 'upload') && known(sub, 'download');
    const total = sub?.total ?? 0;
    const upload = sub?.upload ?? 0;
    const download = sub?.download ?? 0;
    const used = usageKnown && Number.isSafeInteger(upload + download) ? bytes(upload + download) : missing;
    let remaining = missing;
    let quota = totalKnown ? UiText.get($r('app.string.subscription_total_only'), bytes(total)) :
      UiText.get($r('app.string.subscription_remaining_missing'));
    if (totalKnown && usageKnown) {
      // Avoid overflowing the sum of two individually safe integer counters.
      const over = upload > total || download > total - upload;
      const left = upload >= total || download >= total - upload ? 0 : total - upload - download;
      remaining = bytes(left);
      quota = over ? UiText.get($r('app.string.subscription_over_quota')) : left === 0 ?
        UiText.get($r('app.string.subscription_exhausted')) : UiText.get($r('app.string.subscription_remaining'), remaining);
    }
    let expiryStatus = UiText.get($r('app.string.subscription_expiry_missing'));
    let expiry = missing;
    if (known(sub, 'expire') && (sub?.expire ?? 0) > 0) {
      const stamp = sub?.expire ?? 0;
      const date = new Date(stamp * 1000).toLocaleString();
      const expired = stamp <= now;
      const days = Math.ceil((stamp - now) / 86400);
      expiryStatus = expired ? UiText.get($r('app.string.subscription_expired')) : days <= 7 ?
        UiText.get($r('app.string.subscription_expires_soon'), days) :
        UiText.get($r('app.string.subscription_expires_date'), new Date(stamp * 1000).toLocaleDateString());
      expiry = expired ? UiText.get($r('app.string.subscription_expired_date'), date) : date;
    }
    const stamp = sub?.validity?.header === 'present' ? sub.validity.fetchedAt : 0;
    const updated = stamp > 0 && valid(stamp, 'expire') ? new Date(stamp * 1000).toLocaleString() : missing;
    return {
      summary: `${quota} · ${expiryStatus}`,
      usage: UiText.get($r('app.string.subscription_usage'), used, totalKnown ? bytes(total) : missing),
      remaining: UiText.get($r('app.string.subscription_remaining'), remaining),
      expiry: UiText.get($r('app.string.subscription_expiry'), expiry),
      updated: UiText.get($r('app.string.subscription_updated'), updated)
    };
  }
}
