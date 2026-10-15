import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import core from 'libentry.so';
import { ConfigEditor, EditIntent, EditTarget, EditorDraftHost, EditorDraftSession, EditorDraftPreview, RoutingCatalogue, SmartGroupChange } from './ConfigEditor';
import { Settings } from './Settings';
import { EffectiveVersions, RegionPlan } from './EffectiveVersions';
import { ProfileStore, ProfileMetaExt } from './ProfileStore';
import { ProfileTransactions, EditTicket, EditorSourceCandidate } from './ProfileTransactions';

export { EditorSourceCandidate } from './ProfileTransactions';

interface HostInput {
  ticket: EditTicket; committedOriginal: string; projectionOriginal: string; original: string; metadata: string; overlay: string; global: string;
  settings: string; region: RegionPlan | null; intent: EditIntent | null;
}
interface HostReply { identity?: string; error?: string; }
function sameInput(a: HostInput, b: HostInput): boolean {
  // Compare large immutable strings directly; do not serialize three copies of
  // the full Original merely to fence an asynchronous read.
  return a.committedOriginal === b.committedOriginal && a.projectionOriginal === b.projectionOriginal &&
    a.original === b.original && a.metadata === b.metadata && a.overlay === b.overlay &&
    a.global === b.global && a.settings === b.settings && JSON.stringify(a.ticket) === JSON.stringify(b.ticket) &&
    JSON.stringify(a.region) === JSON.stringify(b.region) && JSON.stringify(a.intent) === JSON.stringify(b.intent);
}

function cloneSession(value: EditorDraftSession): EditorDraftSession {
  return JSON.parse(JSON.stringify(value)) as EditorDraftSession;
}

/** One stable profile per instance; no page-owned persistence or publisher. */
class ProfileEditorHost implements EditorDraftHost {
  private context: common.Context;
  private file: string;
  private source: EditorSourceCandidate | undefined;
  private resolved: boolean = false;
  private projectionOriginal: string = '';
  private input: HostInput | null = null;
  private identity: string = '';
  private session: EditorDraftSession | null = null;
  private shown: EditorDraftPreview | null = null;
  private generation: number = 0;
  constructor(context: common.Context, file: string, source?: EditorSourceCandidate) {
    this.context = context; this.file = file;
    if (source !== undefined) {
      this.source = { original: source.original,
        metadata: JSON.parse(JSON.stringify(source.metadata)) as ProfileMetaExt };
      this.source.original = ProfileStore.prepareContent(this.source.original);
      if (JSON.stringify(this.source.metadata).length > 65536) { throw new Error('配置资料超限'); }
    }
  }

