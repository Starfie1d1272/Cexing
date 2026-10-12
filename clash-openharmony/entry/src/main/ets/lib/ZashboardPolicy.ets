import { ZashboardAssets } from './ZashboardAssets';

export class ZashboardPolicy {
  static validSession(authenticated: boolean, url: string, version: string): boolean {
    const match = /^http:\/\/127\.0\.0\.1:([0-9]{1,5})\/ui\/$/.exec(url);
    return authenticated && match !== null && Number(match[1]) > 0 &&
      Number(match[1]) <= 65535 && /^[a-f0-9]{64}$/.test(version);
  }

  static navigation(url: string, version: string, target: string): boolean {
    if (!target.startsWith(url)) { return false; }
    const prefix = `${url}versions/${version}/`;
    let suffix = target.substring(url.length);
    if (target.startsWith(prefix)) { suffix = target.substring(prefix.length); }
    return suffix === '' || suffix === '#' || suffix === '#/' || (suffix.startsWith('#/') &&
      ZashboardAssets.safePath(suffix.substring(2)));
  }

  static request(url: string, target: string): boolean {
    const origin = url.substring(0, url.length - 4);
    let suffix = '';
    if (target.startsWith(`${origin}/`)) { suffix = target.substring(origin.length); }
    else {
      const wsOrigin = origin.replace(/^http:/, 'ws:');
      if (!target.startsWith(`${wsOrigin}/`)) { return false; }
      suffix = target.substring(wsOrigin.length);
    }
    try {
      const path = decodeURIComponent(suffix.split('?')[0]);
      return !/^\/(restart|upgrade)(\/|$)/.test(path) &&
        !path.split('/').some((part: string) => part === '.' || part === '..');
    } catch (_) { return false; }
  }
}
