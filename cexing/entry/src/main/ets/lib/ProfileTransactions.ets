/* Shared gate for every UI and scheduler mutation of effective profile state. */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { EditIntent } from './ConfigEditor';
import { fileIo } from '@kit.CoreFileKit';
import { CoreApi, ConfigApplyResult } from './CoreApi';
import { ProfileStore, ProfileMetaExt } from './ProfileStore';
import { VpnController, VpnStatus } from './VpnController';
import { CoreValidator } from './CoreValidator';
import { MergePreview } from './CoreValidator';
import { EffectiveVersions, EffectiveState, RegionPlan, RegionPreview, ProfileStorageReport } from './EffectiveVersions';
import { ProfileRegionChoices } from './ProfileRegionChoices';
import { Settings } from './Settings';

export type ProfileApplyState = 'applied' | 'saved';

export interface EditorSourceCandidate { original: string; metadata: ProfileMetaExt; }

export interface EditTicket {
  file: string;
  profileIdentity: string;
  profileVersion: string;
  activeVersion: string;
  activeFile: string;
  draftRevision: string;
}

export interface PreviousVersionPreview {
  currentId: string;
  previousId: string;
  currentProfile: string;
  restoredProfile: string;
  globalMergeChanged: boolean;
  smartPolicyChanged: boolean;
}

interface SmartPublication { committed: boolean; unresolved: boolean; expected?: string; }

export namespace ProfileTransactions {
  let busy = false;
  let uncertain = false;
  let releaseConfiguration: (() => void) | null = null;

  function leave(): void { releaseConfiguration?.(); releaseConfiguration = null; busy = false; notifyIdle(); }

  export function isBusy(): boolean { return busy; }

  let idleListeners: Array<() => void> = [];
  /** Settlement only: no success claim. Unsubscribe when the observer leaves. */
  export function onIdle(listener: () => void): () => void {
    idleListeners.push(listener);
    return (): void => { idleListeners = idleListeners.filter((entry: () => void) => entry !== listener); };
  }

  function notifyIdle(): void {
    const listeners = idleListeners.slice();
    for (const listener of listeners) {
      try { listener(); } catch (_) { /* An observer cannot change the transaction result. */ }
    }
  }


  function enter(context: common.Context): void {
    if (busy) { throw new Error('已有配置操作正在进行，请稍后重试'); }
    if (ProfileStore.isApplyUncertain(context)) { uncertain = true; }
    if (uncertain && VpnController.status === VpnStatus.Disconnected &&
      !ProfileStore.isApplyUncertain(context)) { uncertain = false; }
    if (uncertain) { throw new Error('应用未确认，请重连恢复'); }
    busy = true;
    releaseConfiguration = VpnController.holdConfiguration();
  }

  /** Reuse the publication gate for local backup snapshots and offline restore. */
  export async function backupWork(context: common.Context, offline: boolean,
    action: () => Promise<void>): Promise<void> {
    enter(context);
    try {
      Settings.load(context); await Settings.idle();
      if (offline && (VpnController.status !== VpnStatus.Disconnected || VpnController.needsStop())) { throw new Error('请先确认断开 VPN'); }
      await action();
    } finally { leave(); }
  }

