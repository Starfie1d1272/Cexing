import { UiText } from './UiText';
import { TemplateConflict, TemplateConflictDetail, TemplateUpdateRequest, TemplateSnapshot } from './TemplateUpdates';

const sections: Record<string, Resource> = { 'rules': $r('app.string.conflict_text_0'), 'proxy-groups': $r('app.string.conflict_text_1'),
  'proxies': $r('app.string.conflict_text_2'), 'proxy-providers': $r('app.string.conflict_text_3'), 'rule-providers': $r('app.string.conflict_text_4'), 'dns': $r('app.string.conflict_dns'), 'hosts': $r('app.string.conflict_text_5') };
const fields: Record<string, Resource> = { 'name': $r('app.string.conflict_text_6'), 'type': $r('app.string.conflict_text_7'), 'proxies': $r('app.string.conflict_text_8'), 'use': $r('app.string.conflict_text_9'),
  'interval': $r('app.string.conflict_text_10'), 'tolerance': $r('app.string.conflict_text_11'), 'strategy': $r('app.string.conflict_text_12'), 'udp': $r('app.string.conflict_udp'), 'port': $r('app.string.conflict_text_13'),
  'server': $r('app.string.conflict_text_14'), 'url': $r('app.string.conflict_text_15'), 'password': $r('app.string.conflict_text_16'), 'uuid': $r('app.string.conflict_text_17'), 'headers': $r('app.string.conflict_text_18'), 'token': $r('app.string.conflict_text_19') };

function label(value: string): string {
  // Names are user-facing identities. Never treat a URL, credential-shaped
  // string or control characters as a display name or a rule operand.
  if (value.length > 80 || /[\u0000-\u001f\u007f]|:\/\/|@|password|token|secret|authorization/i.test(value)) { return ''; }
  return value;
}
function rule(value: string): string {
  const parts = value.split(',');
  if (parts[0] === 'MATCH' && parts.length === 2) { return UiText.get($r('app.string.conflict_remaining'), label(parts[1]) || UiText.get($r('app.string.conflict_text_20'))); }
  if (!['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'GEOIP', 'GEOSITE', 'IP-CIDR', 'IP-CIDR6',
    'SRC-IP-CIDR', 'SRC-IP-CIDR6', 'PROCESS-NAME'].includes(parts[0]) || parts.length < 3 || parts.length > 4) {
    return UiText.get($r('app.string.conflict_text_21'));
  }
  const subject = label(parts[1]); const target = label(parts[2]);
  if (subject === '' || target === '') { return UiText.get($r('app.string.conflict_text_22')); }
  return `${parts[0]} ${subject} → ${target}${parts[3] === 'no-resolve' ? UiText.get($r('app.string.conflict_text_23')) : ''}`;
}
function entity(snapshot: TemplateSnapshot, id: string): Object | undefined {
  return snapshot.entries.find(item => item.id === id)?.value;
}
function at(value: Object | undefined, path: string[]): Object | undefined {
  let result = value;
  for (const key of path) {
    if (result === undefined || result === null || typeof result !== 'object' ||
      Array.isArray(result) || !Object.keys(result).includes(key)) { return undefined; }
    result = (result as Record<string, Object>)[key];
  }
  return result;
}
function valueSummary(value: Object | undefined, section: string, path: string[], side: string,
  other?: Object): string {
  if (value === undefined) { return UiText.get($r('app.string.conflict_text_24')); }
  if (value === null) { return UiText.get($r('app.string.conflict_text_25')); }
  if (path.some(key => !Object.keys(fields).includes(key)) ||
    path.some(key => ['password', 'uuid', 'token', 'headers', 'url', 'server'].includes(key))) {
    return UiText.get($r('app.string.conflict_hidden_change'), side);
  }
  if (section === 'rules' && typeof value === 'string') { return rule(value); }
  if (typeof value === 'string') { return label(value) || UiText.get($r('app.string.conflict_text_26')); }
  if (typeof value === 'number' || typeof value === 'boolean') { return String(value); }
  if (Array.isArray(value)) {
    const items = value as Object[];
    const alternative = Array.isArray(other) ? other as Object[] : [];
    const different = items.filter(item => !alternative.includes(item));
    let start = 0;
    if (different.length === 0) { start = Math.max(0, items.findIndex((item, index) => alternative[index] !== item)); }
    const visible = different.length > 0 ? different : items.slice(start);
    const names = visible.slice(0, 3).map(item => typeof item === 'string' ? label(item) : '');
    if (names.some(name => name === '')) { return UiText.get($r('app.string.conflict_hidden_items'), value.length); }
    return (different.length > 0 ? UiText.get($r('app.string.conflict_text_27')) : UiText.get($r('app.string.conflict_from_item'), start + 1)) + names.join('、') +
      (visible.length > 3 ? UiText.get($r('app.string.conflict_item_count'), visible.length) : '');
  }
  const name = (value as Record<string, Object>)['name'];
  return typeof name === 'string' && label(name) !== '' ? label(name) : UiText.get($r('app.string.conflict_field_changes'), side);
}
function orderSummary(snapshot: TemplateSnapshot, other: TemplateSnapshot, section: string, ids: string[]): string {
  const entries = snapshot.entries.filter(item => item.section === section);
  const alternative = other.entries.filter(item => item.section === section);
  if (entries.length === 0) { return UiText.get($r('app.string.conflict_text_28')); }
  const start = Math.max(0, entries.findIndex((item, index) => alternative[index]?.id !== item.id));
  return UiText.get($r('app.string.conflict_from_item'), start + 1) + entries.slice(start, start + 3).map(item =>
    `${ids.indexOf(item.id) + 1}. ${valueSummary(item.value, section, [], '')}`).join('；');
}
function fieldLabel(snapshots: TemplateSnapshot[], id: string, path: string[]): string {
  return path.map((key, index) => {
    const keys: string[] = [];
    snapshots.forEach(snapshot => {
      const parent = at(entity(snapshot, id), path.slice(0, index));
      if (parent !== undefined && parent !== null && typeof parent === 'object' && !Array.isArray(parent)) {
        Object.keys(parent).forEach(name => { if (!keys.includes(name)) { keys.push(name); } });
      }
    });
    const ordinal = keys.sort().indexOf(key) + 1;
    return fields[key] !== undefined ? UiText.get(fields[key]) : (label(key) || UiText.get($r('app.string.conflict_advanced_field'), Math.max(1, ordinal)));
  }).join(' · ');
}

