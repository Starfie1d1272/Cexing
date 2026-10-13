/* Immutable generated profiles. The Go FileStore publishes state.json atomically. */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { Settings } from './Settings';

export interface EffectiveVersion { ID: string; Path: string; ProfileID: string; }
export interface EffectiveState {
  Current: EffectiveVersion | null;
  Previous: EffectiveVersion | null;
  Profiles: Record<string, EffectiveVersion>;
}
export interface StagedVersion { version: EffectiveVersion; receipt: string; }
interface VersionRequest {
  op: string;
  profileId?: string;
  original?: string;
  overlay?: string;
  metadata?: string;
  expected?: string;
  overrides?: string;
  versionId?: string;
  active?: boolean;
  newProfileId?: string;
  smartConversion?: boolean;
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

  /** Older versions lack this field and represent the unconverted source. */
  export function smartConversion(context: common.Context, version: EffectiveVersion): boolean {
    check(context, version);
    const source = JSON.parse(fileIo.readTextSync(
      `${context.filesDir}/profile-versions/${version.ID}/source.json`)) as Record<string, Object>;
    return source['SmartConversion'] === true;
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
    overlay: string, metadata: string, expected: string): Promise<StagedVersion> {
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, mode: s.mode, logToFile: s.logToFile });
    const result = await call(context, { op: 'stage', profileId: profileId, original: original,
      overlay: overlay, metadata: metadata, expected: expected, overrides: overrides,
      smartConversion: s.smartAutoConvert });
    const version = result['version'] as EffectiveVersion;
    if (version === undefined) { throw new Error('暂存配置失败'); }
    check(context, version);
    return { version: version, receipt: result['receipt'] as string ?? '' };
  }

  export async function verify(context: common.Context, version: EffectiveVersion,
    expected: string): Promise<string> {
    const s = Settings.load(context);
    const overrides = JSON.stringify({ mixedPort: s.mixedPort, logLevel: s.logLevel,
      allowLan: s.allowLan, mode: s.mode, logToFile: s.logToFile });
    const result = await call(context, { op: 'verify', versionId: version.ID,
      expected: expected, overrides: overrides });
    return result['receipt'] as string ?? '';
  }

  export async function commit(context: common.Context, version: EffectiveVersion,
    expected: string, active: boolean): Promise<void> {
    await call(context, { op: 'commit', versionId: version.ID, profileId: version.ProfileID,
      expected: expected, active: active });
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
