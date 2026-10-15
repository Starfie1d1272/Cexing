import { EditOperation, EditTarget, EditableItem } from './ConfigEditor';

export interface RuleFields { type: string; condition: string; target: string; noResolve: boolean; }
export interface ProviderFields { name: string; type: string; behavior: string; format: string; location: string; interval: number; }
export interface DnsFields { enabled: boolean; mode: string; nameservers: string[]; bootstrap: string[]; }
export const COMMON_RULE_TYPES: string[] = ['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'IP-CIDR', 'IP-CIDR6', 'GEOIP', 'GEOSITE', 'RULE-SET', 'MATCH'];

function atom(value: string): boolean { return value.length > 0 && !/[,\r\n\u0000]/.test(value); }
function object(value: Object): Record<string, Object> { return value as Record<string, Object>; }

export class RuleDnsForms {
  static parseRule(value: Object): RuleFields | null {
    if (typeof value !== 'string') { return null; }
    const parts = (value as string).split(',');
    if (!COMMON_RULE_TYPES.includes(parts[0])) { return null; }
    const match = parts[0] === 'MATCH';
    const length = match ? 2 : 3;
    if (parts.length !== length && parts.length !== length + 1) { return null; }
    const noResolve = parts.length === length + 1;
    if (noResolve && (parts[length] !== 'no-resolve' || !['IP-CIDR', 'IP-CIDR6', 'GEOIP'].includes(parts[0]))) { return null; }
    return { type: parts[0], condition: match ? '' : parts[1], target: parts[match ? 1 : 2], noResolve };
  }

  static ruleValue(fields: RuleFields): string {
    if (!COMMON_RULE_TYPES.includes(fields.type) || !atom(fields.target) ||
      (fields.type !== 'MATCH' && !atom(fields.condition))) { throw new Error('请填写规则与目标'); }
    if (fields.noResolve && !['IP-CIDR', 'IP-CIDR6', 'GEOIP'].includes(fields.type)) { throw new Error('此规则不支持 no-resolve'); }
    const value = fields.type === 'MATCH' ? `MATCH,${fields.target}` : `${fields.type},${fields.condition},${fields.target}`;
    return fields.noResolve ? `${value},no-resolve` : value;
  }

  static updateRule(id: string, selected: EditTarget, fields: RuleFields): EditOperation {
    return { id, kind: 'update', section: 'rules', target: selected.item.id,
      expected: selected.item.revision, value: RuleDnsForms.ruleValue(fields) };
  }

  static addRule(id: string, fields: RuleFields, matchId: string): EditOperation {
    if (fields.type === 'MATCH' && matchId !== '') { throw new Error('已有最终规则，请编辑它'); }
    return { id, kind: 'add', section: 'rules', value: RuleDnsForms.ruleValue(fields),
      before: fields.type === 'MATCH' ? '' : matchId };
  }

  static moveRule(id: string, item: EditableItem, before: string, matchId: string): EditOperation {
    if (item.id === matchId || (before === '' && matchId !== '')) { throw new Error('最终规则必须在末尾'); }
    if (item.id === before) { throw new Error('规则位置未变化'); }
    return { id, kind: 'move', section: 'rules', target: item.id, before };
  }

  static patch(id: string, section: string, selected: EditTarget,
    changes: Record<string, Object>, remove: string[] = []): EditOperation {
    if (section === 'dns' && (Object.keys(changes).includes('listen') || remove.includes('listen'))) {
      throw new Error('DNS 监听由系统管理');
    }
    const preconditions: Record<string, string> = {};
    for (const key of Object.keys(changes).concat(remove)) {
      const revision = selected.item.fields?.[key] ?? selected.missingFieldRevision;
      if (!revision) { throw new Error('字段版本未读取，请重新打开'); }
      preconditions[key] = revision;
    }
    return { id, kind: 'update', section, target: selected.item.id, patch: changes, remove, preconditions };
  }

  static providerValue(fields: ProviderFields): Record<string, Object> {
    if (!atom(fields.name) || !['http', 'file'].includes(fields.type) ||
      !['domain', 'ipcidr', 'classical'].includes(fields.behavior) ||
      !['yaml', 'text', 'mrs'].includes(fields.format) ||
      (fields.format === 'mrs' && fields.behavior === 'classical')) { throw new Error('请检查规则源类型'); }
    if (!Number.isInteger(fields.interval) || fields.interval < 0 || fields.interval > 604800) { throw new Error('更新间隔应为 0–604800 秒'); }
    const value: Record<string, Object> = {};
    value['type'] = fields.type; value['behavior'] = fields.behavior; value['format'] = fields.format;
    if (fields.type === 'http') {
      if (!/^https?:\/\/[^\s]+$/.test(fields.location)) { throw new Error('请输入 HTTP 或 HTTPS 地址'); }
      value['url'] = fields.location; value['interval'] = fields.interval;
    } else {
      if (fields.location === '' || fields.location.startsWith('/') || fields.location.includes('..') || /[\r\n\u0000]/.test(fields.location)) { throw new Error('请输入私有目录内的相对路径'); }
      value['path'] = fields.location;
    }
    return value;
  }

  static dnsFields(selected: EditTarget): DnsFields {
    const value = object(selected.value);
    return { enabled: value['enable'] === true, mode: typeof value['enhanced-mode'] === 'string' ? value['enhanced-mode'] as string : 'redir-host',
      nameservers: Array.isArray(value['nameserver']) ? value['nameserver'] as string[] : [],
      bootstrap: Array.isArray(value['default-nameserver']) ? value['default-nameserver'] as string[] : [] };
  }

  static dnsUpdate(id: string, selected: EditTarget, fields: DnsFields): EditOperation {
    if (!['fake-ip', 'redir-host'].includes(fields.mode) || fields.nameservers.length === 0 ||
      fields.nameservers.some((value: string) => value.trim() === '' || /[\r\n\u0000]/.test(value))) {
      throw new Error('请检查 DNS 服务器');
    }
    const changed: Record<string, Object> = {};
    changed['enable'] = fields.enabled; changed['enhanced-mode'] = fields.mode;
    changed['nameserver'] = fields.nameservers; changed['default-nameserver'] = fields.bootstrap;
    return RuleDnsForms.patch(id, 'dns', selected, changed);
  }

  static recommendedDns(selected: EditTarget): EditOperation {
    // Independently written preset. Only resolvers change; no listener, mode,
    // fake-IP filters, hosts, routing rules or Controller field is replaced.
    const changed: Record<string, Object> = {};
    changed['nameserver'] = ['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query'];
    changed['default-nameserver'] = ['223.5.5.5', '119.29.29.29'];
    return RuleDnsForms.patch('dns-preset-recommended', 'dns', selected, changed);
  }

  static deleteItem(id: string, section: string, selected: EditableItem): EditOperation {
    if (section === 'dns') { throw new Error('DNS 不能整段删除'); }
    return { id, kind: 'delete', section, target: selected.id, expected: selected.revision };
  }

  static advancedRule(id: string, selected: EditTarget, text: string): EditOperation {
    if (text.trim() === '' || /[\r\n\u0000]/.test(text)) { throw new Error('请输入单条规则'); }
    return { id, kind: 'update', section: 'rules', target: selected.item.id, expected: selected.item.revision, value: text };
  }

  static hostValue(value: string): Object {
    const entries = value.split(/[,\n]/).map((entry: string) => entry.trim()).filter((entry: string) => entry !== '');
    if (entries.length === 0) { throw new Error('请输入 hosts 地址'); }
    return entries.length === 1 ? entries[0] : entries;
  }

  static withoutPreset(operations: EditOperation[]): EditOperation[] {
    return operations.filter((op: EditOperation) => op.id !== 'dns-preset-recommended');
  }

  static advancedPatch(id: string, section: string, selected: EditTarget, text: string): EditOperation {
    const value = JSON.parse(text) as Object;
    if (typeof value !== 'object' || value === null || Array.isArray(value)) { throw new Error('高级字段必须是 JSON 对象'); }
    const original = object(selected.value);
    const edited = object(value);
    const changed: Record<string, Object> = {};
    for (const key of Object.keys(edited)) {
      if (JSON.stringify(original[key]) !== JSON.stringify(edited[key])) { changed[key] = edited[key]; }
    }
    const remove = Object.keys(original).filter((key: string) => !Object.keys(edited).includes(key));
    return RuleDnsForms.patch(id, section, selected, changed, remove);
  }
}