/** Only invoked for a conflict, using the already captured private snapshots.
 * No exception bodies, raw JSON, opaque IDs or full YAML reach the cards. */
export function describeTemplateConflict(request: TemplateUpdateRequest,
  conflict: TemplateConflict): TemplateConflictDetail {
  const snapshots = [request.base, request.mine, request.next];
  const ids: string[] = [];
  snapshots.forEach(snapshot => snapshot.entries.forEach(item => {
    if (item.section === conflict.section && !ids.includes(item.id)) { ids.push(item.id); }
  }));
  const number = Math.max(0, ids.indexOf(conflict.entity)) + 1;
  const mine = entity(request.mine, conflict.entity);
  const next = entity(request.next, conflict.entity);
  const current = mine ?? next ?? entity(request.base, conflict.entity);
  let name = '';
  if (typeof current === 'string' && conflict.section === 'rules') { name = rule(current); }
  else if (current !== undefined && current !== null && typeof current === 'object' && !Array.isArray(current)) {
    const candidate = (current as Record<string, Object>)['name'];
    if (typeof candidate === 'string') { name = label(candidate); }
  }
  const path = conflict.path ?? [];
  const field = path.length > 0 ? fieldLabel(snapshots, conflict.entity, path) :
    conflict.kind === 'order' ? UiText.get($r('app.string.conflict_text_29')) : UiText.get($r('app.string.conflict_text_30'));
  return { title: `${sections[conflict.section] !== undefined ? UiText.get(sections[conflict.section]) : UiText.get($r('app.string.conflict_text_31'))} ${number}${name !== '' ? ` · ${name}` : ''} · ${field}`,
    mine: conflict.kind === 'order' ? orderSummary(request.mine, request.next, conflict.section, ids) :
      valueSummary(at(mine, path), conflict.section, path, UiText.get($r('app.string.conflict_text_32')), at(next, path)),
    template: conflict.kind === 'order' ? orderSummary(request.next, request.mine, conflict.section, ids) :
      valueSummary(at(next, path), conflict.section, path, UiText.get($r('app.string.conflict_text_33')), at(mine, path)) };
}

export function unavailableTemplateConflict(conflict: TemplateConflict): TemplateConflictDetail {
  const section = sections[conflict.section];
  return { title: section !== undefined ? UiText.get(section) : UiText.get($r('app.string.template_personal')),
    mine: UiText.get($r('app.string.template_repreview')), template: UiText.get($r('app.string.template_repreview')) };
}
