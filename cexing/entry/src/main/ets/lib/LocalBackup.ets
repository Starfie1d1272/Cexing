import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BackupJournal, BackupResult } from './BackupJournal';
import { BoundedFileReader } from './BoundedFileReader';
import { Settings } from './Settings';
import { EffectiveVersions } from './EffectiveVersions';
import { ProfileTransactions } from './ProfileTransactions';
import { VpnController, VpnStatus } from './VpnController';

export namespace LocalBackup {
  const LIMIT: number = 64 * 1024 * 1024;
  function check(current: () => boolean): void {
    if (!current()) { throw new Error('操作已取消'); }
  }
  function expected(context: common.Context): string { return EffectiveVersions.read(context)?.Current?.ID ?? ''; }
  async function remove(path: string): Promise<void> { try { await fileIo.unlink(path); } catch (_) {} }

  /** Caller obtains explicit sensitive-data consent and a system picker destination. */
  export async function exportTo(context: common.Context, uri: string, current: () => boolean): Promise<void> {
    await ProfileTransactions.backupWork(context, false, async () => {
      check(current);
      const result = await BackupJournal.call(context, JSON.stringify({ op: 'backup-export',
        expected: expected(context), backupPreferences: Settings.portable(Settings.load(context)) }));
      if (!/^backup-export-[A-Za-z0-9_-]+\.json$/.test(result.file)) { throw new Error('备份资料无效'); }
      const path = `${context.filesDir}/backups/${result.file}`;
      try {
        check(current);
        const data = await BoundedFileReader.bytes(path, LIMIT, current);
        await BoundedFileReader.write(uri, data, current);
      } finally { await remove(path); }
    });
  }

  export async function preview(context: common.Context, uri: string,
    current: () => boolean): Promise<BackupResult> {
    let preview: BackupResult | null = null;
    await ProfileTransactions.backupWork(context, false, async () => {
      check(current);
      const data = await BoundedFileReader.bytes(uri, LIMIT, current);
      const directory = `${context.filesDir}/backups`;
      if (!fileIo.accessSync(directory)) { await fileIo.mkdir(directory); }
      const file = `backup-import-${util.generateRandomUUID(true)}.json`;
      const path = `${directory}/${file}`;
      try {
        await BoundedFileReader.write(path, data, current);
        check(current);
        preview = await BackupJournal.call(context, JSON.stringify({ op: 'backup-prepare', expected: expected(context),
          backupFile: file, backupAllowLan: Settings.load(context).allowLan }));
        if (!current()) {
          await BackupJournal.call(context, JSON.stringify({ op: 'backup-finish', backupToken: preview.token }));
          throw new Error('操作已取消');
        }
      } finally { await remove(path); }
    });
    if (preview === null) { throw new Error('备份资料无效'); }
    return preview;
  }

  export async function cancel(context: common.Context, preview: BackupResult): Promise<void> {
    await BackupJournal.call(context, JSON.stringify({ op: 'backup-finish', backupToken: preview.token }));
  }

  /** The confirmation describes settings changes and, when needed, interruption. */
  export async function restore(context: common.UIAbilityContext, preview: BackupResult,
    current: () => boolean, confirmedInterruption: boolean): Promise<void> {
    check(current);
    if (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop()) {
      if (!confirmedInterruption) { throw new Error('需要确认断开 VPN'); }
      if (!(await VpnController.stop(context, false))) { throw new Error('断开未确认，请重试'); }
    }
    check(current);
    await ProfileTransactions.backupWork(context, true, async () => {
      check(current);
      await Settings.restoreBackup(context, preview.preferences, async (old) => {
        check(current);
        await BackupJournal.call(context, JSON.stringify({ op: 'backup-arm', backupToken: preview.token,
          backupOwner: util.generateRandomUUID(true), backupAllowLan: Settings.load(context).allowLan,
          backupPreferences: old }));
      }, async () => {
        check(current);
        return (await BackupJournal.call(context, JSON.stringify({ op: 'backup-commit', backupToken: preview.token }))).outcome;
      }, async () => {
        return (await BackupJournal.call(context, JSON.stringify({ op: 'backup-status', backupToken: preview.token }))).outcome;
      }, async () => { await BackupJournal.acknowledge(context, preview.token); });
    });
  }
}