  async routingCatalogue(revision: string): Promise<RoutingCatalogue> {
    const input = await this.check(revision);
    const raw = await core.versionAction(this.context.filesDir, JSON.stringify({ op: 'routing-catalogue',
      original: input.original, overlay: input.overlay, globalMerge: input.global, updateGlobal: true,
      expected: input.ticket.activeVersion, editIntent: input.intent }));
    const reply = JSON.parse(raw) as Record<string, Object>;
    await this.check(revision);
    if (reply['error'] !== undefined || reply['routingCatalogue'] === undefined) { throw new Error('ROUTING_CATALOGUE_FAILED'); }
    return reply['routingCatalogue'] as RoutingCatalogue;
  }
  async smartChoices(revision: string): Promise<SmartGroupChange[]> {
    const input = await this.check(revision);
    const view = await ConfigEditor.smartPreview(this.context, input.original, input.overlay,
      input.ticket.activeVersion, false, input.intent ?? undefined, input.global, input.region ?? undefined);
    await this.check(revision); return view;
  }
  private capture(): HostInput {
    const original = ProfileStore.getProfileContent(this.context, this.file);
    if (original === null) { throw new Error('原始配置不存在'); }
    const ticket = ProfileTransactions.editTicket(this.context, this.file);
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    return { ticket: ticket, committedOriginal: original, projectionOriginal: this.source !== undefined && !this.resolved ? this.projectionOriginal : this.source?.original ?? original,
      original: this.source?.original ?? original,
      metadata: this.source !== undefined ? JSON.stringify(this.source.metadata) : '', overlay: ProfileStore.getEnabledMerge(this.context, this.file),
      global: EffectiveVersions.globalContent(this.context), settings: JSON.stringify(Settings.load(this.context)),
      region: version !== undefined ? EffectiveVersions.regionPlan(this.context, version) : null,
      intent: ProfileStore.readEditDraft(this.context, this.file).intent };
  }
  private async stamp(input: HostInput): Promise<string> {
    const identity = async (original: string, intent: EditIntent | null, region: RegionPlan | null): Promise<string> => {
      const raw = await core.versionAction(this.context.filesDir, JSON.stringify({ op: 'editor-identity',
        metadata: input.metadata, expected: input.ticket.activeVersion, original: original, overlay: input.overlay,
        globalMerge: input.global, updateGlobal: true, overrides: input.settings, editIntent: intent,
        regionPlan: region }));
      const reply = JSON.parse(raw) as HostReply;
      if (reply.error !== undefined || typeof reply.identity !== 'string') { throw new Error('配置已变化，请重新打开'); }
      return reply.identity;
    };
    const projection = await identity(input.projectionOriginal, input.intent, input.region);
    // An unresolved source update must reach the conflict view. Bind both the
    // successful authoring resources and raw candidate resources without trying
    // to apply stale personal preconditions to the downloaded Original.
    if (this.source !== undefined) {
      return `${projection}:${await identity(input.original, null, null)}`;
    }
    return projection;
  }
  private async check(revision: string, published: boolean = false): Promise<HostInput> {
    if (this.session === null || this.input === null || revision !== this.session.revision) {
      throw new Error('草稿已变化，请重新打开');
    }
    const before = this.input;
    const now = this.capture();
    const oldTicket = before.ticket; const newTicket = now.ticket;
    if ((!published && before.committedOriginal !== now.committedOriginal) ||
      (published && this.source !== undefined && now.committedOriginal !== this.source.original) || oldTicket.profileIdentity !== newTicket.profileIdentity || oldTicket.activeFile !== newTicket.activeFile ||
      oldTicket.draftRevision !== newTicket.draftRevision || (!published &&
      (oldTicket.activeVersion !== newTicket.activeVersion || oldTicket.profileVersion !== newTicket.profileVersion))) {
      throw new Error('配置或草稿已变化，请重新打开');
    }
    const identity = await this.stamp(now);
    // Recheck synchronous inputs after the worker await, including draft/source/settings.
    const after = this.capture();
    if (identity !== this.identity || !sameInput(now, after)) {
      throw new Error('配置或资源已变化，请重新打开');
    }
    return now;
  }
  async load(): Promise<EditorDraftSession> {
    const generation = ++this.generation;
    Settings.load(this.context); await Settings.idle();
    this.projectionOriginal = ProfileStore.getProfileContent(this.context, this.file) ?? '';
    const draft = ProfileStore.readEditDraft(this.context, this.file);
    if (draft.source !== undefined) {
      const ticket = ProfileTransactions.editTicket(this.context, this.file);
      const restored = await ProfileStore.readEditDraftSource(this.context, this.file, draft.revision,
        () => generation === this.generation);
      const digest = await EffectiveVersions.originalIdentity(this.context, this.projectionOriginal, ticket.activeVersion);
      if (JSON.stringify(ticket) !== JSON.stringify(ProfileTransactions.editTicket(this.context, this.file)) ||
        this.projectionOriginal !== ProfileStore.getProfileContent(this.context, this.file) ||
        restored === undefined || draft.source.profileIdentity !== ticket.profileIdentity ||
        draft.source.profileVersion !== ticket.profileVersion || draft.source.baseDigest !== digest) {
        throw new Error('草稿来源已变化，请先处理已有草稿');
      }
      if (this.source !== undefined && (this.source.original !== restored.original ||
        JSON.stringify(this.source.metadata) !== JSON.stringify(restored.metadata))) {
        throw new Error('请先处理已有的更新草稿');
      }
      this.source = restored; this.resolved = true;
    }
    const input = this.capture(); const stamp = await this.stamp(input);
    const snapshot = await ConfigEditor.list(this.context, input.projectionOriginal, input.overlay,
      input.ticket.activeVersion, input.global, input.intent ?? undefined, input.region ?? undefined);
    if (generation !== this.generation || !sameInput(input, this.capture()) ||
      stamp !== await this.stamp(input)) { throw new Error('配置已变化，请重新打开'); }
    this.input = input; this.identity = stamp; this.shown = null;
    this.session = { profileId: this.file, revision: util.generateRandomUUID(true), intent: input.intent, snapshot: snapshot };
    return cloneSession(this.session);
  }
  async target(section: string, id: string, revision: string): Promise<EditTarget> {
    const input = await this.check(revision);
    const value = await ConfigEditor.target(this.context, input.projectionOriginal, input.overlay, input.ticket.activeVersion,
      section, id, input.global, input.intent ?? undefined, input.region ?? undefined);
    await this.check(revision); return value;
  }
  async save(intent: EditIntent, expectedRevision: string): Promise<EditorDraftSession> {
    const input = await this.check(expectedRevision);
    await ProfileTransactions.saveEditDraft(this.context, input.ticket, intent, async () => { await this.check(expectedRevision); }, this.source);
    this.resolved = true;
    return await this.load();
  }
  async preview(expectedRevision: string): Promise<EditorDraftPreview> {
    const input = await this.check(expectedRevision);
    const changes = await ProfileTransactions.previewEditDraft(this.context, input.ticket, this.source);
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
      async (published: boolean) => { await this.check(preview.revision, published); }, this.source);
    this.session = null; this.input = null; this.shown = null; return result;
  }
  async undo(expectedRevision: string): Promise<EditorDraftSession> {
    const input = await this.check(expectedRevision);
    const version = EffectiveVersions.read(this.context)?.Profiles[this.file];
    const committed = version !== undefined ? EffectiveVersions.editIntent(this.context, version) : null;
    await ProfileTransactions.saveEditDraft(this.context, input.ticket, committed, async () => { await this.check(expectedRevision); }, null);
    this.source = undefined; this.resolved = false;
    return await this.load();
  }
}
export namespace EditorDraftHosts {
  export function create(context: common.Context, file: string, sourceOverride?: EditorSourceCandidate): EditorDraftHost {
    return new ProfileEditorHost(context, file, sourceOverride);
  }
}
