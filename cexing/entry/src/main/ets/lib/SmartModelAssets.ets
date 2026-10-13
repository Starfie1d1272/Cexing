import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { SMART_MODEL_BYTES, SMART_MODEL_RAWFILE, SMART_MODEL_SHA256 } from './SmartModelPin';

export interface SmartModelPreparation {
  state: 'missing' | 'ready' | 'invalid';
  message: string;
}

// Installs only a reviewed packaged model, before Mihomo's first model load.
export class SmartModelAssets {
  private static async digest(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const value = await md.digest();
    return Array.from(value.data).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
  }

  private static async valid(bytes: Uint8Array): Promise<boolean> {
    return bytes.length === SMART_MODEL_BYTES && await SmartModelAssets.digest(bytes) === SMART_MODEL_SHA256;
  }

  private static async installed(path: string): Promise<boolean> {
    if (!fileIo.accessSync(path)) { return false; }
    const stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.size !== SMART_MODEL_BYTES) { return false; }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      const bytes = new Uint8Array(SMART_MODEL_BYTES);
      let offset = 0;
      while (offset < bytes.length) {
        const chunk = new ArrayBuffer(Math.min(1024 * 1024, bytes.length - offset));
        const length = fileIo.readSync(file.fd, chunk);
        if (length <= 0) { return false; }
        bytes.set(new Uint8Array(chunk, 0, length), offset);
        offset += length;
      }
      return SmartModelAssets.valid(bytes);
    } finally { fileIo.closeSync(file); }
  }

  static async prepare(context: common.Context): Promise<SmartModelPreparation> {
    const path = `${context.filesDir}/Model.bin`;
    try {
      if (await SmartModelAssets.installed(path)) {
        return { state: 'ready', message: '已安装经校验的模型' };
      }
    } catch (_) { /* A damaged prior file can be recovered from the bundled model. */ }
    let bundled: Uint8Array;
    try {
      bundled = await context.resourceManager.getRawFileContent(SMART_MODEL_RAWFILE);
    } catch (_) {
      return { state: 'missing', message: '安装包没有内置模型，Smart 使用统计权重' };
    }
    if (!await SmartModelAssets.valid(bundled)) {
      return { state: 'invalid', message: '内置模型身份校验失败，Smart 使用统计权重' };
    }
    try {
      const backup = fileIo.accessSync(`${path}.previous`) ?
        `${path}.invalid-${Date.now()}` : `${path}.previous`;
      if (fileIo.accessSync(backup)) { throw new Error('Model backup destination exists'); }
      const temp = `${path}.bundled.tmp`;
      if (fileIo.accessSync(temp)) {
        const stat = fileIo.lstatSync(temp);
        if (stat.isSymbolicLink() || !stat.isFile()) { throw new Error('Unsafe model staging path'); }
        fileIo.unlinkSync(temp);
      }
      const file = fileIo.openSync(temp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      try {
        const bytes = bundled.buffer.slice(bundled.byteOffset, bundled.byteOffset + bundled.byteLength);
        if (fileIo.writeSync(file.fd, bytes) !== bundled.length) { throw new Error('Short model write'); }
        fileIo.fsyncSync(file.fd);
      } finally { fileIo.closeSync(file); }
      if (fileIo.accessSync(path)) { fileIo.renameSync(path, backup); }
      try { fileIo.renameSync(temp, path); }
      catch (_) {
        if (fileIo.accessSync(backup) && !fileIo.accessSync(path)) { fileIo.renameSync(backup, path); }
        throw new Error('Failed to install bundled model');
      }
      return { state: 'ready', message: '已安装经校验的内置模型' };
    } catch (_) {
      return { state: 'invalid', message: '内置模型安装失败，Smart 使用统计权重' };
    }
  }
}
