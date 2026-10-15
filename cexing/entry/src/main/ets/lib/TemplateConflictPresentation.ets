import { TemplateConflict, TemplateConflictDetail, TemplateUpdateRequest, TemplateSnapshot } from './TemplateUpdates';

const sections: Record<string, string> = { 'rules': '分流规则', 'proxy-groups': '策略组',
  'proxies': '节点', 'proxy-providers': '节点来源', 'rule-providers': '规则来源', 'dns': 'DNS', 'hosts': '域名映射' };
const fields: Record<string, string> = { 'name': '名称', 'type': '类型', 'proxies': '成员', 'use': '来源',
  'interval': '检测间隔', 'tolerance': '容差', 'strategy': '策略', 'udp': 'UDP', 'port': '端口',
  'server': '服务器', 'url': '地址', 'password': '凭据', 'uuid': '凭据', 'headers': '请求头', 'token': '凭据' };

function label(value: string): string {
  // Names are user-facing identities. Never treat a URL, credential-shaped
  // string or control characters as a display name or a rule operand.
  if (value.length > 80 || /[\u0000-\u001f\u007f]|:\/\/|@|password|token|secret|authorization/i.test(value)) { return ''; }
  return value;
}
function rule(value: string): string {
  const parts = value.split(',');
  if (parts[0] === 'MATCH' && parts.length === 2) { return `其余流量 → ${label(parts[1]) || '指定出口'}`; }
  if (!['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'GEOIP', 'GEOSITE', 'IP-CIDR', 'IP-CIDR6',
    'SRC-IP-CIDR', 'SRC-IP-CIDR6', 'PROCESS-NAME'].includes(parts[0]) || parts.length < 3 || parts.length > 4) {
    return '高级规则（内容隐藏）';
  }
  const subject = label(parts[1]); const target = label(parts[2]);
  if (subject === '' || target === '') { return '规则内容已隐藏'; }
  return `${parts[0]} ${subject} → ${target}${parts[3] === 'no-resolve' ? '（不解析域名）' : ''}`;
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
  if (value === undefined) { return '删除此项'; }
  if (value === null) { return '空值'; }
  if (path.some(key => !Object.keys(fields).includes(key)) ||
    path.some(key => ['password', 'uuid', 'token', 'headers', 'url', 'server'].includes(key))) {
    return `${side}的修改（内容隐藏）`;
  }
  if (section === 'rules' && typeof value === 'string') { return rule(value); }
  if (typeof value === 'string') { return label(value) || '内容隐藏'; }
  if (typeof value === 'number' || typeof value === 'boolean') { return String(value); }
  if (Array.isArray(value)) {
    const items = value as Object[];
    const alternative = Array.isArray(other) ? other as Object[] : [];
    const different = items.filter(item => !alternative.includes(item));
    let start = 0;
    if (different.length === 0) { start = Math.max(0, items.findIndex((item, index) => alternative[index] !== item)); }
    const visible = different.length > 0 ? different : items.slice(start);
    const names = visible.slice(0, 3).map(item => typeof item === 'string' ? label(item) : '');
    if (names.some(name => name === '')) { return `${value.length} 项（内容隐藏）`; }
    return (different.length > 0 ? '包含：' : `第 ${start + 1} 项起：`) + names.join('、') +
      (visible.length > 3 ? ` 等 ${visible.length} 项` : '');
  }
  const name = (value as Record<string, Object>)['name'];
  return typeof name === 'string' && label(name) !== '' ? label(name) : `${side}的字段修改`;
}
function orderSummary(snapshot: TemplateSnapshot, other: TemplateSnapshot, section: string, ids: string[]): string {
  const entries = snapshot.entries.filter(item => item.section === section);
  const alternative = other.entries.filter(item => item.section === section);
  if (entries.length === 0) { return '无此类项目'; }
  const start = Math.max(0, entries.findIndex((item, index) => alternative[index]?.id !== item.id));
  return `第 ${start + 1} 项起：` + entries.slice(start, start + 3).map(item =>
    `${ids.indexOf(item.id) + 1}. ${valueSummary(item.value, section, [], '')}`).join('；');
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
  const field = path.length > 0 ? (fields[path[path.length - 1]] ?? (label(path[path.length - 1]) || '高级字段')) :
    conflict.kind === 'order' ? '排列顺序' : '内容';
  return { title: `${sections[conflict.section] ?? '个人修改'} ${number}${name !== '' ? ` · ${name}` : ''} · ${field}`,
    mine: conflict.kind === 'order' ? orderSummary(request.mine, request.next, conflict.section, ids) :
      valueSummary(at(mine, path), conflict.section, path, '我', at(next, path)),
    template: conflict.kind === 'order' ? orderSummary(request.next, request.mine, conflict.section, ids) :
      valueSummary(at(next, path), conflict.section, path, '新模板', at(mine, path)) };
}
