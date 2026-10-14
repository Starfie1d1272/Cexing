import { http } from '@kit.NetworkKit';
import { CoreApi } from './CoreApi';

export interface RuleProviderObservation { available: boolean; count: number; updatedAt: string; references: number; error: string; }

// Existing authenticated loopback Controller only. No profile/settings writes,
// direct provider URL fetch, config reload, fallback rule or diagnostic logging.
export class RuleProviderStatus {
  private static async call(name: string, method: http.RequestMethod): Promise<string> {
    const access = CoreApi.getControllerAccess();
    if (access === null || access.httpBase !== 'http://127.0.0.1:9090' || name === '') { throw new Error('控制面不可用'); }
    return RuleProviderStatus.path(`/providers/rules/${encodeURIComponent(name)}`, method);
  }
  private static async path(path: string, method: http.RequestMethod): Promise<string> {
    const access = CoreApi.getControllerAccess();
    if (access === null || access.httpBase !== 'http://127.0.0.1:9090') { throw new Error('控制面不可用'); }
    const request = http.createHttp();
    try {
      const response = await request.request(`${access.httpBase}${path}`,
        { method, header: { 'Authorization': `Bearer ${access.secret}` }, readTimeout: 8000, connectTimeout: 8000 });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        let error = '规则源更新失败';
        try {
          const body = JSON.parse(response.result as string) as Record<string, Object>;
          if (typeof body['message'] === 'string') { error = (body['message'] as string).slice(0, 512); }
        } catch (_) {}
        throw new Error(error);
      }
      return response.result as string;
    } finally { request.destroy(); }
  }
  static async read(name: string): Promise<RuleProviderObservation> {
    try {
      const session = await CoreApi.getControllerSession();
      if (session === null) { throw new Error('运行会话未确认'); }
      const value = JSON.parse(await RuleProviderStatus.call(name, http.RequestMethod.GET)) as Record<string, Object>;
      if (typeof value['ruleCount'] !== 'number' || !Number.isInteger(value['ruleCount']) || (value['ruleCount'] as number) < 0) { throw new Error('无法核验规则源'); }
      let references = -1;
      try {
        const response = JSON.parse(await RuleProviderStatus.path('/rules', http.RequestMethod.GET)) as Record<string, Object>;
        const rules = response['rules'] as Record<string, Object>[];
        if (Array.isArray(rules)) { references = rules.filter((rule: Record<string, Object>) => rule['type'] === 'RuleSet' && rule['payload'] === name).length; }
      } catch (_) {}
      if (await CoreApi.getControllerSession() !== session) { throw new Error('运行会话已变化'); }
      return { available: true, references, count: value['ruleCount'] as number,
        updatedAt: typeof value['updatedAt'] === 'string' ? value['updatedAt'] as string : '', error: '' };
    } catch (_) { return { available: false, count: 0, updatedAt: '', references: -1, error: '无法读取运行状态' }; }
  }
  static async refresh(name: string): Promise<RuleProviderObservation> {
    try { await RuleProviderStatus.call(name, http.RequestMethod.PUT); }
    catch (error) {
      const current = await RuleProviderStatus.read(name);
      current.error = (error as Error).message;
      return current;
    }
    return RuleProviderStatus.read(name);
  }
}
