import { EditTarget } from './ConfigEditor';

/** Transient form result only. The editor host builds field operations from its
 * original target fingerprints; this object is never a Merge or saved YAML. */
export interface ProxyMappingDraft {
  section: string;
  name: string;
  target: EditTarget | null;
  value: Record<string, Object>;
}

export class ProxyMappingForm {
  readonly section: string;
  readonly target: EditTarget | null;
  private value: Record<string, Object>;
  private invalidNumbers: string[] = [];
  private mappingName: string = '';

  constructor(section: string, target: EditTarget | null = null) {
    if (!['proxies', 'proxy-providers', 'proxy-groups'].includes(section)) { throw new Error('编辑类型不可用'); }
    this.section = section;
    this.target = target;
    if (target !== null) {
      if (target.value === null || typeof target.value !== 'object' || Array.isArray(target.value)) {
        throw new Error('该项目需使用原始配置编辑');
      }
      this.representable(target.value, 0);
    }
    this.value = target === null ? {} : JSON.parse(JSON.stringify(target.value)) as Record<string, Object>;
    if (target !== null && section === 'proxy-providers') { this.mappingName = target.name ?? ''; }
  }

  private representable(value: Object, depth: number): void {
    if (depth > 64) { throw new Error('该项目需使用原始配置编辑'); }
    if (typeof value === 'number' && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) {
      throw new Error('该项目需使用原始配置编辑');
    }
    if (Array.isArray(value)) {
      for (const item of value as Object[]) { this.representable(item, depth + 1); }
    } else if (value !== null && typeof value === 'object') {
      const mapping = value as Record<string, Object>;
      for (const key of Object.keys(mapping)) { this.representable(mapping[key], depth + 1); }
    }
  }

  text(key: string): string {
    if (this.section === 'proxy-providers' && key === 'name') { return this.mappingName; }
    const value = this.value[key];
    return typeof value === 'string' || typeof value === 'number' ? String(value) : '';
  }

  list(key: string): string[] {
    const value = this.value[key];
    return Array.isArray(value) ? (value as string[]).slice() : [];
  }

  setText(key: string, value: string): void {
    if (this.section === 'proxy-providers' && key === 'name') { this.mappingName = value; return; }
    if (value === '') { this.value = this.without(this.value, key); } else { this.value[key] = value; }
  }
  setList(key: string, value: string[]): void { this.value[key] = value.slice(); }
  flag(key: string): boolean { return this.value[key] === true; }
  flagOrDefault(key: string, value: boolean): boolean { return this.value[key] === undefined ? value : this.flag(key); }
  setFlag(key: string, value: boolean): void { this.value[key] = value; }

  nestedText(path: string[]): string {
    let value: Object | undefined = this.value;
    for (const key of path) {
      if (value === null || typeof value !== 'object' || Array.isArray(value)) { return ''; }
      value = (value as Record<string, Object>)[key];
    }
    return typeof value === 'string' || typeof value === 'number' ? String(value) : '';
  }

  private without(mapping: Record<string, Object>, removed: string): Record<string, Object> {
    // JSON-backed mappings may contain unknown keys such as __proto__.
    // Reparse property data rather than invoking JavaScript prototype setters.
    const entries: string[] = [];
    for (const key of Object.keys(mapping)) {
      if (key !== removed) { entries.push(`${JSON.stringify(key)}:${JSON.stringify(mapping[key])}`); }
    }
    return JSON.parse(`{${entries.join(',')}}`) as Record<string, Object>;
  }

  private nested(mapping: Record<string, Object>, path: string[], index: number, value: string): Record<string, Object> {
    const key = path[index];
    const next = this.without(mapping, key);
    if (index === path.length - 1) { if (value !== '') { next[key] = value; } return next; }
    const current = mapping[key];
    const empty: Record<string, Object> = {};
    if (current !== undefined && (current === null || typeof current !== 'object' || Array.isArray(current))) {
      throw new Error('该字段请使用高级编辑');
    }
    next[key] = this.nested(current === undefined ? empty : current as Record<string, Object>, path, index + 1, value);
    return next;
  }

  setNestedText(path: string[], value: string): void {
    if (path.length === 0) { return; }
    this.value = this.nested(this.value, path, 0, value);
  }

