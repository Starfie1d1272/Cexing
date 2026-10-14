import { util } from '@kit.ArkTS';

/** Bounded, local sharing-link decoding. Unsupported fields fail closed rather
 * than silently disappearing. No network, persistence or diagnostic output. */
export namespace ProxyNodeImport {
  function fail(): never { throw new Error('节点链接无效或包含暂不支持的参数，请检查或使用高级编辑'); }
  function decoded(value: string): string {
    let text: string;
    try { text = decodeURIComponent(value); } catch (_) { return fail(); }
    if (/[\u0000-\u001f\u007f]/.test(text)) { return fail(); }
    return text;
  }
  function base64(value: string): string {
    if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) { return fail(); }
    let normalized = value.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '');
    if (normalized.length % 4 === 1) { return fail(); }
    while (normalized.length % 4 !== 0) { normalized += '='; }
    try {
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new util.Base64Helper().decodeSync(normalized));
    } catch (_) { return fail(); }
  }
  function endpoint(value: string): Record<string, Object> {
    const match = /^(?:\[([0-9a-f:]+)\]|([a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)):(\d+)$/i.exec(value);
    if (match === null || Number(match[3]) < 1 || Number(match[3]) > 65535) { return fail(); }
    const address: Record<string, Object> = {};
    address['server'] = match[1] || match[2]; address['port'] = Number(match[3]); return address;
  }
  function query(value: string): Record<string, string> {
    const result: Record<string, string> = {};
    if (value === '') { return result; }
    for (const part of value.split('&')) {
      const index = part.indexOf('=');
      if (index < 1) { return fail(); }
      const key = decoded(part.slice(0, index));
      if (Object.keys(result).includes(key) || ['__proto__', 'constructor', 'prototype'].includes(key)) { return fail(); }
      result[key] = decoded(part.slice(index + 1));
    }
    return result;
  }
  function transport(node: Record<string, Object>, network: string, host: string, path: string): void {
    if (!['tcp', 'ws', 'grpc'].includes(network)) { return fail(); }
    if (network === 'tcp') { if (host !== '' || path !== '') { return fail(); } return; }
    node['network'] = network;
    if (network === 'ws') {
      const options: Record<string, Object> = {};
      if (path !== '') { options['path'] = path; }
      if (host !== '') { const headers: Record<string, Object> = {}; headers['Host'] = host; options['headers'] = headers; }
      node['ws-opts'] = options;
    } else {
      if (host !== '') { return fail(); }
      const options: Record<string, Object> = { 'grpc-service-name': path };
      node['grpc-opts'] = options;
    }
  }
  function vmess(value: string): Record<string, Object> {
    let raw: Record<string, Object>;
    try { raw = JSON.parse(base64(value)) as Record<string, Object>; } catch (_) { return fail(); }
    if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) { return fail(); }
    const allowed = ['v', 'ps', 'add', 'port', 'id', 'aid', 'scy', 'net', 'type', 'host', 'path', 'tls', 'sni', 'fp', 'alpn'];
    if (Object.keys(raw).some((key: string) => !allowed.includes(key)) ||
      Object.keys(raw).some((key: string) => typeof raw[key] !== 'string' && typeof raw[key] !== 'number')) { return fail(); }
    const node = endpoint(`${String(raw['add'] ?? '')}:${String(raw['port'] ?? '')}`);
    node['type'] = 'vmess'; node['name'] = String(raw['ps'] || '导入节点'); node['uuid'] = String(raw['id'] ?? '');
    node['alterId'] = Number(raw['aid'] ?? 0); node['cipher'] = String(raw['scy'] || 'auto');
    if (node['uuid'] === '' || !Number.isInteger(node['alterId'] as number) || (node['alterId'] as number) < 0 ||
      (raw['type'] !== undefined && raw['type'] !== '' && raw['type'] !== 'none')) { return fail(); }
    transport(node, String(raw['net'] || 'tcp'), String(raw['host'] ?? ''), String(raw['path'] ?? ''));
    if (raw['tls'] !== undefined && raw['tls'] !== '' && raw['tls'] !== 'tls') { return fail(); }
    if (raw['tls'] === 'tls') { node['tls'] = true; }
    if (raw['sni']) { node['servername'] = String(raw['sni']); }
    if (raw['fp']) { node['client-fingerprint'] = String(raw['fp']); }
    if (raw['alpn']) { node['alpn'] = String(raw['alpn']).split(','); }
    return node;
  }
  export function parse(input: string): Record<string, Object> {
    if (input.length > 8192 || /\s|[\u0000-\u001f\u007f]/.test(input)) { return fail(); }
    const protocol = /^(ss|vmess|vless|trojan):\/\/(.+)$/i.exec(input);
    if (protocol === null) { return fail(); }
    const type = protocol[1].toLowerCase();
    if (type === 'vmess' && !protocol[2].includes('@')) { return vmess(protocol[2]); }
    let body = protocol[2]; let name = '导入节点';
    const fragment = body.indexOf('#');
    if (fragment >= 0) { name = decoded(body.slice(fragment + 1)) || name; body = body.slice(0, fragment); }
    const split = body.indexOf('?');
    const fields = query(split >= 0 ? body.slice(split + 1) : '');
    body = (split >= 0 ? body.slice(0, split) : body).replace(/\/$/, '');
    let legacy = false;
    if (type === 'ss' && !body.includes('@')) { body = base64(body); legacy = true; }
    const at = body.lastIndexOf('@');
    if (at < 1) { return fail(); }
    const credentials = body.slice(0, at);
    const node = endpoint(body.slice(at + 1)); node['name'] = name; node['type'] = type;
    if (type === 'ss') {
      if (Object.keys(fields).length > 0) { return fail(); }
      const plain = !legacy && credentials.includes(':');
      const text = plain || legacy ? credentials : base64(credentials);
      const colon = text.indexOf(':'); if (colon < 1) { return fail(); }
      node['cipher'] = plain ? decoded(text.slice(0, colon)) : text.slice(0, colon);
      node['password'] = plain ? decoded(text.slice(colon + 1)) : text.slice(colon + 1);
      if (/[\u0000-\u001f\u007f]/.test(String(node['password']))) { return fail(); }
      if (node['password'] === '') { return fail(); } return node;
    }
    const allowed = ['encryption', 'type', 'security', 'sni', 'peer', 'fp', 'alpn', 'host', 'path', 'serviceName', 'flow', 'pbk', 'sid', 'allowInsecure'];
    if (Object.keys(fields).some((key: string) => !allowed.includes(key)) || fields['allowInsecure'] && fields['allowInsecure'] !== '0') { return fail(); }
    const credential = decoded(credentials); if (credential === '' || credential.includes('@')) { return fail(); }
    node[type === 'trojan' ? 'password' : 'uuid'] = credential;
    if (type === 'vless' && fields['encryption'] && fields['encryption'] !== 'none') { return fail(); }
    if (type === 'vmess') { node['cipher'] = fields['encryption'] || 'auto'; node['alterId'] = 0; }
    transport(node, fields['type'] || 'tcp', fields['host'] || '', fields['serviceName'] || fields['path'] || '');
    if (fields['serviceName'] && fields['path']) { return fail(); }
    const security = fields['security'] || (type === 'trojan' ? 'tls' : 'none');
    if (!['none', 'tls', 'reality'].includes(security) || type === 'trojan' && security === 'none') { return fail(); }
    if (security !== 'none' && type !== 'trojan') { node['tls'] = true; }
    if (fields['sni'] && fields['peer']) { return fail(); }
    if (fields['sni'] || fields['peer']) { node[type === 'trojan' ? 'sni' : 'servername'] = fields['sni'] || fields['peer']; }
    if (fields['fp']) { node['client-fingerprint'] = fields['fp']; }
    if (fields['alpn']) { node['alpn'] = fields['alpn'].split(','); }
    if (fields['flow']) { if (type !== 'vless') { return fail(); } node['flow'] = fields['flow']; }
    if (security === 'reality') {
      if (type !== 'vless' || !fields['pbk']) { return fail(); }
      const reality: Record<string, Object> = { 'public-key': fields['pbk'] };
      if (fields['sid']) { reality['short-id'] = fields['sid']; } node['reality-opts'] = reality;
    } else if (fields['pbk'] || fields['sid']) { return fail(); }
    return node;
  }
}
