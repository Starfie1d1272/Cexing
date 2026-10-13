/* Shared gate for every UI and scheduler mutation of effective profile state. */
import { common } from '@kit.AbilityKit';
import { CoreApi, ConfigApplyResult } from './CoreApi';
import { ProfileStore } from './ProfileStore';
import { VpnController, VpnStatus } from './VpnController';
import { CoreValidator } from './CoreValidator';
import { MergePreview } from './CoreValidator';

export type ProfileApplyState = 'applied' | 'saved';

export namespace ProfileTransactions {
  let busy = false;
  let uncertain = false;

  function enter(context: common.Context): void {
    if (busy) { throw new Error('已有配置操作正在进行，请稍后重试'); }
    if (ProfileStore.isApplyUncertain(context)) { uncertain = true; }
    if (uncertain && VpnController.status === VpnStatus.Disconnected &&
      !ProfileStore.isApplyUncertain(context)) { uncertain = false; }
    if (uncertain) { throw new Error('上次热加载结果未知，请明确断开 VPN 后重试'); }
    busy = true;
  }

  function markUnknown(context: common.Context): void {
    uncertain = true;
    ProfileStore.markApplyUncertain(context);
  }

  async function running(context: common.Context): Promise<boolean> {
    if (VpnController.status === VpnStatus.Disconnected) { return false; }
    if (VpnController.status !== VpnStatus.Connected || !(await CoreApi.isAlive())) {
      markUnknown(context);
      throw new Error('VPN 状态或控制面未确认，请断开 VPN 后重试');
    }
    return true;
  }

  async function apply(context: common.Context, content: string): Promise<void> {
    const result: ConfigApplyResult = await CoreApi.applyConfigText(content);
    if (result === 'unknown') {
      markUnknown(context);
      throw new Error('热加载结果未知，原配置未改；请断开 VPN 后重试');
    }
    if (result === 'rejected') { throw new Error('内核拒绝候选配置，原配置未改'); }
  }

  async function restore(context: common.Context, previous: string | null): Promise<void> {
    if (previous === null || await CoreApi.applyConfigText(previous) !== 'applied') {
      markUnknown(context);
    }
  }

  export async function activate(context: common.Context, file: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const candidate = ProfileStore.getProfileContent(context, file);
      if (candidate === null) { throw new Error('目标配置不存在或读取失败'); }
      ProfileStore.prepareContent(candidate);
      await CoreValidator.validate(context, candidate);
      const oldFile = ProfileStore.getActiveFile(context);
      if (oldFile === file) { return 'saved'; }
      const live = await running(context);
      const previous = live ? ProfileStore.getActiveContent(context) : null;
      if (live) { await apply(context, candidate); }
      try { ProfileStore.setActive(context, file); } catch (e) {
        if (live) { await restore(context, previous); }
        throw new Error('保存当前选择失败');
      }
      return live ? 'applied' : 'saved';
    } finally { busy = false; }
  }

  export async function edit(context: common.Context, file: string, content: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const candidate = ProfileStore.prepareContent(content);
      await CoreValidator.validate(context, candidate);
      const active = ProfileStore.getActiveFile(context) === file;
      const live = active ? await running(context) : false;
      const previous = live ? ProfileStore.getProfileContent(context, file) : null;
      if (live) { await apply(context, candidate); }
      try { ProfileStore.updateProfileContent(context, file, candidate); } catch (e) {
        if (live) { await restore(context, previous); }
        throw new Error('保存配置失败');
      }
      return live ? 'applied' : 'saved';
    } finally { busy = false; }
  }

  export async function update(context: common.Context, file: string,
    isCurrent?: () => boolean): Promise<ProfileApplyState> {
    enter(context);
    try {
      const downloaded = await ProfileStore.downloadFromOrigin(context, file);
      await CoreValidator.validate(context, downloaded.content);
      if (isCurrent !== undefined && !isCurrent()) { throw new Error('更新已取消'); }
      const active = ProfileStore.getActiveFile(context) === file;
      const live = active ? await running(context) : false;
      const previous = live ? ProfileStore.getProfileContent(context, file) : null;
      if (live) { await apply(context, downloaded.content); }
      try { ProfileStore.commitDownloaded(context, file, downloaded); } catch (e) {
        if (live) { await restore(context, previous); }
        throw new Error('保存更新失败');
      }
      return live ? 'applied' : 'saved';
    } finally { busy = false; }
  }

  export function rename(context: common.Context, file: string, name: string): string {
    enter(context);
    try { return ProfileStore.renameProfile(context, file, name); }
    finally { busy = false; }
  }

  export async function remove(context: common.Context, file: string): Promise<void> {
    enter(context);
    try { await ProfileStore.deleteProfile(context, file); }
    finally { busy = false; }
  }

  /** Preview and store an inert per-profile overlay. Production application remains a separate transaction. */
  export async function saveMergeDraft(context: common.Context, file: string,
    overlay: string): Promise<MergePreview> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const preview = await CoreValidator.previewMerge(context, original, overlay);
      ProfileStore.saveMergeDraft(context, file, overlay);
      return preview;
    } finally { busy = false; }
  }
}
