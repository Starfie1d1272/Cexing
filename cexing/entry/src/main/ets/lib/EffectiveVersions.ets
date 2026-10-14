/* Immutable generated profiles. The Go FileStore publishes state.json atomically. */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Settings } from './Settings';
import { MergePreview } from './CoreValidator';
import { EditIntent } from './ConfigEditor';

export interface EffectiveVersion { ID: string; Path: string; ProfileID: string; }
export interface EffectiveState {
  Current: EffectiveVersion | null;
  Previous: EffectiveVersion | null;
  Profiles: Record<string, EffectiveVersion>;
  GlobalMerge?: string;
}
export interface StagedVersion { version: EffectiveVersion; receipt: string; digest?: string; }
export interface RegionPlan {
  mode: string;
  selector: string;
  enable: boolean;
  disabled?: boolean;
  assignments: Record<string, string>;
}
export interface RegionPreview {
  eligible: boolean;
  offerable: boolean;
  providerPending: boolean;
  selectors: string[];
  regions?: string[];
  nodes: Record<string, string>;
  counts: Record<string, number>;
  unknown: number;
}
interface VersionRequest {
  op: string;
  editIntent?: EditIntent | null;
  profileId?: string;
  original?: string;
  overlay?: string;
  globalMerge?: string;
  updateGlobal?: boolean;
  metadata?: string;
  expected?: string;
  overrides?: string;
  versionId?: string;
  active?: boolean;
  newProfileId?: string;
  smartConversion?: boolean;
  regionPlan?: RegionPlan | null;
}

export namespace EffectiveVersions {
  function path(context: common.Context): string { return `${context.filesDir}/profile-versions/state.json`; }

  function check(context: common.Context, version: EffectiveVersion): void {
    if (!/^version-[A-Za-z0-9_-]+$/.test(version.ID) ||
      !/^[^/\\\u0000-\u001f]{1,128}\.ya?ml$/i.test(version.ProfileID) ||
      version.Path !== `${context.filesDir}/profile-versions/${version.ID}/config.yaml` ||
      !fileIo.accessSync(version.Path) ||
      !fileIo.accessSync(`${context.filesDir}/profile-versions/${version.ID}/original.yaml`) ||
      !fileIo.accessSync(`${context.filesDir}/profile-versions/${version.ID}/source.json`)) {
      throw new Error('有效配置版本损坏，请勿继续启动 VPN');
    }
  }

  /** null: legacy store; a broken published pointer always throws closed. */
  export function read(context: common.Context): EffectiveState | null {
    const p = path(context);
    if (!fileIo.accessSync(p)) { return null; }
    try {
      const state = JSON.parse(fileIo.readTextSync(p)) as EffectiveState;
      if (state.GlobalMerge !== undefined && typeof state.GlobalMerge !== 'string') {
        throw new Error('invalid global merge');
      }
      if (state.Current !== null && state.Current !== undefined) { check(context, state.Current); }
      if (state.Previous !== null && state.Previous !== undefined) { check(context, state.Previous); }
      if (state.Profiles === null || typeof state.Profiles !== 'object') { throw new Error('invalid profiles'); }
      for (const name of Object.keys(state.Profiles)) {
        const v = state.Profiles[name];
        check(context, v);
        if (v.ProfileID !== name) { throw new Error('invalid profile key'); }
      }
      if (state.Current !== null && state.Current !== undefined &&
        state.Profiles[state.Current.ProfileID]?.ID !== state.Current.ID) {
        throw new Error('selected version missing from profile index');
      }
      return state;
    } catch (_) { throw new Error('有效配置版本损坏，请勿继续启动 VPN'); }
  }

  export function original(context: common.Context, version: EffectiveVersion): string {
    check(context, version);
    return fileIo.readTextSync(`${context.filesDir}/profile-versions/${version.ID}/original.yaml`);
  }

  export function overlay(context: common.Context, version: EffectiveVersion): string {
    check(context, version);
    const p = `${context.filesDir}/profile-versions/${version.ID}/overlay.yaml`;
    return fileIo.accessSync(p) ? fileIo.readTextSync(p) : '';
  }

  export function globalContent(context: common.Context): string {
    return read(context)?.GlobalMerge ?? '';
  }

  /** Legacy versions had no global layer. Never infer it from a local overlay. */
  export function globalMerge(context: common.Context, version: EffectiveVersion): string {
    check(context, version);
    const source = JSON.parse(fileIo.readTextSync(
      `${context.filesDir}/profile-versions/${version.ID}/source.json`)) as Record<string, Object>;
    if (source['GlobalMerge'] === undefined) { return ''; }
    if (typeof source['GlobalMerge'] !== 'string') { throw new Error('全局覆写版本损坏'); }
    return source['GlobalMerge'] as string;
  }

  /** Older versions lack this field and represent the unconverted source. */
  export function smartConversion(context: common.Context, version: EffectiveVersion): boolean {
    check(context, version);
    const source = JSON.parse(fileIo.readTextSync(
      `${context.filesDir}/profile-versions/${version.ID}/source.json`)) as Record<string, Object>;
    return source['SmartConversion'] === true;
  }

