import { http } from '@kit.NetworkKit';
import { CoreApi } from './CoreApi';

export interface AiServiceResult { service: string; state: string; at: string; retryAt?: string; }
interface AiProbeFailure { message?: string; }
interface AiProbeResponse { revision: string; results: AiServiceResult[]; }

// A page-owned observer. Destroying its request cancels server work and closes
// its ephemeral listener, without affecting VPN/configuration lifecycle.
export class AiProbeService {
  private request: http.HttpRequest | null = null;
  private generation: number = 0;
  private alive: () => boolean;
  private changed: (results: AiServiceResult[], checking: boolean, state?: string) => void;

  constructor(alive: () => boolean, changed: (results: AiServiceResult[], checking: boolean, state?: string) => void) {
    this.alive = alive;
    this.changed = changed;
  }
  cancel(): void {
    this.generation++;
    this.request?.destroy();
    this.request = null;
  }
  async check(revision: string, retry: boolean = false): Promise<void> {
    if (this.request !== null || !this.alive() || revision.length === 0) { return; }
    const access = CoreApi.getControllerAccess();
    // ControllerAccess is used exclusively for the existing loopback API, never
    // sent to the official HTTPS services. There is no direct/proxy fallback.
    if (access === null || access.httpBase !== 'http://127.0.0.1:9090') { this.changed([], false); return; }
    const epoch = ++this.generation;
    const request = http.createHttp();
    this.request = request;
    this.changed([], true);
    try {
      const response = await request.request(`${access.httpBase}/ohos/ai-probe`, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${access.secret}` },
        extraData: JSON.stringify({ revision: revision, retry: retry }),
        connectTimeout: 2000, readTimeout: 20000, maxLimit: 8192,
        expectDataType: http.HttpDataType.STRING
      });
      if (epoch !== this.generation || !this.alive()) { return; }
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length > 8192) {
        let reason = '';
        if (response.responseCode === 409 && typeof response.result === 'string' && response.result.length <= 8192) {
          const failure = JSON.parse(response.result) as AiProbeFailure;
          if (failure.message === 'PROBE_ROUTE_UNPROVEN') { reason = 'route_unproven'; }
        }
        this.changed([], false, reason); return;
      }
      const result = JSON.parse(response.result) as AiProbeResponse;
      if (result.revision !== revision || !Array.isArray(result.results) || result.results.length !== 3) {
        this.changed([], false); return;
      }
      const expected: string[] = ['chatgpt', 'claude', 'gemini'];
      const allowed: string[] = ['reachable', 'region_restricted', 'limited', 'timeout', 'network_failed', 'unknown'];
      for (let i = 0; i < expected.length; i++) {
        const entry = result.results[i];
        if (entry.service !== expected[i] || !allowed.includes(entry.state) || !Number.isFinite(Date.parse(entry.at))) {
          this.changed([], false); return;
        }
      }
      this.changed(result.results, false);
    } catch (_) { if (epoch === this.generation && this.alive()) { this.changed([], false); } }
    finally {
      if (this.request === request) { this.request = null; request.destroy(); }
    }
  }
}
