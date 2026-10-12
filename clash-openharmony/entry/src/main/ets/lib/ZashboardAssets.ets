import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ZASHBOARD_MANIFEST_SHA256, ZASHBOARD_VERSION } from './ZashboardPin';

interface AssetEntry { path: string; size: number; sha256: string; }
interface AssetManifest { schema: number; version: string; sourceSha: string; files: AssetEntry[]; }
interface AssetSelection { current: string; previous: string; }
export interface ZashboardDeployment {
  directory: string;
  version: string;
  fallback: boolean;
  error: string;
}

// No engine/controller calls: the configuration transaction adopts the returned directory.
export class ZashboardAssets {
  private static queue: Promise<void> = Promise.resolve();
  private static transactionId: number = 0;

  static safePath(path: string): boolean {
    return typeof path === 'string' && path.length > 0 && path.length < 240 &&
      /^[A-Za-z0-9_./-]+$/.test(path) && path.split('/').every((part: string) =>
      part !== '' && part !== '.' && part !== '..');
  }

  static prepare(context: common.Context): Promise<ZashboardDeployment> {
    const job = ZashboardAssets.queue.then(() => ZashboardAssets.exclusive(context,
      () => ZashboardAssets.install(context)));
    ZashboardAssets.queue = job.then(() => {}, () => {});
    return job;
  }

  static rollback(context: common.Context): Promise<ZashboardDeployment> {
    const job = ZashboardAssets.queue.then(() => ZashboardAssets.exclusive(context, async (): Promise<ZashboardDeployment> => {
      try {
        const root = ZashboardAssets.root(context);
        const selection = ZashboardAssets.selection(root);
        const version = selection.previous;
        await ZashboardAssets.validateVersion(root, version);
        ZashboardAssets.select(root, { current: version, previous: selection.current });
        return { directory: root, version, fallback: true, error: '' };
      } catch (_) {
        return { directory: '', version: '', fallback: false, error: '无法回退面板资源' };
      }
    }));
    ZashboardAssets.queue = job.then(() => {}, () => {});
    return job;
  }

  private static async exclusive(context: common.Context,
    operation: () => Promise<ZashboardDeployment>): Promise<ZashboardDeployment> {
    let lock: fileIo.File | undefined = undefined;
    try {
      const root = ZashboardAssets.root(context);
      lock = fileIo.openSync(`${root}/deployment.lock`,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
      lock.tryLock(true);
      return await operation();
    } catch (_) {
      return { directory: '', version: '', fallback: false, error: '面板资源操作未完成，可稍后重试；VPN 可继续运行' };
    } finally { if (lock !== undefined) { try { fileIo.closeSync(lock); } catch (_) {} } }
  }

  private static root(context: common.Context): string {
    const root = `${context.filesDir}/ui`;
    ZashboardAssets.mkdir(root);
    return root;
  }

  private static mkdir(path: string): void {
    if (!fileIo.accessSync(path)) { fileIo.mkdirSync(path); }
    const stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) { throw new Error('Invalid asset directory'); }
  }

  private static exists(path: string): boolean {
    try { fileIo.lstatSync(path); return true; }
    catch (_) { return false; }
  }

