import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/** An inert draft; the enabled global baseline lives in the atomic version state. */
export namespace GlobalMergeDraft {
  function path(context: common.Context): string { return `${context.filesDir}/global-merge-draft.yaml`; }

  export function read(context: common.Context): string | null {
    const p = path(context);
    return fileIo.accessSync(p) ? fileIo.readTextSync(p) : null;
  }

  export function save(context: common.Context, content: string): void {
    const p = path(context);
    const temp = `${p}.pending`;
    const file = fileIo.openSync(temp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, content); } finally { fileIo.closeSync(file); }
    try { fileIo.moveFileSync(temp, p); } catch (_) {
      try { fileIo.unlinkSync(temp); } catch (_) {}
      throw new Error('全局覆写草稿保存失败');
    }
  }
}
