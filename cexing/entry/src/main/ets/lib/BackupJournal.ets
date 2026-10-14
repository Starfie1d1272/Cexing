import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import entry from 'libentry.so';

export interface BackupPreferences {
  keepAlive: boolean; ipv6: boolean; logLevel: string; mixedPort: number;
  accessMode: string; accessList: string[]; mainGroup: string; mode: string;
  autoUpdate: boolean; autoUpdateIntervalHours: number; autoRestore: boolean;
  logToFile: boolean; smartAutoConvert: boolean;
}
export interface BackupName { from: string; to: string; }
export interface BackupResult {
  file: string; token: string; profiles: number; names: BackupName[];
  globalChanged: boolean; preferences: BackupPreferences; outcome: string;
}
interface BackupReply { backup?: BackupResult; error?: string; }

export namespace BackupJournal {
  export function exists(context: common.Context): boolean {
    try { return fileIo.accessSync(`${context.filesDir}/profiles/backup-restore.json`); }
    catch (_) { return true; }
  }
  export async function call(context: common.Context, request: string): Promise<BackupResult> {
    const raw = await entry.versionAction(context.filesDir, request);
    const reply = JSON.parse(raw) as BackupReply;
    if (reply.error !== undefined || reply.backup === undefined) { throw new Error('备份操作失败，请重试'); }
    return reply.backup;
  }
  export async function acknowledge(context: common.Context, token: string): Promise<void> {
    await call(context, JSON.stringify({ op: 'backup-ack', backupToken: token }));
    // Publication/preferences are already durable; retained candidates are safe
    // if interrupted here. A subsequent explicit cleanup retries this step.
    try { await call(context, JSON.stringify({ op: 'backup-finish', backupToken: token })); } catch (_) {}
  }
}