  private static read(path: string, limit: number): Uint8Array {
    const stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isFile() || stat.size > limit) { throw new Error('Invalid asset file'); }
    const bytes = new Uint8Array(stat.size);
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.NOFOLLOW);
    try {
      if (fileIo.readSync(file.fd, bytes.buffer) !== bytes.length) { throw new Error('Short asset read'); }
    } finally { fileIo.closeSync(file); }
    return bytes;
  }

  private static write(path: string, bytes: Uint8Array): void {
    if (fileIo.accessSync(path)) { throw new Error('Asset destination exists'); }
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    try {
      const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      if (fileIo.writeSync(file.fd, buffer) !== bytes.length) { throw new Error('Short asset write'); }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
  }

  private static async hash(bytes: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest = await md.digest();
    return Array.from(digest.data).map((b: number) => b.toString(16).padStart(2, '0')).join('');
  }

  private static parse(bytes: Uint8Array): AssetManifest {
    const manifest = JSON.parse(new util.TextDecoder().decodeToString(bytes)) as AssetManifest;
    if (manifest.schema !== 1 || !/^[a-f0-9]{64}$/.test(manifest.version) ||
      !/^[a-f0-9]{40}$/.test(manifest.sourceSha) || !Array.isArray(manifest.files) ||
      manifest.files.length === 0 || manifest.files.length > 1024) { throw new Error('Invalid manifest'); }
    const names: Set<string> = new Set();
    let total = 0;
    manifest.files.forEach((entry: AssetEntry) => {
      if (!ZashboardAssets.safePath(entry.path) || entry.path === 'manifest.json' ||
        names.has(entry.path) || !Number.isInteger(entry.size) || entry.size < 0 ||
        entry.size > 16 * 1024 * 1024 || !/^[a-f0-9]{64}$/.test(entry.sha256)) {
        throw new Error('Invalid manifest entry');
      }
      names.add(entry.path);
      total += entry.size;
    });
    if (!names.has('index.html') || total > 64 * 1024 * 1024) { throw new Error('Invalid asset set'); }
    return manifest;
  }

  private static entry(selection: AssetSelection): string {
    return `<!doctype html><!--ZASHBOARD_SELECTION:${JSON.stringify(selection)}-->` +
      `<meta charset="utf-8"><title>Zashboard</title>` +
      `<script>location.replace('./versions/${selection.current}/' + location.hash)</script>`;
  }

  private static selection(root: string): AssetSelection {
    if (!fileIo.accessSync(`${root}/index.html`)) { return { current: '', previous: '' }; }
    const data = ZashboardAssets.read(`${root}/index.html`, 1024);
    const text = new util.TextDecoder().decodeToString(data);
    const match = /^<!doctype html><!--ZASHBOARD_SELECTION:(\{[^<>]+\})-->/.exec(text);
    if (match === null) { throw new Error('Invalid selection'); }
    const result = JSON.parse(match[1]) as AssetSelection;
    if (!/^[a-f0-9]{64}$/.test(result.current) ||
      (result.previous !== '' && !/^[a-f0-9]{64}$/.test(result.previous)) ||
      text !== ZashboardAssets.entry(result)) { throw new Error('Invalid selection'); }
    return result;
  }

  private static select(root: string, selection: AssetSelection): void {
    const temp = `${root}/entry-${Date.now()}.tmp`;
    ZashboardAssets.write(temp, new util.TextEncoder().encodeInto(ZashboardAssets.entry(selection)));
    try { fileIo.renameSync(temp, `${root}/index.html`); }
    finally { if (fileIo.accessSync(temp)) { fileIo.unlinkSync(temp); } }
  }

  private static collect(directory: string, prefix: string = ''): string[] {
    let paths: string[] = [];
    fileIo.listFileSync(directory).forEach((name: string) => {
      const path = prefix + name;
      if (!ZashboardAssets.safePath(path)) { throw new Error('Invalid on-disk path'); }
      const stat = fileIo.lstatSync(`${directory}/${name}`);
      if (stat.isSymbolicLink()) { throw new Error('Symlink in assets'); }
      if (stat.isDirectory()) {
        paths = paths.concat(ZashboardAssets.collect(`${directory}/${name}`, `${path}/`));
      } else if (stat.isFile()) { paths.push(path); }
      else { throw new Error('Invalid on-disk entry'); }
    });
    return paths;
  }

  private static async validate(directory: string, manifest: AssetManifest): Promise<void> {
    const actual = ZashboardAssets.collect(directory).sort();
    const expected = manifest.files.map((entry: AssetEntry) => entry.path).concat(['manifest.json']).sort();
    if (actual.join('\n') !== expected.join('\n')) { throw new Error('Unexpected asset set'); }
    for (const entry of manifest.files) {
      const bytes = ZashboardAssets.read(`${directory}/${entry.path}`, entry.size);
      if (bytes.length !== entry.size || await ZashboardAssets.hash(bytes) !== entry.sha256) {
        throw new Error('Asset checksum mismatch');
      }
    }
  }

  private static async validateVersion(root: string, version: string): Promise<void> {
    if (!/^[a-f0-9]{64}$/.test(version)) { throw new Error('Invalid version'); }
    ZashboardAssets.mkdir(`${root}/versions`);
    const directory = `${root}/versions/${version}`;
    const stat = fileIo.lstatSync(directory);
    if (stat.isSymbolicLink() || !stat.isDirectory()) { throw new Error('Invalid version directory'); }
    const bytes = ZashboardAssets.read(`${directory}/manifest.json`, 512 * 1024);
    if (version === ZASHBOARD_VERSION && await ZashboardAssets.hash(bytes) !== ZASHBOARD_MANIFEST_SHA256) {
      throw new Error('Stored manifest checksum mismatch');
    }
    // Older manifests were approved when installed and stored only in app-private storage.
    const manifest = ZashboardAssets.parse(bytes);
    if (manifest.version !== version) { throw new Error('Version mismatch'); }
    if (await ZashboardAssets.hash(new util.TextEncoder().encodeInto(JSON.stringify(manifest.files))) !== version) {
      throw new Error('Manifest identity mismatch');
    }
    await ZashboardAssets.validate(directory, manifest);
  }

  private static async install(context: common.Context): Promise<ZashboardDeployment> {
    let root = '';
    let staging = '';
    let selectionError = '';
    let selection: AssetSelection = { current: '', previous: '' };
    try {
      root = ZashboardAssets.root(context);
      try { selection = ZashboardAssets.selection(root); }
      catch (_) { selectionError = '面板版本记录损坏，已用入包资源重建'; }
      const bytes = await context.resourceManager.getRawFileContent('zashboard/manifest.json');
      if (await ZashboardAssets.hash(bytes) !== ZASHBOARD_MANIFEST_SHA256) { throw new Error('Untrusted manifest'); }
      const manifest = ZashboardAssets.parse(bytes);
      if (manifest.version !== ZASHBOARD_VERSION) { throw new Error('Unexpected bundled version'); }
      const directory = `${root}/versions/${manifest.version}`;
      ZashboardAssets.mkdir(`${root}/versions`);
      let install = true;
      if (ZashboardAssets.exists(directory)) {
        try { await ZashboardAssets.validateVersion(root, manifest.version); install = false; }
        catch (_) { selectionError = '损坏的面板资源已从入包资源重新准备'; }
      }
      if (install) {
        const transaction = `${Date.now()}-${ZashboardAssets.transactionId++}`;
        staging = `${context.filesDir}/zashboard-staging-${transaction}`;
        ZashboardAssets.mkdir(staging);
        for (const entry of manifest.files) {
          const data = await context.resourceManager.getRawFileContent(`zashboard/${entry.path}`);
          if (data.length !== entry.size || await ZashboardAssets.hash(data) !== entry.sha256) {
            throw new Error('Bundled asset checksum mismatch');
          }
          let parent = staging;
          const parts = entry.path.split('/');
          for (let i = 0; i < parts.length - 1; i++) {
            parent += `/${parts[i]}`;
            ZashboardAssets.mkdir(parent);
          }
          ZashboardAssets.write(`${staging}/${entry.path}`, data);
        }
        ZashboardAssets.write(`${staging}/manifest.json`, bytes);
        await ZashboardAssets.validate(staging, manifest);
        let quarantine = '';
        if (ZashboardAssets.exists(directory)) {
          quarantine = `${context.filesDir}/zashboard-quarantine-${manifest.version}-${transaction}`;
          if (ZashboardAssets.exists(quarantine)) { throw new Error('Quarantine destination exists'); }
          fileIo.renameSync(directory, quarantine);
        }
        try { fileIo.renameSync(staging, directory); }
        catch (_) {
          if (quarantine !== '') { fileIo.renameSync(quarantine, directory); }
          throw new Error('Asset publish failed');
        }
        staging = '';
      }
      if (selection.current !== manifest.version) {
        let previous = '';
        if (selection.current !== '') {
          try { await ZashboardAssets.validateVersion(root, selection.current); previous = selection.current; } catch (_) {}
        }
        ZashboardAssets.select(root, { current: manifest.version, previous });
      }
      return { directory: root, version: manifest.version, fallback: false, error: selectionError };
    } catch (_) {
      if (staging !== '') { try { fileIo.rmdirSync(staging); } catch (_) {} }
      for (const version of [selection.current, selection.previous]) {
        try {
          await ZashboardAssets.validateVersion(root, version);
          if (version !== selection.current) { ZashboardAssets.select(root, { current: version, previous: '' }); }
          return { directory: root, version, fallback: true, error: '面板资源校验失败，已保留可用版本' };
        } catch (_) {}
      }
      return { directory: '', version: '', fallback: false, error: '面板资源不可用，可重新准备；VPN 可继续运行' };
    }
  }
}
