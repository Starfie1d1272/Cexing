import { UiText } from './UiText';
/* Offline validation on the existing C++ single worker; never applies config. */
import { common } from '@kit.AbilityKit';
import { GeoDataAssets } from './GeoDataAssets';
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
      case 'proxies': return UiText.get($r('app.string.merge_nodes'));
      case 'proxy-providers': return UiText.get($r('app.string.merge_node_sources'));
      case 'proxy-groups': return UiText.get($r('app.string.merge_groups'));
      case 'rules': return UiText.get($r('app.string.merge_rules'));
      case 'rule-providers': return UiText.get($r('app.string.merge_rule_sources'));
      case 'dns': return 'DNS';
      case 'hosts': return 'Hosts';
      case 'listeners': return UiText.get($r('app.string.merge_listeners'));
      case 'tun': return 'TUN';
      case 'mode': return UiText.get($r('app.string.merge_mode'));
      case 'external-controller': return UiText.get($r('app.string.merge_controller'));
      case 'external-ui': return UiText.get($r('app.string.merge_panel'));
      case 'allow-lan': return UiText.get($r('app.string.merge_lan'));
      case 'bind-address': return UiText.get($r('app.string.merge_bind'));
      case 'mixed-port': case 'port': case 'socks-port': case 'redir-port': case 'tproxy-port': return UiText.get($r('app.string.merge_ports'));
      default: return UiText.get($r('app.string.merge_other'));
    }
  }

  /** Shared presentation only: semantic comparison belongs to the Go compiler. */
  export function describeMergeChange(change: MergeChange): string {
    const label = sectionLabel(change.section);
    if (change.kind === 'protected') { return UiText.get($r('app.string.merge_protected'), label); }
    if (change.kind === 'cleared') { return UiText.get($r('app.string.merge_cleared'), label); }
    if ((change.typesChanged ?? 0) > 0 && (change.membersChanged ?? 0) > 0) {
      return UiText.get($r('app.string.merge_types_members'), label);
    }
    if ((change.typesChanged ?? 0) > 0) { return UiText.get($r('app.string.merge_types'), label); }
    if ((change.membersChanged ?? 0) > 0) { return UiText.get($r('app.string.merge_members'), label); }
    if (change.reordered && (change.modified ?? 0) === 0 && (change.added ?? 0) === 0 && (change.removed ?? 0) === 0) {
      return UiText.get($r('app.string.merge_reordered'), label);
    }
    if ((change.modified ?? 0) > 0) { return UiText.get($r('app.string.merge_modified'), label, change.modified ?? 0); }
    if ((change.added ?? 0) > 0 && (change.removed ?? 0) === 0) { return UiText.get($r('app.string.merge_added_count'), label, change.added ?? 0); }
    if ((change.removed ?? 0) > 0 && (change.added ?? 0) === 0) { return UiText.get($r('app.string.merge_removed_count'), label, change.removed ?? 0); }
    if (change.kind === 'added') { return UiText.get($r('app.string.merge_added'), label); }
    if (change.kind === 'removed') { return UiText.get($r('app.string.merge_removed'), label); }
    return UiText.get($r('app.string.merge_content'), label);
  }

  export function describeMergePreview(preview: MergePreview): string {
    const parts = preview.changes.map((change: MergeChange) => describeMergeChange(change));
    const protectedCount = preview.platformChanges?.length ?? 0;
    if (protectedCount > 0) { parts.push(UiText.get($r('app.string.merge_device_count'), protectedCount)); }
    return parts.length > 0 ? parts.join(' · ') : UiText.get($r('app.string.merge_no_changes'));
  }

  /** Fixed recovery guidance only; never echo arbitrary backend error text. */
  export function describeMergeFailure(error: Object, fallback: Resource): string {
    if (error === null || error === undefined) { return UiText.get(fallback); }
    const message = (error as Error).message ?? '';
    if (message === '备份恢复未确认，请重新打开应用后重试') { return UiText.get($r('app.string.failure_recovery_restart')); }
    if (message.includes('未确认') || message.includes('结果未知')) { return UiText.get($r('app.string.editor_unknown')); }
    if (message.startsWith('请先启用订阅')) { return UiText.get($r('app.string.editor_enable_first')); }
    if (message === 'Invalid packaged GeoData') { return UiText.get($r('app.string.merge_update_package')); }
    if (message.includes('RESOURCE_MISSING') || ['Invalid GeoData file', 'Short GeoData read',
      'GeoData staging exists', 'Short GeoData write', 'GeoData staged checksum mismatch',
      'Unsafe GeoData destination', '配置所需的离线资源缺失，原配置未修改'].includes(message)) {
      return UiText.get($r('app.string.merge_repair_resources'));
    }
    if (message.includes('PROVIDER_UNRESOLVED') || message === '配置包含尚未验证的 provider 资源，原配置未修改') {
      return UiText.get($r('app.string.merge_update_source'));
    }
    if (['预览已变化，请重新预览', 'provider 缓存已变化，请重试', '版本已变化，请重新预览'].includes(message)) {
      return UiText.get($r('app.string.merge_repreview'));
    }
    if (['当前原始配置读取失败', '原始配置不存在', '目标配置不存在或读取失败'].includes(message)) {
      return UiText.get($r('app.string.merge_reread'));
    }
    if (message === '已有配置操作正在进行，请稍后重试') { return UiText.get($r('app.string.merge_wait')); }
    if (message === '请先断开连接') { return UiText.get($r('app.string.merge_disconnect')); }
    return UiText.get(fallback);
  }

  export async function prepareResources(context: common.Context): Promise<void> {
    await ensureGeoData(context);
  }

  async function ensureGeoData(context: common.Context): Promise<void> {
    if (await GeoDataAssets.inspect(context) !== 'ready') {
      await GeoDataAssets.restore(context, { cancelled: false });
    }
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
