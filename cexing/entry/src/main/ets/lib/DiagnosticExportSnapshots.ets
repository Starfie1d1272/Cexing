import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface DiagnosticExportSnapshot { readonly path: string; }

// The service cache is mutable. Each user operation owns a separate captured
// JSON file; neither a VPN notification nor a new page may overwrite it.
export class DiagnosticExportSnapshots {
  private static active: Set<string> = new Set<string>();
  private static readonly retainMs: number = 24 * 60 * 60 * 1000;
  private static readonly names: RegExp = /^support-([0-9]{13})-[a-f0-9-]{36}\.json$/;

  private static directory(context: common.Context): string {
    return `${context.cacheDir}/diagnostic-export-snapshots`;
  }

  private static collect(context: common.Context): string[] {
    const directory = DiagnosticExportSnapshots.directory(context);
    if (!fileIo.accessSync(directory)) { fileIo.mkdirSync(directory); }
    for (const name of fileIo.listFileSync(directory)) {
      const match = DiagnosticExportSnapshots.names.exec(name);
      const path = `${directory}/${name}`;
      // Handoffs retain a grace period. Known live picker/share leases are
      // never collected, even when the page disappeared or the clock moved.
      if (match !== null && !DiagnosticExportSnapshots.active.has(path) &&
        Date.now() - Number(match[1]) > DiagnosticExportSnapshots.retainMs) {
        try { fileIo.unlinkSync(path); } catch (_) {}
      }
    }
    return fileIo.listFileSync(directory).filter((name: string) => DiagnosticExportSnapshots.names.test(name));
  }

  static create(context: common.Context, json: string, share: boolean): DiagnosticExportSnapshot {
    const bytes = new util.TextEncoder().encodeInto(json);
    if (bytes.byteLength > 1024 * 1024) { throw new Error('snapshot_size'); }
    const names = DiagnosticExportSnapshots.collect(context);
    // Reserve four slots for saves when recent share handoffs remain retained.
    // Admission fails instead of deleting a pending or recently shared file.
    if (DiagnosticExportSnapshots.active.size >= 8 || names.length >= (share ? 16 : 20)) {
      throw new Error('snapshot_capacity');
    }
    const directory = DiagnosticExportSnapshots.directory(context);
    let path = '';
    for (let attempt = 0; attempt < 4; attempt++) {
      const candidate = `${directory}/support-${Date.now()}-${util.generateRandomUUID().toLowerCase()}.json`;
      if (!fileIo.accessSync(candidate)) { path = candidate; break; }
    }
    if (path === '') { throw new Error('snapshot_name'); }
    // This module is the sole writer of this private directory. Creation is
    // synchronous before any UI await, and existing names are never reused.
    const file = fileIo.openSync(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.NOFOLLOW);
    try {
      let written = 0;
      while (written < bytes.byteLength) {
        const buffer = bytes.buffer as ArrayBuffer;
        const chunk = buffer.slice(bytes.byteOffset + written, bytes.byteOffset + Math.min(bytes.byteLength, written + 65536));
        const length = fileIo.writeSync(file.fd, chunk);
        if (length <= 0 || length > chunk.byteLength) { throw new Error('snapshot_write'); }
        written += length;
      }
      fileIo.fsyncSync(file.fd);
    } catch (error) {
      try { fileIo.unlinkSync(path); } catch (_) {}
      throw error as Error;
    } finally { fileIo.closeSync(file); }
    DiagnosticExportSnapshots.active.add(path);
    return { path: path };
  }

  static release(snapshot: DiagnosticExportSnapshot, retain: boolean): void {
    // Idempotent, operation-scoped release: a late A callback cannot release B.
    if (!DiagnosticExportSnapshots.active.delete(snapshot.path)) { return; }
    if (!retain) { try { fileIo.unlinkSync(snapshot.path); } catch (_) {} }
  }
}
