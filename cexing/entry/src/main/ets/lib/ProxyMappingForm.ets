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

  constructor(section: string, target: EditTarget | null = null) {
    if (!['proxies', 'proxy-providers', 'proxy-groups'].includes(section)) { throw new Error('编辑类型不可用'); }
    this.section = section;
    this.target = target;
    this.value = target === null ? {} : JSON.parse(JSON.stringify(target.value)) as Record<string, Object>;
    if (target !== null && target.name !== undefined && section === 'proxy-providers') { this.value['name'] = target.name; }
  }

  text(key: string): string {
    const value = this.value[key];
    return typeof value === 'string' || typeof value === 'number' ? String(value) : '';
  }

  list(key: string): string[] {
    const value = this.value[key];
    return Array.isArray(value) ? (value as string[]).slice() : [];
  }

  setText(key: string, value: string): void {
    if (value === '') { delete this.value[key]; } else { this.value[key] = value; }
  }
  setList(key: string, value: string[]): void { this.value[key] = value.slice(); }
  flag(key: string): boolean { return this.value[key] === true; }
  setFlag(key: string, value: boolean): void { this.value[key] = value; }

  setNumber(key: string, value: string): void {
    this.invalidNumbers = this.invalidNumbers.filter((name: string) => name !== key);
    if (value.trim() === '') { delete this.value[key]; return; }
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) {
      this.invalidNumbers.push(key); return;
    }
    this.value[key] = Number(value);
  }

  advancedText(): string { return JSON.stringify(this.value, null, 2); }

  replaceAdvanced(value: string): void {
    let parsed: Record<string, Object>;
    try { parsed = JSON.parse(value) as Record<string, Object>; } catch (_) { throw new Error('高级字段格式无效'); }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { throw new Error('高级字段需要是对象'); }
    this.value = parsed;
    this.invalidNumbers = [];
  }

  private required(key: string, label: string): void {
    if (this.text(key).trim() === '') { throw new Error(`请填写${label}`); }
  }

  finish(): ProxyMappingDraft {
    if (this.invalidNumbers.length > 0) { throw new Error('请填写有效数字'); }
    this.required('name', '名称');
    this.required('type', '类型');
    const type = this.text('type');
    if (this.section === 'proxies') {
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
    } else if (this.list('proxies').length === 0 && this.list('use').length === 0) {
      throw new Error('请添加节点或订阅来源');
    }
    const value = JSON.parse(JSON.stringify(this.value)) as Record<string, Object>;
    if (this.section === 'proxy-providers') { delete value['name']; }
    return { section: this.section, name: this.text('name'), target: this.target, value: value };
  }
}
