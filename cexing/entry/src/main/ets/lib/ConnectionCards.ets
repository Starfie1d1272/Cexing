import { common, shortcutManager } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { Logger } from './Logger';

export interface ConnectionReport {
  label: string;
  reportedAt: string;
  verifiedAt: number;
  stopUnknown: boolean;
  action: string;
}

// The extension has no VPN/runtime ownership. These files contain no profile data.
export namespace ConnectionCards {
  const REPORT = 'desktop_connection_report.json';
  const IDS = 'desktop_connection_forms.json';
  let desiredAction: string = '';
  let appliedAction: string = '';
  let syncingShortcuts: boolean = false;

  // Serialize visibility changes so an older callback cannot restore both entries.
  async function syncShortcuts(action: string): Promise<void> {
    desiredAction = action;
    if (syncingShortcuts) { return; }
    syncingShortcuts = true;
    try {
      while (appliedAction !== desiredAction) {
        const next = desiredAction;
        appliedAction = '';
        await shortcutManager.setShortcutVisibleForSelf(next === 'connect' ? 'disconnect' : 'connect', false);
        if (next !== desiredAction) { continue; }
        await shortcutManager.setShortcutVisibleForSelf(next, true);
        appliedAction = next;
      }
    } catch (_) { Logger.warn('shortcut', 'connection action update unavailable'); }
    finally { syncingShortcuts = false; }
  }

  function actionFor(label: string, stopUnknown: boolean): string {
    return stopUnknown || label === '已连接' || label === '连接中' || label === '断开中' ? 'disconnect' : 'connect';
  }

  function write(ctx: common.Context, name: string, data: string): void {
    const path = `${ctx.filesDir}/${name}`;
    const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, data); } finally { fileIo.closeSync(file); }
    fileIo.renameSync(path + '.tmp', path);
  }

  export function read(ctx: common.Context): ConnectionReport {
    try {
      const value = JSON.parse(fileIo.readTextSync(`${ctx.filesDir}/${REPORT}`)) as ConnectionReport;
      if (typeof value.label === 'string' && typeof value.reportedAt === 'string' &&
        typeof value.stopUnknown === 'boolean') {
        const verifiedAt = typeof value.verifiedAt === 'number' && Number.isFinite(value.verifiedAt) &&
          value.verifiedAt > 0 ? value.verifiedAt : 0;
        return { label: value.label, reportedAt: value.reportedAt, verifiedAt,
          stopUnknown: value.stopUnknown, action: actionFor(value.label, value.stopUnknown) };
      }
    } catch (_) {}
    return { label: '未连接', reportedAt: '', verifiedAt: 0, stopUnknown: false, action: 'connect' };
  }

  function ids(ctx: common.Context): string[] {
    try {
      const values = JSON.parse(fileIo.readTextSync(`${ctx.filesDir}/${IDS}`)) as string[];
      return Array.isArray(values) ? values.filter((id: string) => typeof id === 'string' && /^[0-9]+$/.test(id)) : [];
    }
    catch (_) { return []; }
  }

  export function add(ctx: common.Context, id: string): void {
    const current = ids(ctx);
    if (/^[0-9]+$/.test(id) && current.indexOf(id) < 0) {
      current.push(id);
      try { write(ctx, IDS, JSON.stringify(current)); }
      catch (_) { Logger.warn('card', 'form registration unavailable'); }
    }
  }

  export function remove(ctx: common.Context, id: string): void {
    try { write(ctx, IDS, JSON.stringify(ids(ctx).filter((value: string) => value !== id))); }
    catch (_) { Logger.warn('card', 'form removal unavailable'); }
  }

  export function update(ctx: common.Context, id: string, report?: ConnectionReport): void {
    formProvider.updateForm(id, formBindingData.createFormBindingData(report ?? read(ctx)))
      .catch(() => Logger.warn('card', 'form update unavailable'));
  }

  export function publish(ctx: common.Context, label: string, stopUnknown: boolean): void {
    const report: ConnectionReport = { label, reportedAt: new Date().toLocaleString(), verifiedAt: Date.now(), stopUnknown,
      action: actionFor(label, stopUnknown) };
    syncShortcuts(report.action);
    try {
      write(ctx, REPORT, JSON.stringify(report));
      for (const id of ids(ctx)) { update(ctx, id, report); }
    } catch (_) { Logger.warn('card', 'connection report unavailable'); }
  }
}