  export function regionPlan(context: common.Context, version: EffectiveVersion): RegionPlan | null {
    check(context, version);
    const source = JSON.parse(fileIo.readTextSync(
      `${context.filesDir}/profile-versions/${version.ID}/source.json`)) as Record<string, Object>;
    const plan = source['RegionPlan'] as RegionPlan | null;
    return plan ?? null;
  }

  /** Missing legacy provenance means no structured edits. Drafts are never read here. */
  export function editIntent(context: common.Context, version: EffectiveVersion): EditIntent | null {
    check(context, version);
    const source = JSON.parse(fileIo.readTextSync(
      `${context.filesDir}/profile-versions/${version.ID}/source.json`)) as Record<string, Object>;
    const intent = source['EditIntent'] as EditIntent | null;
    if (intent === undefined || intent === null) { return null; }
    if (intent.schemaVersion !== 1 || typeof intent.revision !== 'string' ||
      intent.revision.length === 0 || !Array.isArray(intent.operations)) { throw new Error('编辑意图损坏'); }
    return intent;
  }

  export async function checkIntent(context: common.Context, intent: EditIntent | null,
    expected: string): Promise<void> {
    await call(context, { op: 'edit-check', editIntent: intent, expected: expected });
  }

  async function call(context: common.Context, action: VersionRequest): Promise<Record<string, Object>> {
    const result = await core.versionAction(context.filesDir, JSON.stringify(action));
    try {
      const parsed = JSON.parse(result) as Record<string, Object>;
      if (typeof parsed['error'] === 'string') { throw new Error(parsed['error'] as string); }
      return parsed;
    } catch (e) { throw new Error(`配置版本操作失败: ${(e as Error).message}`); }
  }

  export async function stage(context: common.Context, profileId: string, original: string,
    overlay: string, metadata: string, expected: string,
    regionPlan: RegionPlan | null, globalMerge?: string, editIntent?: EditIntent | null): Promise<StagedVersion> {
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, ipv6: s.ipv6, mode: s.mode, logToFile: s.logToFile });
    const result = await call(context, { op: 'stage', profileId: profileId, original: original,
      overlay: overlay, metadata: metadata, expected: expected, overrides: overrides,
      smartConversion: s.smartAutoConvert, regionPlan: regionPlan,
      globalMerge: globalMerge, updateGlobal: globalMerge !== undefined, editIntent: editIntent });
    const version = result['version'] as EffectiveVersion;
    if (version === undefined) { throw new Error('暂存配置失败'); }
    check(context, version);
    return { version: version, receipt: result['receipt'] as string ?? '', digest: result['digest'] as string ?? '' };
  }

  export async function previewMerge(context: common.Context, original: string,
    overlay: string, regionPlan: RegionPlan | null, globalMerge?: string, editIntent?: EditIntent | null): Promise<MergePreview> {
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, ipv6: s.ipv6, mode: s.mode, logToFile: s.logToFile });
    const result = await call(context, { op: 'merge-preview', original: original,
      overlay: overlay, regionPlan: regionPlan, smartConversion: s.smartAutoConvert,
      expected: read(context)?.Current?.ID ?? '', overrides: overrides,
      globalMerge: globalMerge, updateGlobal: globalMerge !== undefined, editIntent: editIntent });
    const preview = result['mergePreview'] as MergePreview;
    if (preview === undefined || typeof preview.digest !== 'string' || !Array.isArray(preview.changes)) {
      throw new Error('覆写未通过本机校验或资源未解析');
    }
    return preview;
  }

  export async function previewRegion(context: common.Context, original: string,
    overlay: string, plan: RegionPlan, editIntent?: EditIntent | null): Promise<RegionPreview> {
    const result = await call(context, { op: 'region-preview', original: original,
      overlay: overlay, regionPlan: plan, editIntent: editIntent, expected: read(context)?.Current?.ID ?? '' });
    const preview = result['regionPreview'] as RegionPreview;
    if (preview === undefined || !Array.isArray(preview.selectors)) {
      throw new Error('地区策略预览失败');
    }
    return preview;
  }

  export async function verify(context: common.Context, version: EffectiveVersion,
    expected: string, globalMerge?: string): Promise<string> {
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, ipv6: s.ipv6, mode: s.mode, logToFile: s.logToFile });
    const result = await call(context, { op: 'verify', versionId: version.ID,
      expected: expected, overrides: overrides,
      globalMerge: globalMerge, updateGlobal: globalMerge !== undefined });
    return result['receipt'] as string ?? '';
  }

  export async function commit(context: common.Context, version: EffectiveVersion,
    expected: string, active: boolean, globalMerge?: string): Promise<void> {
    await call(context, { op: 'commit', versionId: version.ID, profileId: version.ProfileID,
      expected: expected, active: active,
      globalMerge: globalMerge, updateGlobal: globalMerge !== undefined });
  }

  export async function discard(context: common.Context, version: EffectiveVersion,
    expected: string): Promise<void> {
    await call(context, { op: 'discard', versionId: version.ID, expected: expected });
  }

  export async function rename(context: common.Context, oldName: string,
    newName: string, expected: string): Promise<void> {
    await call(context, { op: 'rename', profileId: oldName, newProfileId: newName, expected: expected });
  }

  export async function remove(context: common.Context, name: string, expected: string): Promise<void> {
    await call(context, { op: 'remove', profileId: name, expected: expected });
  }
}
