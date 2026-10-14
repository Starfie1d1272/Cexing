/* Offline validation on the existing C++ single worker; never applies config. */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Settings } from './Settings';

export interface MergeFieldChange {
  field: string; kind: string; before: number; after: number; reordered?: boolean;
}
export interface MergeChange {
  section: string; before: number; after: number;
  kind?: string; contentChanged?: boolean;
  added?: number; removed?: number; modified?: number; reordered?: boolean;
  typesChanged?: number; membersChanged?: number; fields?: MergeFieldChange[];
}
export interface MergePreview { digest: string; changes: MergeChange[]; platformChanges?: MergeChange[]; }

export namespace CoreValidator {
  function sectionLabel(section: string): string {
    switch (section) {
      case 'proxies': return '节点';
      case 'proxy-providers': return '节点源';
      case 'proxy-groups': return '策略组';
      case 'rules': return '规则';
      case 'rule-providers': return '规则源';
      case 'dns': return 'DNS';
      case 'hosts': return 'Hosts';
      case 'listeners': return '监听';
      case 'tun': return 'TUN';
      case 'mode': return '模式';
      case 'external-controller': return '控制接口';
      case 'external-ui': return '面板';
      case 'allow-lan': return '局域网代理';
      case 'bind-address': return '代理监听';
      case 'mixed-port': case 'port': case 'socks-port': case 'redir-port': case 'tproxy-port': return '代理端口';
      default: return '其他配置';
    }
  }

  /** Shared presentation only: semantic comparison belongs to the Go compiler. */
  export function describeMergeChange(change: MergeChange): string {
    const label = sectionLabel(change.section);
    if (change.kind === 'protected') { return `${label}：使用设备约束`; }
    if (change.kind === 'cleared') { return `${label}：已清空`; }
    if ((change.typesChanged ?? 0) > 0 && (change.membersChanged ?? 0) > 0) {
      return `${label}：类型和成员已调整`;
    }
    if ((change.typesChanged ?? 0) > 0) { return `${label}：类型已调整`; }
    if ((change.membersChanged ?? 0) > 0) { return `${label}：成员已调整`; }
    if (change.reordered && (change.modified ?? 0) === 0 && (change.added ?? 0) === 0 && (change.removed ?? 0) === 0) {
      return `${label}：顺序已调整`;
    }
    if ((change.modified ?? 0) > 0) { return `${label}：修改 ${change.modified} 项`; }
    if ((change.added ?? 0) > 0 && (change.removed ?? 0) === 0) { return `${label}：新增 ${change.added} 项`; }
    if ((change.removed ?? 0) > 0 && (change.added ?? 0) === 0) { return `${label}：移除 ${change.removed} 项`; }
    if (change.kind === 'added') { return `${label}：已添加`; }
    if (change.kind === 'removed') { return `${label}：已移除`; }
    return `${label}：内容已调整`;
  }

  export function describeMergePreview(preview: MergePreview): string {
    const parts = preview.changes.map((change: MergeChange) => describeMergeChange(change));
    const protectedCount = preview.platformChanges?.length ?? 0;
    if (protectedCount > 0) { parts.push(`${protectedCount} 项使用设备约束`); }
    return parts.length > 0 ? parts.join(' · ') : '无需更改';
  }

  export async function prepareResources(context: common.Context): Promise<void> {
    await ensureGeoData(context);
  }

  async function ensureGeoData(context: common.Context): Promise<void> {
    const path = `${context.filesDir}/geoip.metadb`;
    if (fileIo.accessSync(path) && fileIo.statSync(path).size > 0) { return; }
    const bytes = await context.resourceManager.getRawFileContent('geodata/geoip.metadb');
    const temp = `${path}.validate-pending`;
    const file = fileIo.openSync(temp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, bytes.buffer); } finally { fileIo.closeSync(file); }
    fileIo.moveFileSync(temp, path);
  }

  export async function validate(context: common.Context, content: string): Promise<string> {
    await ensureGeoData(context);
    const overrides = settingsOverrides(context);
    let code = '';
    try { code = await core.validateOffline(context.filesDir, content, overrides); }
    catch (_) { throw new Error('本机配置校验不可用，原配置未修改'); }
    if (code === '') { return ''; }
    if (/^CACHED_PROVIDER:[0-9a-f]{64}$/.test(code)) { return code; }
    if (code === 'PROVIDER_UNRESOLVED') {
      throw new Error('配置包含尚未验证的 provider 资源，原配置未修改');
    }
    if (code === 'RESOURCE_MISSING') {
      throw new Error('配置所需的离线资源缺失，原配置未修改');
    }
    throw new Error('配置未通过本机 Mihomo 校验，原配置未修改');
  }

  function settingsOverrides(context: common.Context): string {
    const s = Settings.load(context);
    return JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, ipv6: s.ipv6, mode: s.mode, logToFile: s.logToFile });
  }

  export async function previewMerge(context: common.Context, original: string,
    overlay: string): Promise<MergePreview> {
    await ensureGeoData(context);
    let response = '';
    try { response = await core.previewMerge(context.filesDir, original, overlay, settingsOverrides(context)); }
    catch (_) { throw new Error('本机 Merge 预览不可用'); }
    try {
      const parsed = JSON.parse(response) as Record<string, Object>;
      if (typeof parsed['digest'] !== 'string' || !Array.isArray(parsed['changes'])) {
        throw new Error('invalid preview');
      }
      return { digest: parsed['digest'] as string, changes: parsed['changes'] as MergeChange[],
        platformChanges: parsed['platformChanges'] as MergeChange[] | undefined };
    } catch (_) { throw new Error('Merge 未通过本机校验或资源未解析'); }
  }

}
