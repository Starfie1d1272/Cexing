import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import core from 'libentry.so';
import { ConfigEditor, EditIntent, EditTarget, EditorDraftHost, EditorDraftSession, EditorDraftPreview } from './ConfigEditor';
import { Settings } from './Settings';
import { EffectiveVersions, RegionPlan } from './EffectiveVersions';
import { ProfileStore } from './ProfileStore';
import { ProfileTransactions, EditTicket } from './ProfileTransactions';

interface HostInput {
  ticket: EditTicket; original: string; overlay: string; global: string;
  settings: string; region: RegionPlan | null; intent: EditIntent | null;
}
interface HostReply { identity?: string; error?: string; }
function cloneSession(value: EditorDraftSession): EditorDraftSession {
  return JSON.parse(JSON.stringify(value)) as EditorDraftSession;
}

/** One stable profile per instance; no page-owned persistence or publisher. */
class ProfileEditorHost implements EditorDraftHost {
  private context: common.Context;
  private file: string;
  private input: HostInput | null = null;
  private identity: string = '';
  private session: EditorDraftSession | null = null;
  private shown: EditorDraftPreview | null = null;
  private generation: number = 0;
  constructor(context: common.Context, file: string) { this.context = context; this.file = file; }

  private capture(): HostInput {
    const original = ProfileStore.getProfileContent(this.context, this.file);
    if (original === null) { throw new Error('原始配置不存在'); }
    const ticket = ProfileTransactions.editTicket(this.context, this.file);
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    return { ticket: ticket, original: original, overlay: ProfileStore.getEnabledMerge(this.context, this.file),
      global: EffectiveVersions.globalContent(this.context), settings: JSON.stringify(Settings.load(this.context)),
      region: version !== undefined ? EffectiveVersions.regionPlan(this.context, version) : null,
      intent: ProfileStore.readEditDraft(this.context, this.file).intent };
  }
  private async stamp(input: HostInput): Promise<string> {
    const raw = await core.versionAction(this.context.filesDir, JSON.stringify({ op: 'editor-identity',
      expected: input.ticket.activeVersion, original: input.original, overlay: input.overlay,
      globalMerge: input.global, updateGlobal: true, overrides: input.settings, editIntent: input.intent,
      regionPlan: input.region }));
    const reply = JSON.parse(raw) as HostReply;
    if (reply.error !== undefined || typeof reply.identity !== 'string') { throw new Error('配置已变化，请重新打开'); }
    return reply.identity;
  }
  private async check(revision: string, published: boolean = false): Promise<HostInput> {
    if (this.session === null || this.input === null || revision !== this.session.revision) {
      throw new Error('草稿已变化，请重新打开');
    }
    const before = this.input;
    const now = this.capture();
    const oldTicket = before.ticket; const newTicket = now.ticket;
    if (oldTicket.profileIdentity !== newTicket.profileIdentity || oldTicket.activeFile !== newTicket.activeFile ||
      oldTicket.draftRevision !== newTicket.draftRevision || (!published &&
      (oldTicket.activeVersion !== newTicket.activeVersion || oldTicket.profileVersion !== newTicket.profileVersion))) {
      throw new Error('配置或草稿已变化，请重新打开');
    }
    const identity = await this.stamp(now);
    // Recheck synchronous inputs after the worker await, including draft/source/settings.
    const after = this.capture();
    if (identity !== this.identity || JSON.stringify(now) !== JSON.stringify(after)) {
      throw new Error('配置或资源已变化，请重新打开');
    }
    return now;
  }
  async load(): Promise<EditorDraftSession> {
    const generation = ++this.generation;
    Settings.load(this.context); await Settings.idle();
    const input = this.capture(); const stamp = await this.stamp(input);
    const snapshot = await ConfigEditor.list(this.context, input.original, input.overlay,
      input.ticket.activeVersion, input.global, input.intent ?? undefined, input.region ?? undefined);
    if (generation !== this.generation || JSON.stringify(input) !== JSON.stringify(this.capture()) ||
      stamp !== await this.stamp(input)) { throw new Error('配置已变化，请重新打开'); }
    this.input = input; this.identity = stamp; this.shown = null;
    this.session = { profileId: this.file, revision: util.generateRandomUUID(true), intent: input.intent, snapshot: snapshot };
    return cloneSession(this.session);
  }
  async target(section: string, id: string, revision: string): Promise<EditTarget> {
    const input = await this.check(revision);
    const value = await ConfigEditor.target(this.context, input.original, input.overlay, input.ticket.activeVersion,
      section, id, input.global, input.intent ?? undefined, input.region ?? undefined);
    await this.check(revision); return value;
  }
  async save(intent: EditIntent, expectedRevision: string): Promise<EditorDraftSession> {
    const input = await this.check(expectedRevision);
    await ProfileTransactions.saveEditDraft(this.context, input.ticket, intent, async () => { await this.check(expectedRevision); });
    return await this.load();
  }
  async preview(expectedRevision: string): Promise<EditorDraftPreview> {
    const input = await this.check(expectedRevision);
    const changes = await ProfileTransactions.previewEditDraft(this.context, input.ticket);
    await this.check(expectedRevision);
    this.shown = { revision: expectedRevision, digest: changes.digest, changes: changes };
    return JSON.parse(JSON.stringify(this.shown)) as EditorDraftPreview;
  }
  async apply(preview: EditorDraftPreview): Promise<string> {
    if (this.shown === null || preview.revision !== this.shown.revision || preview.digest !== this.shown.digest) {
      throw new Error('请先重新预览');
    }
    const input = await this.check(preview.revision);
    const result = await ProfileTransactions.applyEditDraft(this.context, input.ticket, preview.digest,
      async (published: boolean) => { await this.check(preview.revision, published); });
    this.session = null; this.input = null; this.shown = null; return result;
  }
  async undo(expectedRevision: string): Promise<EditorDraftSession> {
    const input = await this.check(expectedRevision);
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    const committed = version !== undefined ? EffectiveVersions.editIntent(this.context, version) : null;
    await ProfileTransactions.saveEditDraft(this.context, input.ticket, committed, async () => { await this.check(expectedRevision); });
    return await this.load();
  }
}
export namespace EditorDraftHosts {
  export function create(context: common.Context, file: string): EditorDraftHost { return new ProfileEditorHost(context, file); }
}
