/* Shared gate for every UI and scheduler mutation of effective profile state. */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { CoreApi, ConfigApplyResult } from './CoreApi';
import { ProfileStore, ProfileMetaExt } from './ProfileStore';
import { VpnController, VpnStatus } from './VpnController';
import { CoreValidator } from './CoreValidator';
import { MergePreview } from './CoreValidator';
import { EffectiveVersions, EffectiveState, RegionPlan, RegionPreview } from './EffectiveVersions';
import { Settings } from './Settings';

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

  async function publish(context: common.Context, file: string, original: string,
    overlay: string, metadata: string, select: boolean,
    isCurrent?: () => boolean, regionOverride?: RegionPlan | null): Promise<ProfileApplyState> {
    const state = EffectiveVersions.read(context);
    const expected = state?.Current?.ID ?? '';
    const live = select ? await running(context) : false;
    const previous = live ? ProfileStore.getActiveContent(context) : null;
    await CoreValidator.prepareResources(context);
    const saved = state?.Profiles[file];
    const region = regionOverride !== undefined ? regionOverride :
      (saved !== undefined ? EffectiveVersions.regionPlan(context, saved) : null);
    const staged = await EffectiveVersions.stage(context, file, original, overlay, metadata, expected, region);
    let applied = false;
    let published = false;
    try {
      const candidate = fileIo.readTextSync(staged.version.Path);
      if (staged.receipt.length > 0 &&
        await EffectiveVersions.verify(context, staged.version, expected) !== staged.receipt) {
        throw new Error('provider 缓存已变化，请重试');
      }
      if (isCurrent !== undefined && !isCurrent()) { throw new Error('更新已取消'); }
      if (live) { await apply(context, candidate); applied = true; }
      try {
        await EffectiveVersions.commit(context, staged.version, expected, select);
        published = true;
      } catch (e) {
        let after: EffectiveState | null = null;
        try { after = EffectiveVersions.read(context); }
        catch (_) { markUnknown(context); throw new Error('版本发布结果未知，请断开 VPN 后检查'); }
        const actual = select ? after?.Current?.ID : after?.Profiles[file]?.ID;
        if (actual === staged.version.ID) { published = true; }
        else if ((after?.Current?.ID ?? '') !== expected) {
          markUnknown(context);
          throw new Error('版本发布结果未知，请断开 VPN 后检查');
        } else { throw new Error((e as Error).message); }
      }
      return live ? 'applied' : 'saved';
    } catch (e) {
      if (applied && !published && !ProfileStore.isApplyUncertain(context)) {
        await restore(context, previous);
      }
      if (!ProfileStore.isApplyUncertain(context)) {
        try { await EffectiveVersions.discard(context, staged.version, expected); } catch (_) {}
      }
      throw new Error((e as Error).message);
    }
  }

  function metadata(context: common.Context, file: string, edited: boolean = false): string {
    const existing = ProfileStore.getMeta(context)[file];
    const empty: ProfileMetaExt = { origin: '',
      sub: { upload: 0, download: 0, total: 0, expire: 0 }, updatedAt: 0 };
    const entry = existing ?? empty;
    if (edited) {
      const refreshed: ProfileMetaExt = { origin: entry.origin, sub: entry.sub,
        updatedAt: Math.floor(Date.now() / 1000) };
      return JSON.stringify(refreshed);
    }
    return JSON.stringify(entry);
  }

  export async function activate(context: common.Context, file: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('目标配置不存在或读取失败'); }
      return await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true);
    } finally { busy = false; }
  }

  /** Before a disconnected start, migrate old versions through the same gate. */
  export async function ensureActiveSmartPolicy(context: common.Context): Promise<void> {
    enter(context);
    try {
      if (VpnController.status !== VpnStatus.Disconnected) { return; }
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { return; }
      const current = EffectiveVersions.read(context)?.Current;
      if (current !== null && current !== undefined &&
        EffectiveVersions.smartConversion(context, current) === Settings.load(context).smartAutoConvert) {
        return;
      }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前配置不存在或读取失败'); }
      await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true);
    } finally { busy = false; }
  }

  export async function edit(context: common.Context, file: string, content: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const candidate = ProfileStore.prepareContent(content);
      const active = ProfileStore.getActiveFile(context) === file;
      return await publish(context, file, candidate, ProfileStore.getEnabledMerge(context, file),
        metadata(context, file, true), active);
    } finally { busy = false; }
  }

  export async function update(context: common.Context, file: string,
    isCurrent?: () => boolean): Promise<ProfileApplyState> {
    enter(context);
    try {
      const downloaded = await ProfileStore.downloadFromOrigin(context, file);
      if (isCurrent !== undefined && !isCurrent()) { throw new Error('更新已取消'); }
      const active = ProfileStore.getActiveFile(context) === file;
      return await publish(context, file, downloaded.content, ProfileStore.getEnabledMerge(context, file),
        JSON.stringify(downloaded.meta), active, isCurrent);
    } finally { busy = false; }
  }

  export async function rename(context: common.Context, file: string, name: string): Promise<string> {
    enter(context);
    try {
      const state = EffectiveVersions.read(context);
      const target = ProfileStore.renameProfile(context, file, name);
      if (target !== file && state !== null && state.Profiles[file] !== undefined) {
        try { await EffectiveVersions.rename(context, file, target, state.Current?.ID ?? ''); }
        catch (e) {
          try { ProfileStore.renameProfile(context, target, file); }
          catch (_) { markUnknown(context); }
          throw new Error((e as Error).message);
        }
      }
      return target;
    }
    finally { busy = false; }
  }

  export async function remove(context: common.Context, file: string): Promise<void> {
    enter(context);
    try {
      if (ProfileStore.getActiveFile(context) === file && VpnController.status !== VpnStatus.Disconnected) {
        throw new Error('请先断开连接，再删除当前订阅');
      }
      const state = EffectiveVersions.read(context);
      const version = state?.Profiles[file];
      const expected = state?.Current?.ID ?? '';
      if (version !== undefined) { await EffectiveVersions.remove(context, file, expected); }
      try { await ProfileStore.deleteProfile(context, file); }
      catch (e) {
        if (version !== undefined) {
          try { await EffectiveVersions.commit(context, version, state?.Current?.ProfileID === file ? '' : expected,
            state?.Current?.ProfileID === file); }
          catch (_) { markUnknown(context); }
        }
        throw new Error((e as Error).message);
      }
    }
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

  /** Enable or remove a Merge overlay through the same version and core transaction. */
  export async function applyMerge(context: common.Context, file: string,
    overlay: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const result = await publish(context, file, original, overlay,
        metadata(context, file), ProfileStore.getActiveFile(context) === file);
      // The committed version remains authoritative if sidecar metadata cannot be written.
      try { ProfileStore.setMergeEnabled(context, file, overlay); } catch (_) {}
      return result;
    } finally { busy = false; }
  }

  /** Recompile the active original and Merge through the normal version gate. */
  export async function setSmartAutoConvert(context: common.Context,
    enabled: boolean): Promise<ProfileApplyState> {
    enter(context);
    const previous = Settings.load(context).smartAutoConvert;
    try {
      Settings.setSmartAutoConvert(context, enabled);
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { return 'saved'; }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前配置不存在或读取失败'); }
      return await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true);
    } catch (e) {
      try { Settings.setSmartAutoConvert(context, previous); }
      catch (_) { markUnknown(context); }
      throw new Error((e as Error).message);
    } finally { busy = false; }
  }

  export async function previewRegion(context: common.Context, file: string,
    plan: RegionPlan): Promise<RegionPreview> {
    const original = ProfileStore.getProfileContent(context, file);
    if (original === null) { throw new Error('原始配置不存在'); }
    return await EffectiveVersions.previewRegion(context, ProfileStore.prepareContent(original),
      ProfileStore.getEnabledMerge(context, file), plan);
  }

  export async function setRegionPlan(context: common.Context, file: string,
    plan: RegionPlan | null): Promise<ProfileApplyState> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('原始配置不存在'); }
      return await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file),
        ProfileStore.getActiveFile(context) === file, undefined, plan);
    } finally { busy = false; }
  }
}
