/*
 * ProfileStore.ets - 配置（订阅）存储
 * 导入兼容文件存放于 filesDir/profiles/*.yaml；发布过版本后，
 * profile-versions/state.json 是唯一有效选择与内容指针，active.txt 仅供旧数据迁移。
 * 主进程下载订阅（本应用已被加入 VPN blockedApplications，走直连）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';
import { suggestProfileName, profileNameFromUrl } from './ProfileName';
import { EffectiveVersions } from './EffectiveVersions';
import { RegionChoiceState } from './TemplateRegionEffects';
import { EditIntent } from './ConfigEditor';
import { BoundedFileReader, IMPORT_CONFIG_BYTES, CORE_CONFIG_BYTES } from './BoundedFileReader';

const TAG = 'profileStore';
const ACTIVE_FILE = 'active.txt';
const META_FILE = 'meta.json';
const UNCERTAIN_FILE = 'apply-uncertain.txt';

export interface ProfileMeta {
  file: string;
  name: string;
  size: number;
  mtime: number;
  active: boolean;
}

/** 订阅流量信息（来自 HTTP 响应头 subscription-userinfo） */
export interface SubInfo {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

/** 侧车 meta.json 中单个 profile 的扩展信息 */
export interface ProfileMetaExt {
  origin: string;
  sub: SubInfo;
  updatedAt: number;
}

export interface ProfileUpdateState {
  id: string;
  attemptedAt: number;
  succeededAt: number;
  failedAt: number;
  retryAt: number;
}

export interface EditorSourceCandidate { original: string; metadata: ProfileMetaExt; }
export interface EditDraftSource {
  profileIdentity: string; profileVersion: string; baseDigest: string; metadata: ProfileMetaExt;
}
export interface EditDraft { revision: string; intent: EditIntent | null; source?: EditDraftSource; consumed?: boolean; }
const DRAFT_HEADER_BYTES: number = 1024 * 1024 + 128 * 1024;
const DRAFT_PREFIX_BYTES: number = 13;
const DRAFT_BYTES: number = IMPORT_CONFIG_BYTES + DRAFT_HEADER_BYTES + DRAFT_PREFIX_BYTES;

export namespace ProfileStore {
  function intentDraftPath(context: common.Context, file: string): string {
    if (!/^[^/\\\u0000-\u001f]{1,128}\.ya?ml$/i.test(file)) { throw new Error('无效的配置文件名'); }
    return `${ensureDir(context)}/${file}.intent.json`;
  }

  function readDraftRecord(context: common.Context, file: string): EditDraft | null {
    const path = intentDraftPath(context, file);
    if (!fileIo.accessSync(path)) { return null; }
    const size = fileIo.statSync(path).size;
    const magic = fileIo.readTextSync(path, { length: Math.min(4, size) });
    let raw = '';
    if (magic === 'CED2') {
      const prefix = fileIo.readTextSync(path, { length: DRAFT_PREFIX_BYTES });
      const length = draftHeaderLength(prefix);
      if (size > DRAFT_BYTES || size <= DRAFT_PREFIX_BYTES + length) { throw new Error('编辑草稿损坏'); }
      raw = fileIo.readTextSync(path, { offset: DRAFT_PREFIX_BYTES, length: length });
    } else {
      if (size > 1024 * 1024 + 1024) { throw new Error('编辑草稿超限'); }
      raw = fileIo.readTextSync(path);
    }
    const draft = JSON.parse(raw) as EditDraft;
    if (draft.source !== undefined && (magic !== 'CED2' ||
      typeof draft.source.profileIdentity !== 'string' || typeof draft.source.profileVersion !== 'string' ||
      !/^[a-f0-9]{64}$/.test(draft.source.baseDigest) || draft.source.metadata === null ||
      typeof draft.source.metadata !== 'object')) { throw new Error('编辑草稿损坏'); }
    if (magic === 'CED2' && (draft.source === undefined || draft.intent === null)) { throw new Error('编辑草稿损坏'); }
    if ((draft.consumed !== undefined && typeof draft.consumed !== 'boolean') ||
      (draft.consumed === true && (draft.intent !== null || draft.source !== undefined)) ||
      typeof draft.revision !== 'string' || draft.revision.length === 0 ||
      draft.intent === undefined || (draft.intent !== null && draft.intent.revision !== draft.revision)) {
      throw new Error('编辑草稿损坏');
    }
    return draft;
  }

  export function readEditDraft(context: common.Context, file: string): EditDraft {
    const draft = readDraftRecord(context, file);
    const version = EffectiveVersions.read(context)?.Profiles[file];
    const applied = version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
    if (draft === null || draft.consumed === true) { return { revision: applied?.revision ?? '', intent: applied }; }
    if (applied !== null && applied.revision === draft.revision) {
      // The compiler may enrich the applied intent with template Base/Mine.
      // An applied draft is now the successful provenance; an unpublished UUID
      // keeps its own content and is never silently rebased here.
      return { revision: draft.revision, intent: applied };
    }
    return draft;
  }

