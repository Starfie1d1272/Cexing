import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export type GeoDataState = 'ready' | 'missing' | 'invalid';
export interface ResourceCancellation { cancelled: boolean; }

// The trusted package is produced by prepare-geodata.py after upstream size/hash
// verification. Recovery is offline; never accepts a URL or a user supplied path.
export class GeoDataAssets {
  private static queue: Promise<void> = Promise.resolve();
  private static sequence: number = 0;
  private static readonly limit: number = 64 * 1024 * 1024;

  private static async hash(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const result = await md.digest();
    return Array.from(result.data).map((b: number) => b.toString(16).padStart(2, '0')).join('');
  }

  private static read(path: string): Uint8Array {
    const stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > GeoDataAssets.limit) {
      throw new Error('Invalid GeoData file');
    }
    const bytes = new Uint8Array(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const chunk = new ArrayBuffer(Math.min(1024 * 1024, bytes.length - offset));
        const length = fileIo.readSync(file.fd, chunk);
        if (length <= 0) { throw new Error('Short GeoData read'); }
        bytes.set(new Uint8Array(chunk, 0, length), offset);
        offset += length;
      }
    } finally { fileIo.closeSync(file); }
    return bytes;
  }

  private static async bundled(context: common.Context): Promise<Uint8Array> {
    const bytes = await context.resourceManager.getRawFileContent('geodata/geoip.metadb');
    if (bytes.length === 0 || bytes.length > GeoDataAssets.limit) { throw new Error('Invalid packaged GeoData'); }
    return bytes;
  }

  static async inspect(context: common.Context): Promise<GeoDataState> {
    const path = `${context.filesDir}/geoip.metadb`;
    try {
      if (!fileIo.accessSync(path)) { return 'missing'; }
      const installed = GeoDataAssets.read(path);
      const bundled = await GeoDataAssets.bundled(context);
      return installed.length === bundled.length &&
        await GeoDataAssets.hash(installed) === await GeoDataAssets.hash(bundled) ? 'ready' : 'invalid';
    } catch (_) { return 'invalid'; }
  }

  static restore(context: common.Context, cancellation: ResourceCancellation,
    canRestore: () => boolean = () => true): Promise<void> {
    const job = GeoDataAssets.queue.then(() => GeoDataAssets.install(context, cancellation, canRestore));
    GeoDataAssets.queue = job.then(() => {}, () => {});
    return job;
  }

  private static async install(context: common.Context, cancellation: ResourceCancellation,
    canRestore: () => boolean): Promise<void> {
    const path = `${context.filesDir}/geoip.metadb`;
    const staging = `${path}.restore-${Date.now()}-${GeoDataAssets.sequence++}`;
    let lock: fileIo.File | undefined = undefined;
    try {
      lock = fileIo.openSync(`${context.filesDir}/geodata-recovery.lock`,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      lock.tryLock(true);
      if (cancellation.cancelled) { throw new Error('已取消'); }
      if (!canRestore()) { throw new Error('请先断开连接'); }
      const bytes = await GeoDataAssets.bundled(context);
      const digest = await GeoDataAssets.hash(bytes);
      if (fileIo.accessSync(staging)) { throw new Error('GeoData staging exists'); }
      const file = fileIo.openSync(staging,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      try {
        const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        if (fileIo.writeSync(file.fd, buffer) !== bytes.length) { throw new Error('Short GeoData write'); }
        fileIo.fsyncSync(file.fd);
      } finally { fileIo.closeSync(file); }
      if (await GeoDataAssets.hash(GeoDataAssets.read(staging)) !== digest) {
        throw new Error('GeoData staged checksum mismatch');
      }
      if (cancellation.cancelled) { throw new Error('已取消'); }
      if (!canRestore()) { throw new Error('请先断开连接'); }
      // Rename is the commit point. All checks precede it, so failed writes and
      // cancellation preserve the previous file without a delete/rename gap.
      if (fileIo.accessSync(path)) {
        const stat = fileIo.lstatSync(path);
        if (stat.isSymbolicLink() || !stat.isFile()) { throw new Error('Unsafe GeoData destination'); }
      }
      fileIo.renameSync(staging, path);
    } finally {
      try { if (fileIo.accessSync(staging)) { fileIo.unlinkSync(staging); } } catch (_) {}
      if (lock !== undefined) { try { fileIo.closeSync(lock); } catch (_) {} }
    }
  }
}
