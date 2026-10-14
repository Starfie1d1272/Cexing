import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { CoreApi, ControllerAccess } from './CoreApi';
import { EffectiveVersions } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { VpnController, VpnStatus } from './VpnController';

export interface ProxyProviderObservation {
  available: boolean;
  count: number;
  updatedAt: number;
  refreshed: boolean;
  error: string;
}

/** Explicit inspection/update of an active provider through the existing
 * authenticated loopback API. Never fetches its subscription URL or logs data. */
export namespace ProxyProviderStatus {
  function selected(context: common.Context, file: string, version: string): boolean {
    const current = EffectiveVersions.read(context)?.Current;
    return !ProfileStore.isApplyUncertain(context) && version !== '' && VpnController.status === VpnStatus.Connected &&
      ProfileStore.getActiveFile(context) === file && current?.ProfileID === file && current.ID === version;
  }

  async function call(access: ControllerAccess, name: string, update: boolean): Promise<string> {
    if (access.httpBase !== 'http://127.0.0.1:9090' || access.secret === '' || name === '') {
      throw new Error('控制面不可用');
    }
    const request = http.createHttp();
    try {
      const response = await request.request(`${access.httpBase}/providers/proxies/${encodeURIComponent(name)}`, {
        method: update ? http.RequestMethod.PUT : http.RequestMethod.GET,
        header: { 'Authorization': `Bearer ${access.secret}` }, readTimeout: 8000, connectTimeout: 8000 });
      if (response.responseCode < 200 || response.responseCode >= 300) { throw new Error('来源请求未完成'); }
      const body = typeof response.result === 'string' ? response.result : '';
      if (body.length > 2 * 1024 * 1024) { throw new Error('来源状态过大'); }
      return body;
    } finally { request.destroy(); }
  }

  export async function observe(context: common.Context, file: string, version: string,
    name: string, update: boolean): Promise<ProxyProviderObservation> {
    const result: ProxyProviderObservation = { available: false, count: 0, updatedAt: 0, refreshed: false, error: '' };
    try {
      if (!selected(context, file, version)) { result.error = '连接此订阅后可查看来源状态'; return result; }
      const access = CoreApi.getControllerAccess();
      const session = await CoreApi.getControllerSession();
      if (access === null || session === null || !selected(context, file, version)) { throw new Error('状态不可用'); }
      if (update) {
        try { await call(access, name, true); result.refreshed = true; }
        catch (_) { result.error = '来源更新失败，请重试'; }
      }
      if (!selected(context, file, version) || await CoreApi.getControllerSession() !== session) {
        result.refreshed = false; result.error = '配置已变化，请重新读取'; return result;
      }
      const data = JSON.parse(await call(access, name, false)) as Record<string, Object>;
      if (!Array.isArray(data['proxies'])) { throw new Error('来源状态无效'); }
      if (!selected(context, file, version) || await CoreApi.getControllerSession() !== session) {
        result.refreshed = false; result.error = '配置已变化，请重新读取'; return result;
      }
      result.available = true;
      result.count = (data['proxies'] as Object[]).length;
      const updated = typeof data['updatedAt'] === 'string' ? Date.parse(data['updatedAt'] as string) : 0;
      result.updatedAt = Number.isFinite(updated) && updated > 0 ? updated : 0;
    } catch (_) { result.refreshed = false; result.error = '来源状态读取失败，请重试'; }
    return result;
  }
}