  /** Compact a consumed record before another publication can move its provenance away.
   * A crash before compaction is recoverable while the current version still owns it. */
  export async function compactAppliedDraft(context: common.Context, file: string): Promise<void> {
    const draft = readDraftRecord(context, file);
    if (draft === null || draft.consumed === true) { return; }
    const version = EffectiveVersions.read(context)?.Profiles[file];
    const applied = version !== undefined ? EffectiveVersions.editIntent(context, version) : null;
    if (applied === null || applied.revision !== draft.revision) { return; }
    await saveEditDraftAtomic(context, file, { revision: draft.revision, intent: null, consumed: true },
      draft.revision, async () => {
        const now = readDraftRecord(context, file);
        const current = EffectiveVersions.read(context)?.Profiles[file];
        if (now?.revision !== draft.revision || current?.ID !== version?.ID) { throw new Error('草稿已变化，请重新打开'); }
      });
  }

  /** Called by the shared transaction gate after strict worker schema checking. */
  export function saveEditDraft(context: common.Context, file: string, draft: EditDraft,
    expected: string): void {
    if (draft.source !== undefined) { throw new Error('候选草稿必须完整保存'); }
    if (readEditDraft(context, file).revision !== expected) { throw new Error('草稿已变化，请重新打开'); }
    atomicText(intentDraftPath(context, file), JSON.stringify(draft));
  }

  function draftHeaderLength(prefix: string): number {
    if (!/^CED2[0-9a-f]{8}\n$/.test(prefix)) { throw new Error('编辑草稿损坏'); }
    const length = parseInt(prefix.substring(4, 12), 16);
    if (length <= 0 || length > DRAFT_HEADER_BYTES) { throw new Error('编辑草稿超限'); }
    return length;
  }

  /** Read the large private body asynchronously, never as part of a sync ticket. */
  export async function readEditDraftSource(context: common.Context, file: string,
    revision: string, current?: () => boolean): Promise<EditorSourceCandidate | undefined> {
    const before = readEditDraft(context, file);
    if (before.revision !== revision) { throw new Error('草稿已变化，请重新打开'); }
    if (before.source === undefined) { return undefined; }
    const data = await BoundedFileReader.bytes(intentDraftPath(context, file), DRAFT_BYTES, current);
    const decoder = util.TextDecoder.create('utf-8', { fatal: true });
    const prefix = decoder.decodeToString(new Uint8Array(data, 0, DRAFT_PREFIX_BYTES));
    const length = draftHeaderLength(prefix);
    if (data.byteLength <= DRAFT_PREFIX_BYTES + length) { throw new Error('编辑草稿损坏'); }
    const header = JSON.parse(decoder.decodeToString(new Uint8Array(data, DRAFT_PREFIX_BYTES, length))) as EditDraft;
    if (JSON.stringify(header) !== JSON.stringify(before)) { throw new Error('草稿已变化，请重新打开'); }
    const start = DRAFT_PREFIX_BYTES + length;
    if (data.byteLength - start > IMPORT_CONFIG_BYTES) { throw new Error('编辑草稿超限'); }
    const original = await BoundedFileReader.decodeUtf8(data, current, start);
    if (JSON.stringify(readEditDraft(context, file)) !== JSON.stringify(before)) { throw new Error('草稿已变化，请重新打开'); }
    return { original: original, metadata: before.source.metadata };
  }

  /** One atomic private file pairs intent and candidate; failed/late writes leave the old draft. */
  export async function saveEditDraftAtomic(context: common.Context, file: string, draft: EditDraft,
    expected: string, guard: () => Promise<void>, original?: string): Promise<void> {
    if ((draft.source === undefined) !== (original === undefined) ||
      (draft.source !== undefined && draft.intent === null)) { throw new Error('编辑草稿损坏'); }
    if (original !== undefined) { BoundedFileReader.checkConfigSize(original); }
    const header = JSON.stringify(draft);
    const encodedHeader = util.TextEncoder.create('utf-8').encodeInto(header);
    if (encodedHeader.byteLength > (original !== undefined ? DRAFT_HEADER_BYTES : 1024 * 1024 + 1024)) { throw new Error('编辑草稿超限'); }
    const prefix = `CED2${encodedHeader.byteLength.toString(16).padStart(8, '0')}\n`;
    const path = intentDraftPath(context, file);
    const temp = `${path}.pending-${util.generateRandomUUID(true)}`;
    try {
      const data = util.TextEncoder.create('utf-8').encodeInto(original !== undefined ? prefix + header + original : header);
      await BoundedFileReader.write(temp, data.buffer as ArrayBuffer);
      await guard();
      if (readEditDraft(context, file).revision !== expected) { throw new Error('草稿已变化，请重新打开'); }
      await fileIo.moveFile(temp, path);
    } finally {
      try { if (fileIo.accessSync(temp)) { await fileIo.unlink(temp); } } catch (_) {}
    }
  }

  let pendingImports: string[] = [];
  /** One stable identity per imported source; rename moves this sidecar too.
   * Legacy global lastAutoUpdateMs is intentionally not attributed to any source.
   */
  export function updateState(context: common.Context, file: string): ProfileUpdateState {
    if (!/^[^/\\\u0000-\u001f]{1,128}\.ya?ml$/i.test(file)) { throw new Error('无效的配置文件名'); }
    const path = `${ensureDir(context)}/${file}.update.json`;
    if (fileIo.accessSync(path)) {
      const state = JSON.parse(fileIo.readTextSync(path)) as ProfileUpdateState;
      if (typeof state.id !== 'string' || state.id.length === 0 ||
        ![state.attemptedAt, state.succeededAt, state.failedAt, state.retryAt].every(
          (value: number) => Number.isFinite(value) && value >= 0)) {
        throw new Error('更新记录损坏');
      }
      return state;
    }
    const state: ProfileUpdateState = { id: util.generateRandomUUID(true), attemptedAt: 0,
      succeededAt: 0, failedAt: 0, retryAt: 0 };
    saveUpdateState(context, file, state);
    return state;
  }

