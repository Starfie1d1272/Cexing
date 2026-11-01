import { connection } from '@kit.NetworkKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppIdentityBatch, AppIdentityReply, AppIdentityRequest, CoreApi } from './CoreApi';

/** VPN extension owned; bounded asynchronous lookups never hold up TUN forwarding. */
export class AppTrafficIdentity {
  private watcher = new CoreApi.StreamWatcher<AppIdentityBatch>();
  private generation: number = 0;
  private pending: number = 0;
  private lookups: number = 0;
  private session: string = '';

  start(): void {
    this.stop();
    const generation = this.generation;
    this.watcher.start('/ohos/app-traffic/identity', (batch: AppIdentityBatch) => {
      if (generation !== this.generation || !Array.isArray(batch.requests) || batch.requests.length > 32) { return; }
      if (this.session.length === 0) { this.session = batch.session; }
      if (batch.session !== this.session || batch.requests.length === 0 || this.pending >= 4) { return; }
      this.pending++;
      this.resolveBatch(batch, generation).catch(() => {}).finally(() => {
        if (generation === this.generation) { this.pending--; }
      });
    });
  }

  stop(): void {
    this.generation++;
    this.watcher.stop();
    this.pending = 0;
    this.session = '';
  }

  private async resolveBatch(batch: AppIdentityBatch, generation: number): Promise<void> {
    const replies = await Promise.all(batch.requests.map((request: AppIdentityRequest) => this.resolveWithDeadline(request)));
    if (generation !== this.generation || batch.session !== this.session) { return; }
    await CoreApi.replyAppIdentities(batch.session, replies);
  }

  private async resolveWithDeadline(request: AppIdentityRequest): Promise<AppIdentityReply> {
    const timeout: AppIdentityReply = { id: request.id, uid: -1, status: 'timeout' };
    // A timed-out platform promise still owns its slot until it actually settles.
    // This cap survives stop/start, so a stuck system service cannot grow work forever.
    if (this.lookups >= 128) { return timeout; }
    this.lookups++;
    let timer = -1;
    const deadline = new Promise<AppIdentityReply>((resolve) => {
      timer = setTimeout(() => resolve(timeout), 3000);
    });
    const lookup = this.resolve(request).finally(() => { this.lookups--; });
    const reply = await Promise.race([lookup, deadline]);
    if (timer >= 0) { clearTimeout(timer); }
    return reply;
  }

  private async resolve(request: AppIdentityRequest): Promise<AppIdentityReply> {
    const reply: AppIdentityReply = { id: request.id, uid: -1, status: 'unsupported' };
    // API 22 still forwards and accounts unknown traffic; never call missing symbols.
    if (deviceInfo.sdkApiVersion < 23) { return reply; }
    if ((request.protocol !== 'tcp' && request.protocol !== 'udp') || request.local.port <= 0 || request.remote.port <= 0) {
      reply.status = 'error';
      return reply;
    }
    try {
      const protocol = request.protocol === 'tcp' ? connection.ProtocolType.PROTO_TYPE_TCP : connection.ProtocolType.PROTO_TYPE_UDP;
      // Official UDP lookup may fall back to the local tuple. Do not infer a UID ourselves.
      const uid = await connection.getConnectOwnerUid(protocol, request.local, request.remote);
      if (uid < 0) { reply.status = 'notFound'; return reply; }
      // A UID is not a verified application bundle (shared UIDs are possible).
      reply.uid = uid;
      reply.status = 'uid';
    } catch (_) { reply.status = 'error'; }
    return reply;
  }
}