  export async function refreshStorage(context: common.Context): Promise<ProfileStorageReport> {
    enter(context);
    try { return await EffectiveVersions.collect(context, EffectiveVersions.read(context)?.Current?.ID ?? ''); }
    finally { leave(); }
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

  async function apply(context: common.Context, content: string, session: string): Promise<void> {
    let result: ConfigApplyResult = 'unknown';
    try { result = await CoreApi.applyConfigText(content, session); } catch (_) {}
    if (result === 'unknown') {
      markUnknown(context);
      throw new Error('应用未确认，请重连恢复');
    }
    if (result === 'rejected') { throw new Error('内核拒绝候选配置，原配置未改'); }
  }

  async function restore(context: common.Context, previous: string | null, session: string,
    sameSession: () => Promise<boolean>): Promise<void> {
    try {
      if (previous !== null && await sameSession()) {
        const result = await CoreApi.applyConfigText(previous, session);
        if (result === 'applied' && await sameSession()) { return; }
      }
    } catch (_) {}
    markUnknown(context);
  }

  async function rollbackSmartPreference(context: common.Context, previous: boolean,
    publication: SmartPublication): Promise<void> {
    // Runtime uncertainty and pointer publication are different facts. Only a
    // confirmed unpublished pointer permits restoring the old preference.
    if (publication.committed || publication.unresolved) { return; }
    if (publication.expected !== undefined) {
      try {
        if ((EffectiveVersions.read(context)?.Current?.ID ?? '') !== publication.expected) {
          markUnknown(context); return;
        }
      } catch (_) { markUnknown(context); return; }
    }
    try { await Settings.setSmartAutoConvert(context, previous); }
    catch (_) { markUnknown(context); }
  }

  async function publish(context: common.Context, file: string, original: string,
    overlay: string, metadata: string, select: boolean,
    isCurrent?: (published?: boolean) => boolean, regionOverride?: RegionPlan | null,
    globalOverride?: string, intentOverride?: EditIntent | null, expectedDigest?: string,
    guard?: (published: boolean) => Promise<void>, smartPublication?: SmartPublication): Promise<ProfileApplyState> {
    const epoch = VpnController.configurationEpoch();
    Settings.load(context); await Settings.idle();
    const state = EffectiveVersions.read(context);
    const expected = state?.Current?.ID ?? '';
    if (smartPublication !== undefined) { smartPublication.expected = expected; }
    const live = select ? await running(context) : false;
    const session = live ? await CoreApi.getControllerSession() : null;
    if (live && (session === null || epoch !== VpnController.configurationEpoch())) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
    const sameSession = async (): Promise<boolean> => {
      if (!live) { return true; }
      if (VpnController.status !== VpnStatus.Connected || epoch !== VpnController.configurationEpoch()) { return false; }
      let actual: string | null = null;
      try { actual = await CoreApi.getControllerSession(); } catch (_) { return false; }
      return actual === session && VpnController.status === VpnStatus.Connected && epoch === VpnController.configurationEpoch();
    };
    const current = (published: boolean = false): boolean => { try { return isCurrent === undefined || isCurrent(published); } catch (_) { return false; } };
    const previous = live ? ProfileStore.getActiveContent(context) : null;
    await CoreValidator.prepareResources(context);
    const saved = state?.Profiles[file];
    const intent = intentOverride !== undefined ? intentOverride :
      (saved !== undefined ? EffectiveVersions.editIntent(context, saved) : null);
    const region = regionOverride !== undefined ? regionOverride :
      (saved !== undefined ? EffectiveVersions.regionPlan(context, saved) : null);
    const selector = ProfileRegionChoices.selector(intent, region);
    const transition = await ProfileRegionChoices.prepare(context, file, saved, selector, live);
    const staged = await EffectiveVersions.stage(context, file, original, overlay, metadata, expected, region, globalOverride, intent, transition.state);
    let applied = false;
    let published = false;
    try {
      if (expectedDigest !== undefined && staged.digest !== expectedDigest) { throw new Error('预览已变化，请重新预览'); }
      const candidate = fileIo.readTextSync(staged.version.Path);
      if (staged.receipt.length > 0 &&
        await EffectiveVersions.verify(context, staged.version, expected, globalOverride) !== staged.receipt) {
        throw new Error('provider 缓存已变化，请重试');
      }
      if (guard !== undefined) { await guard(false); }
      if (!current()) { throw new Error('更新已取消'); }
      if (!(await sameSession())) { throw new Error('连接已变化，请重试'); }
      if (live) {
        await apply(context, candidate, session ?? '');
        applied = true;
        if (!(await sameSession())) {
          markUnknown(context);
          throw new Error('应用未确认，请重连恢复');
        }
      }
      if (guard !== undefined) { await guard(false); }
      if (!current()) { throw new Error('更新已取消'); }
      if (!(await sameSession())) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      if (smartPublication !== undefined) { smartPublication.unresolved = true; }
      try {
        await EffectiveVersions.commit(context, staged.version, expected, select, globalOverride);
        published = true;
        if (smartPublication !== undefined) { smartPublication.committed = true; smartPublication.unresolved = false; }
      } catch (e) {
        let after: EffectiveState | null = null;
        try { after = EffectiveVersions.read(context); }
        catch (_) { markUnknown(context); throw new Error('版本发布结果未知，请断开 VPN 后检查'); }
        const actual = select ? after?.Current?.ID : after?.Profiles[file]?.ID;
        if (actual === staged.version.ID) {
          published = true;
          if (smartPublication !== undefined) { smartPublication.committed = true; smartPublication.unresolved = false; }
        }
        else if ((after?.Current?.ID ?? '') !== expected) {
          markUnknown(context);
          throw new Error('版本发布结果未知，请断开 VPN 后检查');
        } else {
          if (smartPublication !== undefined) { smartPublication.unresolved = false; }
          throw new Error((e as Error).message);
        }
      }
      if (guard !== undefined) {
        try { await guard(true); } catch (_) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      }
      if (!(await sameSession()) || !current(true)) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      // Publication is already durable; GC cannot turn success into a false
      // rollback. Its bounded status is available only in advanced storage UI.
      try { await EffectiveVersions.collect(context, select ? staged.version.ID : expected); } catch (_) {}
      if (guard !== undefined) {
        try { await guard(true); } catch (_) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      }
      if (!(await sameSession()) || !current(true)) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      if (live) {
        await ProfileRegionChoices.committed(context, file, staged.version, transition, selector,
          () => VpnController.status === VpnStatus.Connected && epoch === VpnController.configurationEpoch() &&
            EffectiveVersions.read(context)?.Current?.ID === staged.version.ID && current(true), sameSession);
        if (!(await sameSession()) || !current(true)) { markUnknown(context); throw new Error('应用未确认，请重连恢复'); }
      }
      return live ? 'applied' : 'saved';
    } catch (e) {
      if (applied && !published && !uncertain && !ProfileStore.isApplyUncertain(context)) {
        if (await sameSession()) { await restore(context, previous, session ?? '', sameSession); }
        else { markUnknown(context); }
      }
      if (!published && !uncertain && !ProfileStore.isApplyUncertain(context)) {
        try { await EffectiveVersions.discard(context, staged.version, expected); } catch (_) {}
      }
      throw new Error(ProfileStore.isApplyUncertain(context) ? '应用未确认，请重连恢复' : (e as Error).message);
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

  /** Capture before asynchronous editor reads. Never substitute a fresh ticket at completion. */
  export function editTicket(context: common.Context, file: string): EditTicket {
    const state = EffectiveVersions.read(context);
    return { file: file, profileIdentity: ProfileStore.updateState(context, file).id, profileVersion: state?.Profiles[file]?.ID ?? '',
      activeVersion: state?.Current?.ID ?? '', activeFile: ProfileStore.getActiveFile(context),
      draftRevision: ProfileStore.readEditDraft(context, file).revision };
  }

  function checkEditTicket(context: common.Context, ticket: EditTicket, published: boolean = false): void {
    const current = editTicket(context, ticket.file);
    if (current.profileIdentity !== ticket.profileIdentity || (!published && (current.profileVersion !== ticket.profileVersion || current.activeVersion !== ticket.activeVersion)) ||
      current.activeFile !== ticket.activeFile || current.draftRevision !== ticket.draftRevision) {
      throw new Error('配置或草稿已变化，请重新打开');
    }
  }

  export async function saveEditDraft(context: common.Context, ticket: EditTicket,
    intent: EditIntent | null, guard?: () => Promise<void>): Promise<string> {
    enter(context);
    try {
      checkEditTicket(context, ticket);
      const revision = util.generateRandomUUID(true);
      const candidate = intent === null ? null : JSON.parse(JSON.stringify(intent)) as EditIntent;
      if (candidate !== null) { candidate.revision = revision; }
      await EffectiveVersions.checkIntent(context, candidate, ticket.activeVersion);
      if (guard !== undefined) { await guard(); }
      checkEditTicket(context, ticket);
      ProfileStore.saveEditDraft(context, ticket.file, { revision: revision, intent: candidate }, ticket.draftRevision);
      return revision;
    } finally { leave(); }
  }

  export async function previewEditDraft(context: common.Context, ticket: EditTicket, source?: EditorSourceCandidate): Promise<MergePreview> {
    enter(context);
    try {
      checkEditTicket(context, ticket);
      const original = source?.original ?? ProfileStore.getProfileContent(context, ticket.file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const version = EffectiveVersions.read(context)?.Profiles[ticket.file];
      const region = version !== undefined ? EffectiveVersions.regionPlan(context, version) : null;
      const intent = ProfileStore.readEditDraft(context, ticket.file).intent;
      await CoreValidator.prepareResources(context);
      const preview = await EffectiveVersions.previewMerge(context, original,
        ProfileStore.getEnabledMerge(context, ticket.file), region, undefined, intent);
      checkEditTicket(context, ticket);
      return preview;
    } finally { leave(); }
  }

  export async function applyEditDraft(context: common.Context, ticket: EditTicket,
    expectedDigest?: string, guard?: (published: boolean) => Promise<void>,
    source?: EditorSourceCandidate): Promise<ProfileApplyState> {
    enter(context);
    try {
      checkEditTicket(context, ticket);
      const original = source?.original ?? ProfileStore.getProfileContent(context, ticket.file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const intent = ProfileStore.readEditDraft(context, ticket.file).intent;
      return await publish(context, ticket.file, original, ProfileStore.getEnabledMerge(context, ticket.file),
        source !== undefined ? JSON.stringify(source.metadata) : metadata(context, ticket.file), ProfileStore.getActiveFile(context) === ticket.file,
        (published?: boolean) => { checkEditTicket(context, ticket, published === true); return true; }, undefined, undefined, intent, expectedDigest, guard);
    } finally { leave(); }
  }

  /** The UI confirms this exact pair, then passes both IDs to restorePrevious.
   * File names and change flags describe the effect without exposing config bytes.
   */
  export function previewPrevious(context: common.Context): PreviousVersionPreview {
    enter(context);
    try {
      const state = EffectiveVersions.read(context);
      if (state?.Current === null || state?.Current === undefined ||
        state.Previous === null || state.Previous === undefined) { throw new Error('没有可恢复的版本'); }
      return { currentId: state.Current.ID, previousId: state.Previous.ID,
        currentProfile: state.Current.ProfileID, restoredProfile: state.Previous.ProfileID,
        globalMergeChanged: EffectiveVersions.globalMerge(context, state.Previous) !== (state.GlobalMerge ?? ''),
        smartPolicyChanged: EffectiveVersions.smartConversion(context, state.Previous) !== Settings.load(context).smartAutoConvert };
    } finally { leave(); }
  }

  /** Restage provenance through the current compiler and platform safety constraints;
   * never copy an old generated file over a live file or activate an unverified pointer.
   */
  export async function restorePrevious(context: common.Context, expectedCurrent: string,
    expectedPrevious: string): Promise<ProfileApplyState> {
    enter(context);
    let smart = Settings.load(context).smartAutoConvert;
    let preferenceChanged = false;
    const publication: SmartPublication = { committed: false, unresolved: false };
    try {
      await Settings.idle(); smart = Settings.load(context).smartAutoConvert;
      const state = EffectiveVersions.read(context);
      const previous = state?.Previous;
      if (state?.Current?.ID !== expectedCurrent || previous === null || previous === undefined ||
        previous.ID !== expectedPrevious) { throw new Error('版本已变化，请重新预览'); }
      const original = EffectiveVersions.original(context, previous);
      const overlay = EffectiveVersions.overlay(context, previous);
      const globalMerge = EffectiveVersions.globalMerge(context, previous);
      const region = EffectiveVersions.regionPlan(context, previous);
      const source = JSON.parse(fileIo.readTextSync(
        `${context.filesDir}/profile-versions/${previous.ID}/source.json`)) as Record<string, string>;
      const meta = source['Metadata'];
      if (typeof meta !== 'string' || meta.length === 0) { throw new Error('上一版本资料损坏'); }
      // Only the strategy preference is restored here. LAN consent and runtime
      // credentials still come from the current host safety projection.
      await Settings.setSmartAutoConvert(context, EffectiveVersions.smartConversion(context, previous));
      preferenceChanged = true;
      return await publish(context, previous.ProfileID, original, overlay, meta, true,
        undefined, region, globalMerge, EffectiveVersions.editIntent(context, previous), undefined, undefined, publication);
    } catch (e) {
      if (preferenceChanged) {
        await rollbackSmartPreference(context, smart, publication);
      }
      throw new Error(ProfileStore.isApplyUncertain(context) ? '应用未确认，请重连恢复' : (e as Error).message);
    } finally { leave(); }
  }

  export async function activate(context: common.Context, file: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('目标配置不存在或读取失败'); }
      return await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true);
    } finally { leave(); }
  }

  /** Before a disconnected start, migrate old versions through the same gate. */
  export async function ensureActiveSmartPolicy(context: common.Context): Promise<void> {
    enter(context);
    try {
      Settings.load(context); await Settings.idle();
      if (VpnController.status !== VpnStatus.Disconnected) { return; }
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { return; }
      const current = EffectiveVersions.read(context)?.Current;
      if (current !== null && current !== undefined &&
        EffectiveVersions.smartConversion(context, current) === Settings.load(context).smartAutoConvert &&
        EffectiveVersions.globalMerge(context, current) === EffectiveVersions.globalContent(context)) {
        return;
      }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前配置不存在或读取失败'); }
      await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true);
    } finally { leave(); }
  }

  export async function edit(context: common.Context, file: string, content: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const candidate = ProfileStore.prepareContent(content);
      const active = ProfileStore.getActiveFile(context) === file;
      return await publish(context, file, candidate, ProfileStore.getEnabledMerge(context, file),
        metadata(context, file, true), active);
    } finally { leave(); }
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
    } finally { leave(); }
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
    finally { leave(); }
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
      try { await EffectiveVersions.collect(context, EffectiveVersions.read(context)?.Current?.ID ?? ''); } catch (_) {}
    }
    finally { leave(); }
  }

  /** Preview and store an inert per-profile overlay. Production application remains a separate transaction. */
  export async function saveMergeDraft(context: common.Context, file: string,
    overlay: string): Promise<MergePreview> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('原始配置不存在'); }
      await CoreValidator.prepareResources(context);
      const saved = EffectiveVersions.read(context)?.Profiles[file];
      const region = saved !== undefined ? EffectiveVersions.regionPlan(context, saved) : null;
      const preview = await EffectiveVersions.previewMerge(context, original, overlay, region, undefined,
        saved !== undefined ? EffectiveVersions.editIntent(context, saved) : null);
      ProfileStore.saveMergeDraft(context, file, overlay);
      return preview;
    } finally { leave(); }
  }

  /** Preview a common baseline against the active source and its local exception. */
  export async function previewGlobalMerge(context: common.Context, overlay: string): Promise<MergePreview> {
    enter(context);
    try {
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { throw new Error('请先启用订阅，再预览或应用全局覆写'); }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前原始配置读取失败'); }
      await CoreValidator.prepareResources(context);
      const saved = EffectiveVersions.read(context)?.Profiles[file];
      const region = saved !== undefined ? EffectiveVersions.regionPlan(context, saved) : null;
      return await EffectiveVersions.previewMerge(context, original,
        ProfileStore.getEnabledMerge(context, file), region, overlay,
        saved !== undefined ? EffectiveVersions.editIntent(context, saved) : null);
    } finally { leave(); }
  }

  /** Global text and the active version share one atomic state publication. */
  export async function applyGlobalMerge(context: common.Context, overlay: string): Promise<ProfileApplyState> {
    enter(context);
    try {
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { throw new Error('请先启用订阅，再应用全局覆写；可先保留草稿'); }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前原始配置读取失败'); }
      return await publish(context, file, original, ProfileStore.getEnabledMerge(context, file),
        metadata(context, file), true, undefined, undefined, overlay);
    } finally { leave(); }
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
    } finally { leave(); }
  }

  /** Recompile the active original and Merge through the normal version gate. */
  export async function setSmartAutoConvert(context: common.Context,
    enabled: boolean): Promise<ProfileApplyState> {
    enter(context);
    const previous = Settings.load(context).smartAutoConvert;
    const publication: SmartPublication = { committed: false, unresolved: false };
    try {
      await Settings.setSmartAutoConvert(context, enabled);
      const file = ProfileStore.getActiveFile(context);
      if (file === '') { return 'saved'; }
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('当前配置不存在或读取失败'); }
      return await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file), true,
        undefined, undefined, undefined, undefined, undefined, undefined, publication);
    } catch (e) {
      await rollbackSmartPreference(context, previous, publication);
      throw new Error((e as Error).message);
    } finally { leave(); }
  }

  export async function previewRegion(context: common.Context, file: string,
    plan: RegionPlan): Promise<RegionPreview> {
    const original = ProfileStore.getProfileContent(context, file);
    if (original === null) { throw new Error('原始配置不存在'); }
    const saved = EffectiveVersions.read(context)?.Profiles[file];
    return await EffectiveVersions.previewRegion(context, ProfileStore.prepareContent(original),
      ProfileStore.getEnabledMerge(context, file), plan,
      saved !== undefined ? EffectiveVersions.editIntent(context, saved) : null);
  }

  export async function setRegionPlan(context: common.Context, file: string,
    plan: RegionPlan | null, activate: boolean = false): Promise<ProfileApplyState> {
    enter(context);
    try {
      const original = ProfileStore.getProfileContent(context, file);
      if (original === null) { throw new Error('原始配置不存在'); }
      const result = await publish(context, file, ProfileStore.prepareContent(original),
        ProfileStore.getEnabledMerge(context, file), metadata(context, file),
        activate || ProfileStore.getActiveFile(context) === file, undefined, plan);
      return result;
    } finally { leave(); }
  }

  /** Consume only a user's explicit selection request, once Controller is ready. */
  export async function applyPendingRegionSelection(context: common.Context): Promise<boolean> {
    if (busy || VpnController.status !== VpnStatus.Connected) { return false; }
    enter(context);
    try {
      const file = ProfileStore.getActiveFile(context);
      const version = EffectiveVersions.read(context)?.Current;
      if (file === '' || version === null || version === undefined) { return false; }
      const epoch = VpnController.configurationEpoch();
      const session = await CoreApi.getControllerSession();
      const current = (): boolean => VpnController.status === VpnStatus.Connected &&
        VpnController.configurationEpoch() === epoch && ProfileStore.getActiveFile(context) === file &&
        EffectiveVersions.read(context)?.Current?.ID === version.ID;
      if (session === null || !current()) { return false; }
      const sameSession = async (): Promise<boolean> => current() && await CoreApi.getControllerSession() === session && current();
      return await ProfileRegionChoices.resume(context, file, version, current, sameSession);
    } finally { leave(); }
  }
}