  export function saveUpdateState(context: common.Context, file: string, state: ProfileUpdateState): void {
    if (!/^[^/\\\u0000-\u001f]{1,128}\.ya?ml$/i.test(file)) { throw new Error('无效的配置文件名'); }
    atomicText(`${ensureDir(context)}/${file}.update.json`, JSON.stringify(state));
  }


  function dir(context: common.Context): string {
    return `${context.filesDir}/profiles`;
  }

  function ensureDir(context: common.Context): string {
    const d = dir(context);
    if (!fileIo.accessSync(d)) {
      fileIo.mkdirSync(d, true);
    }
    return d;
  }

  function activePath(context: common.Context): string {
    return `${ensureDir(context)}/${ACTIVE_FILE}`;
  }

  function metaPath(context: common.Context): string {
    return `${ensureDir(context)}/${META_FILE}`;
  }

  export function isApplyUncertain(context: common.Context): boolean {
    return fileIo.accessSync(`${ensureDir(context)}/${UNCERTAIN_FILE}`);
  }

  export function markApplyUncertain(context: common.Context): void {
    atomicText(`${ensureDir(context)}/${UNCERTAIN_FILE}`, '1');
  }

  export function clearApplyUncertain(context: common.Context): void {
    const p = `${ensureDir(context)}/${UNCERTAIN_FILE}`;
    if (fileIo.accessSync(p)) { fileIo.unlinkSync(p); }
  }

  function atomicText(path: string, content: string): void {
    const temp = `${path}.pending`;
    const f = fileIo.openSync(temp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(f.fd, content); } finally { fileIo.closeSync(f); }
    try { fileIo.moveFileSync(temp, path); } catch (e) {
      try { fileIo.unlinkSync(temp); } catch (_) {}
      throw new Error('保存配置文件失败');
    }
  }

  /** 读取侧车 meta.json；文件不存在或解析失败返回 {} */
  export function getMeta(context: common.Context): Record<string, ProfileMetaExt> {
    const state = EffectiveVersions.read(context);
    let all: Record<string, ProfileMetaExt>;
    try {
      const p = metaPath(context);
      const raw = fileIo.accessSync(p) ? fileIo.readTextSync(p) : '{}';
      all = JSON.parse(raw.trim().length > 0 ? raw : '{}') as Record<string, ProfileMetaExt>;
    } catch (e) {
      Logger.warn(TAG, 'getMeta failed');
      all = JSON.parse('{}') as Record<string, ProfileMetaExt>;
    }
    if (state !== null) {
      for (const name of Object.keys(state.Profiles)) {
        const version = state.Profiles[name];
        try {
          const source = JSON.parse(fileIo.readTextSync(`${context.filesDir}/profile-versions/${version.ID}/source.json`)) as
            Record<string, string>;
          all[name] = JSON.parse(source['Metadata']) as ProfileMetaExt;
        } catch (_) { throw new Error('有效配置元数据损坏，请勿继续修改'); }
      }
    }
    return all;
  }

  function writeMeta(context: common.Context, all: Record<string, ProfileMetaExt>): void {
    atomicText(metaPath(context), JSON.stringify(all));
  }

  function readMetaStrict(context: common.Context): Record<string, ProfileMetaExt> {
    const p = metaPath(context);
    if (!fileIo.accessSync(p)) { return {}; }
    const raw = fileIo.readTextSync(p);
    return raw.trim().length === 0 ? {} : JSON.parse(raw) as Record<string, ProfileMetaExt>;
  }

  function writeMetaEntryStrict(context: common.Context, file: string, entry: ProfileMetaExt): void {
    const all = readMetaStrict(context);
    all[file] = entry;
    writeMeta(context, all);
  }

  /** 写入/覆盖单个 profile 的 meta 条目 */
  export function setMetaEntry(context: common.Context, file: string, entry: ProfileMetaExt): void {
    try {
      const all = getMeta(context);
      all[file] = entry;
      writeMeta(context, all);
    } catch (e) {
      Logger.warn(TAG, 'setMetaEntry failed');
    }
  }

  /** 删除单个 profile 的 meta 条目（ArkTS 不支持 delete 运算符，重建对象） */
  export function deleteMetaEntry(context: common.Context, file: string): void {
    try {
      const all = getMeta(context);
      if (all[file] === undefined) {
        return;
      }
      const next: Record<string, ProfileMetaExt> = {};
      const keys = Object.keys(all);
      for (const k of keys) {
        if (k !== file) {
          next[k] = all[k];
        }
      }
      writeMeta(context, next);
    } catch (e) {
      Logger.warn(TAG, 'deleteMetaEntry failed');
    }
  }

  /** 解析 subscription-userinfo 响应头（upload=1; download=2; total=3; expire=4，字段可缺失） */
  function parseSubInfo(raw: string): SubInfo {
    const out: SubInfo = { upload: 0, download: 0, total: 0, expire: 0 };
    if (raw.length === 0) {
      return out;
    }
    const parts = raw.split(';');
    for (const part of parts) {
      const eq = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k = part.substring(0, eq).trim();
      const v = Number(part.substring(eq + 1).trim());
      // !(v >= 0) 同时命中 NaN（转换失败）与负数
      if (!(v >= 0)) {
        continue;
      }
      if (k === 'upload') {
        out.upload = v;
      } else if (k === 'download') {
        out.download = v;
      } else if (k === 'total') {
        out.total = v;
      } else if (k === 'expire') {
        out.expire = v;
      }
    }
    return out;
  }

