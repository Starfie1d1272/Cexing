/* Offline validation on the existing C++ single worker; never applies config. */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Settings } from './Settings';

export namespace CoreValidator {
  async function ensureGeoData(context: common.Context): Promise<void> {
    const path = `${context.filesDir}/geoip.metadb`;
    if (fileIo.accessSync(path) && fileIo.statSync(path).size > 0) { return; }
    const bytes = await context.resourceManager.getRawFileContent('geodata/geoip.metadb');
    const temp = `${path}.validate-pending`;
    const file = fileIo.openSync(temp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, bytes.buffer); } finally { fileIo.closeSync(file); }
    fileIo.moveFileSync(temp, path);
  }

  export async function validate(context: common.Context, content: string): Promise<void> {
    await ensureGeoData(context);
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, mode: s.mode, logToFile: s.logToFile });
    let code = '';
    try { code = await core.validateOffline(context.filesDir, content, overrides); }
    catch (_) { throw new Error('本机配置校验不可用，原配置未修改'); }
    if (code === '') { return; }
    if (code === 'PROVIDER_UNRESOLVED') {
      throw new Error('配置包含尚未验证的 provider 资源，原配置未修改');
    }
    if (code === 'RESOURCE_MISSING') {
      throw new Error('配置所需的离线资源缺失，原配置未修改');
    }
    throw new Error('配置未通过本机 Mihomo 校验，原配置未修改');
  }
}