  setNumber(key: string, value: string): void {
    this.invalidNumbers = this.invalidNumbers.filter((name: string) => name !== key);
    if (value.trim() === '') { this.value = this.without(this.value, key); return; }
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
      this.invalidNumbers.push(key); return;
    }
    this.value[key] = Number(value);
  }

  setFraction(key: string, value: string): void {
    this.invalidNumbers = this.invalidNumbers.filter(name => name !== key);
    if (value.trim() === '') { this.value = this.without(this.value, key); return; }
    const number = Number(value);
    if (!Number.isFinite(number) || number <= 0 || number > 1) { this.invalidNumbers.push(key); return; }
    this.value[key] = number;
  }
  advancedText(): string { return JSON.stringify(this.value, null, 2); }

  replaceAdvanced(value: string): void {
    let parsed: Record<string, Object>;
    try { parsed = JSON.parse(value) as Record<string, Object>; } catch (_) { throw new Error('高级字段格式无效'); }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { throw new Error('高级字段需要是对象'); }
    this.representable(parsed, 0);
    this.value = parsed;
    this.invalidNumbers = [];
  }

  private required(key: string, label: string): void {
    if (this.text(key).trim() === '') { throw new Error(`请填写${label}`); }
  }

  private validateGroupOptions(): void {
    for (const key of ['interval', 'timeout', 'max-failed-times', 'tolerance']) {
      const value = this.value[key]; if (value === undefined) { continue; }
      const limit = key === 'timeout' ? 300000 : key === 'tolerance' ? 65535 : 86400;
      if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > limit) { throw new Error('请填写有效数字'); }
    }
    const sample = this.value['sample-rate'];
    if (sample !== undefined && (typeof sample !== 'number' || !Number.isFinite(sample) || sample <= 0 || sample > 1)) { throw new Error('请填写有效数字'); }
    const status = this.value['expected-status'];
    if (status !== undefined && (typeof status !== 'string' || !/^(\*|[0-9]+(?:-[0-9]+)?(?:\/[0-9]+(?:-[0-9]+)?)*)$/.test(status))) { throw new Error('高级字段格式无效'); }
    for (const key of ['lazy', 'uselightgbm', 'collectdata', 'prefer-asn', 'include-all', 'include-all-proxies', 'include-all-providers']) {
      if (this.value[key] !== undefined && typeof this.value[key] !== 'boolean') { throw new Error('高级字段格式无效'); }
    }
    const priority = this.text('policy-priority');
    for (const rule of priority.split(';')) {
      if (rule.trim() === '') { continue; }
      const index = rule.lastIndexOf(':'); const factor = Number(rule.substring(index + 1));
      if (index < 1 || !Number.isFinite(factor) || factor <= 0) { throw new Error('高级字段格式无效'); }
    }
  }

  finish(): ProxyMappingDraft {
    if (this.invalidNumbers.length > 0) { throw new Error('请填写有效数字'); }
    this.required('name', '名称');
    this.required('type', '类型');
    const type = this.text('type');
    if (this.section === 'proxies' && ['ss', 'vmess', 'vless', 'trojan'].includes(type)) {
      this.required('server', '服务器');
      const port = this.value['port'];
      if (typeof port !== 'number' || !Number.isInteger(port) || port < 1 || port > 65535) { throw new Error('端口应为 1–65535'); }
      if (type === 'ss') { this.required('cipher', '加密方式'); this.required('password', '密码'); }
      if (type === 'vmess' || type === 'vless') { this.required('uuid', 'UUID'); }
      if (type === 'trojan') { this.required('password', '密码'); }
    } else if (this.section === 'proxy-providers') {
      if (type === 'http') {
        if (!/^https?:\/\/\S+$/i.test(this.text('url'))) { throw new Error('请填写来源链接'); }
      } else if (type === 'file') { this.required('path', '文件路径'); }
      else if (type === 'inline' && !Array.isArray(this.value['payload'])) { throw new Error('请在高级编辑中填写节点列表'); }
    } else if (this.section === 'proxy-groups' && this.list('proxies').length === 0 && this.list('use').length === 0 && !['include-all', 'include-all-proxies', 'include-all-providers'].some(key => this.flag(key))) {
      throw new Error('请添加节点或订阅来源');
    }
    if (this.section === 'proxy-groups') { this.validateGroupOptions(); }
    const value = JSON.parse(JSON.stringify(this.value)) as Record<string, Object>;
    return { section: this.section, name: this.text('name'), target: this.target, value: value };
  }
}