  /** 从 HTTP 响应构造 meta 条目（头键名为小写 subscription-userinfo） */
  function metaEntryFromResp(resp: http.HttpResponse, url: string): ProfileMetaExt {
    let raw = '';
    try {
      const headers = resp.header as Record<string, Object>;
      const v = headers['subscription-userinfo'];
      raw = typeof v === 'string' ? v : '';
    } catch (e) {
      // 无该头，忽略
    }
    return {
      origin: url,
      sub: parseSubInfo(raw),
      updatedAt: Math.floor(Date.now() / 1000)
    };
  }

  export function list(context: common.Context): ProfileMeta[] {
    const d = ensureDir(context);
    const state = EffectiveVersions.read(context);
    const active = getActiveFile(context);
    const out: ProfileMeta[] = [];
    try {
      const names = fileIo.listFileSync(d);
      // Immutable versions remain authoritative after restoration even if the
      // old compatibility file was deleted. Keep those profiles operable in UI.
      if (state !== null) {
        for (const name of Object.keys(state.Profiles)) {
          if (!names.includes(name)) { names.push(name); }
        }
      }
      for (const name of names) {
        if (name === ACTIVE_FILE || !/\.(yaml|yml)$/i.test(name)) {
          continue;
        }
        try {
          const version = state?.Profiles[name];
          const st = fileIo.statSync(version === undefined ? `${d}/${name}` :
            `${context.filesDir}/profile-versions/${version.ID}/original.yaml`);
          out.push({
            file: name,
            name: name.replace(/\.(yaml|yml)$/i, ''),
            size: st.size,
            mtime: st.mtime,
            active: name === active
          });
        } catch (e) {
          Logger.warn(TAG, `stat ${name} failed: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      Logger.warn(TAG, `listFile failed: ${JSON.stringify(e)}`);
    }
    out.sort((a, b) => b.mtime - a.mtime);
    return out;
  }

  export function getActiveFile(context: common.Context): string {
    const state = EffectiveVersions.read(context);
    if (state !== null) { return state.Current?.ProfileID ?? ''; }
    try {
      const p = activePath(context);
      if (fileIo.accessSync(p)) {
        return fileIo.readTextSync(p).trim();
      }
    } catch (e) {
      Logger.warn(TAG, `read active failed: ${JSON.stringify(e)}`);
    }
    return '';
  }

  export function setActive(context: common.Context, file: string): void {
    atomicText(activePath(context), file);
    Logger.info(TAG, `active -> ${file}`);
  }

  /**
   * 清洗并校验配置文本：
   * 1. 去 UTF-8 BOM
   * 2. 修复旧版导入路径（String.fromCharCode 逐字节映射）造成的 UTF-8 双重编码：
   *    原始字节 b(≥0x80) 被映射成 U+00xx 字符再按 UTF-8 落盘，其中续字节 0x80~0x9F
   *    变成 C1 控制符，内核 yaml 解析报 "control characters are not allowed"。
   *    检测到 C1 控制符且全部码点 ≤0xFF 时，把码点还原为字节并按 UTF-8 解码。
   * 3. 拒绝剩余的非法控制字符（C0 除 \t\n\r、DEL、C1），给出可读错误。
   */
  function sanitizeConfigContent(content: string): string {
    let text = content;
    if (text.charCodeAt(0) === 0xFEFF) {
      text = text.slice(1);
    }
    let hasC1 = false;
    let allLatin1 = true;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c >= 0x80 && c <= 0x9F) {
        hasC1 = true;
      }
      if (c > 0xFF) {
        allLatin1 = false;
      }
    }
    if (hasC1 && allLatin1) {
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) {
        bytes[i] = text.charCodeAt(i);
      }
      const fixed = util.TextDecoder.create('utf-8').decodeToString(bytes);
      // 修复结果必须仍含配置特征才采纳，防止误修复
      if (fixed.includes('proxies:') || fixed.includes('proxy-groups:') || fixed.includes('proxy-providers:')) {
        Logger.warn(TAG, `config repaired from byte-flattened UTF-8 (${text.length} -> ${fixed.length} chars)`);
        text = fixed;
      }
    }
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c < 0x20 && c !== 0x09 && c !== 0x0A && c !== 0x0D) || c === 0x7F || (c >= 0x80 && c <= 0x9F)) {
        throw new Error(`配置含非法控制字符(0x${c.toString(16)})，请确认文件为 UTF-8 编码`);
      }
    }
    return text;
  }

  /** 读取激活配置内容；无激活配置返回 null（调用方回退 rawfile/默认）。
   *  读取时执行编码修复：若文件是旧版导入的字节拍平损坏，修复后回写磁盘，
   *  保证后续 PUT /configs 按路径热加载也能解析成功。 */
  export function getActiveContent(context: common.Context): string | null {
    const state = EffectiveVersions.read(context);
    if (state !== null) {
      return state.Current === null || state.Current === undefined ? null : fileIo.readTextSync(state.Current.Path);
    }
    const file = getActiveFile(context);
    if (file.length === 0) {
      return null;
    }
    const p = `${dir(context)}/${file}`;
    try {
      if (fileIo.accessSync(p)) {
        const raw = fileIo.readTextSync(p);
        const fixed = sanitizeConfigContent(raw);
        if (fixed !== raw) {
          atomicText(p, fixed);
          Logger.info(TAG, `profile ${file} repaired and written back`);
        }
        return fixed;
      }
    } catch (e) {
      Logger.error(TAG, `read profile ${file} failed: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
    return null;
  }

  export async function deleteProfile(context: common.Context, file: string): Promise<void> {
    const rawPath = `${dir(context)}/${file}`;
    if (fileIo.accessSync(rawPath)) { await fileIo.unlink(rawPath); }
    deleteMetaEntry(context, file);
    const originPath = `${dir(context)}/${file}.url`;
    if (fileIo.accessSync(originPath)) {
      try { await fileIo.unlink(originPath); } catch (_) { /* orphan metadata can be retried */ }
    }
    if (getActiveFile(context) === file) {
      setActive(context, '');
    }
    const backup = `${dir(context)}/${file}.last-good`;
    if (fileIo.accessSync(backup)) {
      try { await fileIo.unlink(backup); } catch (_) { /* non-effective backup */ }
    }
    const merge = `${dir(context)}/${file}.merge.json`;
    if (fileIo.accessSync(merge)) {
      try { await fileIo.unlink(merge); } catch (_) { /* orphan draft is not effective */ }
    }
    const updatePath = `${dir(context)}/${file}.update.json`;
    if (fileIo.accessSync(updatePath)) {
      try { await fileIo.unlink(updatePath); } catch (_) { /* orphan schedule is not effective */ }
    }
    const intentPath = intentDraftPath(context, file);
    if (fileIo.accessSync(intentPath)) {
      try { await fileIo.unlink(intentPath); } catch (_) { /* inert orphan */ }
    }
    clearPendingRegionSelection(context, file);
    clearPreviousRegionSelection(context, file);
    try { clearDraft(context, file); } catch (_) { /* non-effective draft */ }
  }

  export function absPath(context: common.Context, file: string): string {
    return `${dir(context)}/${file}`;
  }

  function draftPath(context: common.Context, file: string): string {
    if (!/^[^/\\]+\.(yaml|yml)$/i.test(file)) { throw new Error('无效的配置文件名'); }
    const d = `${ensureDir(context)}/drafts`;
    if (!fileIo.accessSync(d)) { fileIo.mkdirSync(d); }
    return `${d}/${file}.draft`;
  }

  export function readDraft(context: common.Context, file: string): string | null {
    const p = draftPath(context, file);
    return fileIo.accessSync(p) ? fileIo.readTextSync(p) : null;
  }

  export function writeDraft(context: common.Context, file: string, content: string): void {
    atomicText(draftPath(context, file), content);
  }

  export function clearDraft(context: common.Context, file: string): void {
    const p = draftPath(context, file);
    if (fileIo.accessSync(p)) { fileIo.unlinkSync(p); }
  }

  /** Stored separately from the raw subscription; never active until a full transaction commits it. */
  export function getMergeDraft(context: common.Context, file: string): string {
    const p = `${ensureDir(context)}/${file}.merge.json`;
    if (!fileIo.accessSync(p)) { return ''; }
    const entry = JSON.parse(fileIo.readTextSync(p)) as Record<string, string>;
    if (entry['dialect'] !== 'clash-verge-merge-2.5.8' || typeof entry['content'] !== 'string') {
      throw new Error('Merge 方言不受支持');
    }
    return entry['content'];
  }

  /** The immutable version owns an enabled overlay; editing the draft cannot change it. */
  export function getEnabledMerge(context: common.Context, file: string): string {
    const version = EffectiveVersions.read(context)?.Profiles[file];
    if (version !== undefined) { return EffectiveVersions.overlay(context, version); }
    const p = `${ensureDir(context)}/${file}.merge.json`;
    if (!fileIo.accessSync(p)) { return ''; }
    const entry = JSON.parse(fileIo.readTextSync(p)) as Record<string, Object>;
    if (entry['enabled'] !== true) { return ''; }
    return getMergeDraft(context, file);
  }

  /** Runtime consumption belongs only to this exact immutable version. */
  export function runtimeRegionChoice(context: common.Context, file: string, versionId: string): RegionChoiceState | null {
    const p = `${ensureDir(context)}/${file}.region-select.json`;
    if (!fileIo.accessSync(p)) { return null; }
    const raw = JSON.parse(fileIo.readTextSync(p)) as Record<string, Object>;
    if (raw['versionId'] !== versionId) { return null; }
    const state = raw['state'] as RegionChoiceState;
    if (state === undefined || typeof state.pending !== 'string' ||
      (state.previous !== undefined && (typeof state.previous.selector !== 'string' ||
      typeof state.previous.name !== 'string'))) { throw new Error('地区选择记录损坏'); }
    return state;
  }

  export function saveRuntimeRegionChoice(context: common.Context, file: string,
    versionId: string, state: RegionChoiceState): void {
    atomicText(`${ensureDir(context)}/${file}.region-select.json`, JSON.stringify({ versionId: versionId, state: state }));
  }

  export function pendingRegionSelection(context: common.Context, file: string): string {
    const p = `${ensureDir(context)}/${file}.region-select.json`;
    if (!fileIo.accessSync(p)) { return ''; }
    const raw = JSON.parse(fileIo.readTextSync(p)) as Record<string, string>;
    return typeof raw['selector'] === 'string' ? raw['selector'] : '';
  }

  export function setPendingRegionSelection(context: common.Context, file: string,
    selector: string): void {
    atomicText(`${ensureDir(context)}/${file}.region-select.json`, JSON.stringify({ selector: selector }));
  }

  export function clearPendingRegionSelection(context: common.Context, file: string): void {
    const p = `${ensureDir(context)}/${file}.region-select.json`;
    if (fileIo.accessSync(p)) { fileIo.unlinkSync(p); }
  }

  export function previousRegionSelection(context: common.Context, file: string): string {
    const p = `${ensureDir(context)}/${file}.region-previous.json`;
    if (!fileIo.accessSync(p)) { return ''; }
    const raw = JSON.parse(fileIo.readTextSync(p)) as Record<string, string>;
    return typeof raw['name'] === 'string' ? raw['name'] : '';
  }

  export function setPreviousRegionSelection(context: common.Context, file: string,
    name: string): void {
    atomicText(`${ensureDir(context)}/${file}.region-previous.json`, JSON.stringify({ name: name }));
  }

  /** Controller's choice immediately after a failed disable restore; later changes are not ours to overwrite. */
  export function previousRegionObservation(context: common.Context, file: string): string {
    const p = `${ensureDir(context)}/${file}.region-previous.json`;
    if (!fileIo.accessSync(p)) { return ''; }
    const raw = JSON.parse(fileIo.readTextSync(p)) as Record<string, string>;
    return typeof raw['observed'] === 'string' ? raw['observed'] : '';
  }

  export function setPreviousRegionObservation(context: common.Context, file: string,
    observed: string): void {
    const name = previousRegionSelection(context, file);
    if (name !== '') {
      atomicText(`${ensureDir(context)}/${file}.region-previous.json`,
        JSON.stringify({ name: name, observed: observed }));
    }
  }

  export function clearPreviousRegionSelection(context: common.Context, file: string): void {
    const p = `${ensureDir(context)}/${file}.region-previous.json`;
    if (fileIo.accessSync(p)) { fileIo.unlinkSync(p); }
  }

  export function setMergeEnabled(context: common.Context, file: string, content: string): void {
    atomicText(`${ensureDir(context)}/${file}.merge.json`, JSON.stringify({
      dialect: 'clash-verge-merge-2.5.8', sourceVersion: '', content: content, enabled: content.length > 0
    }));
  }

  export function saveMergeDraft(context: common.Context, file: string, content: string): void {
    if (!fileIo.accessSync(absPath(context, file))) { throw new Error('原始配置不存在'); }
    atomicText(`${ensureDir(context)}/${file}.merge.json`, JSON.stringify({
      dialect: 'clash-verge-merge-2.5.8', sourceVersion: '', content: content
    }));
  }

  /** 重命名配置：自动补 .yaml 后缀，迁移 active/.url/meta 记录；返回新文件名，失败抛错 */
  export function renameProfile(context: common.Context, oldFile: string, newName: string): string {
    let target = newName.trim();
    if (target.length === 0) {
      throw new Error('名称不能为空');
    }
    if (target.includes('/') || target.includes('\\')) {
      throw new Error('名称不能包含路径分隔符');
    }
    if (!/\.(yaml|yml)$/i.test(target)) {
      target = `${target}.yaml`;
    }
    if (target === oldFile) {
      return oldFile;
    }
    const d = ensureDir(context);
    const oldPath = `${d}/${oldFile}`;
    const newPath = `${d}/${target}`;
    const suffixes: string[] = ['.url', '.last-good', '.merge.json', '.region-select.json',
      '.region-previous.json', '.update.json', '.intent.json'];
    // moveFileSync may replace a destination. Reject every managed collision
    // before moving the raw source or materializing an immutable-only source.
    const newDraft = draftPath(context, target);
    if (pendingImports.includes(target) || fileIo.accessSync(newPath) || fileIo.accessSync(newDraft) ||
      suffixes.some((suffix: string) => fileIo.accessSync(`${newPath}${suffix}`)) ||
      readMetaStrict(context)[target] !== undefined) {
      throw new Error('目标名称已有资料，请使用其他名称');
    }
    if (!fileIo.accessSync(oldPath)) {
      const original = getProfileContent(context, oldFile);
      if (original === null) { throw new Error('配置文件不存在'); }
      atomicText(oldPath, original);
    }
    try {
      fileIo.moveFileSync(oldPath, newPath);
    } catch (e) {
      throw new Error(`移动文件失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
    const moved: string[][] = [];
    try {
      for (const suffix of suffixes) {
        const from = `${oldPath}${suffix}`;
        const to = `${newPath}${suffix}`;
        if (fileIo.accessSync(from)) {
          fileIo.moveFileSync(from, to);
          moved.push([from, to]);
        }
      }
      const oldDraft = draftPath(context, oldFile);
      if (fileIo.accessSync(oldDraft)) {
        fileIo.moveFileSync(oldDraft, newDraft);
        moved.push([oldDraft, newDraft]);
      }
      if (getActiveFile(context) === oldFile) { setActive(context, target); }
    } catch (_) {
      for (let i = moved.length - 1; i >= 0; i--) {
        try { fileIo.moveFileSync(moved[i][1], moved[i][0]); } catch (_) {}
      }
      try { fileIo.moveFileSync(newPath, oldPath); } catch (_) {}
      throw new Error('重命名附属数据失败，原配置未修改或需要重新检查');
    }
    // 迁移 meta 条目
    const entry = getMeta(context)[oldFile];
    if (entry !== undefined) {
      deleteMetaEntry(context, oldFile);
      setMetaEntry(context, target, entry);
    }
    Logger.info(TAG, `renamed ${oldFile} -> ${target}`);
    return target;
  }

  /** 读取指定配置内容（复用 getActiveContent 的 sanitize 修复逻辑）；文件不存在返回 null */
  export async function getProfileContentAsync(context: common.Context, file: string,
    current?: () => boolean): Promise<string | null> {
    const state = EffectiveVersions.read(context);
    const version = state?.Profiles[file];
    const path = version !== undefined ? `${context.filesDir}/profile-versions/${version.ID}/original.yaml` : `${dir(context)}/${file}`;
    if (!fileIo.accessSync(path)) { return null; }
    const bytes = await BoundedFileReader.bytes(path, CORE_CONFIG_BYTES, current);
    const content = await BoundedFileReader.decodeUtf8(bytes, current);
    return version !== undefined ? content : sanitizeConfigContent(content);
  }

  export function getProfileContent(context: common.Context, file: string): string | null {
    const state = EffectiveVersions.read(context);
    if (state !== null && state.Profiles[file] !== undefined) {
      return EffectiveVersions.original(context, state.Profiles[file]);
    }
    const p = `${dir(context)}/${file}`;
    try {
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const raw = fileIo.readTextSync(p);
      const fixed = sanitizeConfigContent(raw);
      return fixed;
    } catch (e) {
      Logger.error(TAG, `read profile ${file} failed: ${(e as Error).message ?? JSON.stringify(e)}`);
      return null;
    }
  }

  function replaceProfileContent(context: common.Context, file: string, content: string,
    entry: ProfileMetaExt): void {
    const clean = prepareContent(content);
    const p = `${ensureDir(context)}/${file}`;
    if (!fileIo.accessSync(p)) { throw new Error('配置文件不存在'); }
    const previous = fileIo.readTextSync(p);
    // Reject malformed metadata before touching the effective source.
    readMetaStrict(context);
    atomicText(`${p}.last-good`, previous);
    try {
      atomicText(p, clean);
      writeMetaEntryStrict(context, file, entry);
    } catch (_) {
      try { atomicText(p, previous); }
      catch (_) { throw new Error('PROFILE_ROLLBACK_FAILED'); }
      throw new Error('保存配置和元数据失败，原配置已恢复');
    }
    Logger.info(TAG, `profile ${file} updated (${clean.length} bytes)`);
  }

  /** 覆盖写配置（编辑页保存）：元数据失败时恢复原文；失败抛错 */
  export function updateProfileContent(context: common.Context, file: string, content: string): void {
    const prev = readMetaStrict(context)[file];
    const entry: ProfileMetaExt = {
      origin: prev !== undefined ? prev.origin : '',
      sub: prev !== undefined ? prev.sub : { upload: 0, download: 0, total: 0, expire: 0 },
      updatedAt: Math.floor(Date.now() / 1000)
    };
    replaceProfileContent(context, file, content, entry);
  }

  export function prepareContent(content: string): string {
    const clean = sanitizeConfigContent(content);
    validateConfig(clean);
    return clean;
  }

  /** 订阅来源 URL（用于“更新”），sidecar 文件 <file>.url */
  export function getOrigin(context: common.Context, file: string): string {
    const state = EffectiveVersions.read(context);
    if (state !== null && state.Profiles[file] !== undefined) {
      return getMeta(context)[file]?.origin ?? '';
    }
    try {
      const p = `${dir(context)}/${file}.url`;
      if (fileIo.accessSync(p)) {
        return fileIo.readTextSync(p).trim();
      }
    } catch (e) {
      // 忽略
    }
    return '';
  }

  function setOrigin(context: common.Context, file: string, url: string): void {
    atomicText(`${ensureDir(context)}/${file}.url`, url);
  }

  /** Ask subscription origins for Clash YAML using the installed product version. */
  function subscriptionUserAgent(): string {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return `ClashMeta/1.0 Cexing/${info.versionName}`;
  }

  /** 从 URL 导入订阅，返回保存的文件名；失败抛错 */
  export async function importFromUrl(context: common.Context, url: string, current?: () => boolean): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': subscriptionUserAgent() },
        expectDataType: http.HttpDataType.STRING,
        maxLimit: IMPORT_CONFIG_BYTES,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const raw = typeof resp.result === 'string' ? resp.result : '';
      const content = sanitizeConfigContent(raw);
      validateConfig(content);
      const name = suggestProfileName(resp.header as Record<string, Object>,
        profileNameFromUrl(url, '新订阅'));
      const saved = await saveAsync(context, name, content, current);
      setOrigin(context, saved, url);
      writeMetaEntryStrict(context, saved, metaEntryFromResp(resp, url));
      Logger.info(TAG, 'profile imported');
      return saved;
    } finally {
      req.destroy();
    }
  }

  /** 从本地文件/剪贴板内容导入；仅记录 updatedAt（origin 为空） */
  export function importContent(context: common.Context, name: string, content: string): string {
    const clean = sanitizeConfigContent(content);
    validateConfig(clean);
    const file = save(context, name, clean);
    writeMetaEntryStrict(context, file, {
      origin: '',
      sub: { upload: 0, download: 0, total: 0, expire: 0 },
      updatedAt: Math.floor(Date.now() / 1000)
    });
    return file;
  }

  export interface DownloadedProfile {
    content: string;
    meta: ProfileMetaExt;
  }

  /** Download and check a candidate without touching the effective file. */
  export async function downloadFromOrigin(context: common.Context, file: string): Promise<DownloadedProfile> {
    const url = getOrigin(context, file);
    if (url.length === 0) {
      throw new Error('该配置无订阅来源（本地导入）');
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': subscriptionUserAgent() },
        expectDataType: http.HttpDataType.STRING,
        maxLimit: IMPORT_CONFIG_BYTES,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const raw = typeof resp.result === 'string' ? resp.result : '';
      const content = sanitizeConfigContent(raw);
      validateConfig(content);
      return { content: content, meta: metaEntryFromResp(resp, url) };
    } finally {
      req.destroy();
    }
  }


  export function commitDownloaded(context: common.Context, file: string, candidate: DownloadedProfile): void {
    replaceProfileContent(context, file, candidate.content, candidate.meta);
  }

  function validateConfig(content: string): void {
    BoundedFileReader.checkConfigSize(content);
    if (content.length < 16) {
      throw new Error('内容为空或过短');
    }
    if (!content.includes('proxies:') && !content.includes('proxy-providers:') && !content.includes('proxy-groups:')) {
      throw new Error('不是合法的 mihomo 配置（缺少 proxies/proxy-groups）');
    }
  }

  function prepareSave(context: common.Context, name: string): string {
    let file = /\.(yaml|yml)$/i.test(name) ? name : `${name}.yaml`;
    // 避免路径穿越
    file = file.replace(/[\/\\]/g, '_');
    const d = ensureDir(context);
    const stem = file.replace(/\.(yaml|yml)$/i, '');
    const ext = file.substring(stem.length);
    let suffix = 2;
    const effective = EffectiveVersions.read(context);
    while (fileIo.accessSync(`${d}/${file}`) || effective?.Profiles[file] !== undefined || pendingImports.includes(file)) {
      file = `${stem} (${suffix++})${ext}`;
    }
    // Reset the new source before publishing its raw file. A leftover sidecar
    // must either be neutralized or make import fail, never silently reactivate.
    for (const suffix of ['.intent.json', '.url', '.merge.json', '.region-select.json', '.region-previous.json']) {
      const stale = `${d}/${file}${suffix}`;
      if (fileIo.accessSync(stale)) { fileIo.unlinkSync(stale); }
    }
    const oldDraft = draftPath(context, file);
    if (fileIo.accessSync(oldDraft)) { fileIo.unlinkSync(oldDraft); }
    const metadata = readMetaStrict(context);
    const kept: Record<string, ProfileMetaExt> = {};
    for (const name of Object.keys(metadata)) { if (name !== file) { kept[name] = metadata[name]; } }
    writeMeta(context, kept);
    saveUpdateState(context, file, { id: util.generateRandomUUID(true), attemptedAt: 0,
      succeededAt: 0, failedAt: 0, retryAt: 0 });
    return file;
  }

  function save(context: common.Context, name: string, content: string): string {
    const file = prepareSave(context, name);
    const p = `${ensureDir(context)}/${file}`;
    const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(f.fd, content); } finally { fileIo.closeSync(f); }
    return file;
  }
  /** Picker and URL imports use bounded async writes as well as async reads. */
  async function saveAsync(context: common.Context, name: string, content: string,
    current?: () => boolean): Promise<string> {
    const check = (): void => { if (current !== undefined && !current()) { throw new Error('导入已取消'); } };
    check();
    const file = prepareSave(context, name);
    pendingImports.push(file);
    const path = `${ensureDir(context)}/${file}`;
    const temp = `${path}.import-${util.generateRandomUUID(true)}`;
    let opened: fileIo.File | null = null;
    try {
      opened = await fileIo.open(temp, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const encoder = util.TextEncoder.create('utf-8');
      let written = 0;
      for (let start = 0; start < content.length;) {
        check();
        let end = Math.min(start + 64 * 1024, content.length);
        if (end < content.length && content.charCodeAt(end - 1) >= 0xd800 && content.charCodeAt(end - 1) <= 0xdbff) { end--; }
        const chunk = encoder.encodeInto(content.substring(start, end));
        let offset = 0;
        while (offset < chunk.byteLength) {
          check();
          const count = await fileIo.write(opened.fd, chunk.buffer.slice(offset), { offset: written });
          if (!Number.isInteger(count) || count <= 0 || count > chunk.byteLength - offset) { throw new Error('配置未完整写入'); }
          offset += count; written += count;
        }
        start = end;
      }
      check(); await fileIo.fsync(opened.fd);
      await fileIo.close(opened); opened = null;
      check(); await fileIo.moveFile(temp, path);
      return file;
    } finally {
      try { if (opened !== null) { await fileIo.close(opened); } }
      finally {
        try { await fileIo.unlink(temp); } catch (_) { /* own temporary path only */ }
        pendingImports = pendingImports.filter((name: string) => name !== file);
      }
    }
  }

  export async function importContentAsync(context: common.Context, name: string, content: string,
    current?: () => boolean): Promise<string> {
    if (current !== undefined && !current()) { throw new Error('导入已取消'); }
    const clean = sanitizeConfigContent(content);
    validateConfig(clean);
    const file = await saveAsync(context, name, clean, current);
    writeMetaEntryStrict(context, file, { origin: '',
      sub: { upload: 0, download: 0, total: 0, expire: 0 }, updatedAt: Math.floor(Date.now() / 1000) });
    return file;
  }

}
