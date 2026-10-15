import { ProxyInfo } from './CoreApi';

export namespace LiveViewStrategy {
  export function groups(proxies: Record<string, ProxyInfo>): string[] {
    return Object.keys(proxies).filter((name: string) =>
      ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Smart'].includes(proxies[name].type));
  }

  /** Display preference only. Never infer an exit from now or write a selection. */
  export function choose(proxies: Record<string, ProxyInfo>, requested: string): string {
    const available = groups(proxies);
    if (requested.length > 0) { return available.includes(requested) ? requested : ''; }
    return available.find((name: string) => name !== 'GLOBAL') ?? '';
  }

  export function mode(value: string): string {
    return value === 'rule' ? '规则模式' : (value === 'global' ? '全局模式' :
      (value === 'direct' ? '直连模式' : ''));
  }
}
