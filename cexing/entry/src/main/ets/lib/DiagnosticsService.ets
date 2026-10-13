/* Local support evidence on the existing Go worker. No upload, raw YAML,
 * subscription metadata, credentials or successful connection history. */
import { common, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import core from 'libentry.so';
import { CoreApi } from './CoreApi';
import { Settings } from './Settings';
import { VpnController, VpnStatus } from './VpnController';

export type DiagnosticOutcome = 'started' | 'success' | 'failed' | 'skipped' | 'unknown' | 'cancelled';
export type DiagnosticCheckKind = 'controller' | 'dns' | 'connection' | 'delay' | 'bandwidth';
export interface DiagnosticPhase {
  operation: string;
  stage: string;
  outcome: DiagnosticOutcome;
  object?: string;
  reason?: string;
  code?: string;
  durationMs?: number;
}
export interface DiagnosticFailure {
  kind: string;
  code?: string;
  message: string;
  causes?: DiagnosticFailure[];
}
export interface DiagnosticCheckResult {
  kind: DiagnosticCheckKind;
  stage: string;
  outcome: DiagnosticOutcome;
  at: string;
  durationMs: number;
  reason?: string;
  error?: DiagnosticFailure;
  details?: Record<string, Object>;
}
export interface DiagnosticExport {
  json: string;
  path: string;
  fileName: string;
}
interface DiagnosticRequest {
  op: string;
  contextCollected?: boolean;
  operation?: string;
  stage?: string;
  outcome?: string;
  object?: string;
  reason?: string;
  code?: string;
  durationMs?: number;
  environment?: Record<string, Object>;
  settings?: Record<string, Object>;
  observations?: Record<string, Object>;
}
interface DiagnosticResponse { error?: string; recorded?: boolean; schema?: string; }

export namespace DiagnosticsService {
  let initializedDir: string = '';
  let initializing: Promise<boolean> | null = null;

  async function call(context: common.Context, request: DiagnosticRequest): Promise<string> {
    return core.versionAction(context.filesDir, JSON.stringify(request));
  }

  /** Called once by AppRuntime before recovery; repeated calls are idempotent.
   * Export also calls it, retaining previous sessions even if UI opened first. */
  export async function initialize(context: common.Context): Promise<boolean> {
    if (initializedDir === context.filesDir) { return true; }
    if (initializing !== null) { return initializing; }
    initializing = snapshot(context).then((ok: boolean) => {
      if (ok) { initializedDir = context.filesDir; }
      return ok;
    }).finally(() => { initializing = null; });
    return initializing;
  }

  /** AppRuntime owns this subscription; dispose only at process/runtime teardown,
   * never at a page teardown. Reads getters without consuming or controlling VPN. */
  export function observe(context: common.Context): () => void {
    const capture = (status: VpnStatus): void => {
      const names = ['disconnected', 'connecting', 'connected', 'disconnecting'];
      const failure = VpnController.getLastStartFailure();
      const stop = VpnController.getLastStopCompleted();
      const observations: Record<string, Object> = {
        vpnState: names[status] ?? 'unknown', tunCreateObserved: VpnController.getTunCreateObserved(),
        kernelReadyReported: VpnController.getKernelReadyReported(),
        stopOutcome: stop === null ? 'not_reported' : stop ? 'completed' : 'unknown',
        substageCoverage: 'system_authorization_binding_protect_assets_not_observable_via_status_getters'
      };
      if (failure !== null) { observations['failureCategory'] = failure.category; }
      const request: DiagnosticRequest = { op: 'diagnostics-record', operation: 'vpn',
        stage: failure?.phase ?? 'state_observation', outcome: failure === null ? 'observed' : 'failed',
        code: failure === null || failure.code === 0 ? undefined : `${failure.code}`, observations: observations };
      call(context, request).catch(() => {});
    };
    initialize(context).then(() => capture(VpnController.status)).catch(() => {});
    VpnController.onChanged(capture);
    return (): void => { VpnController.offChanged(capture); };
  }

  /** Structured codes only. Never pass exception.message, Wants or raw config.
   * Failure is observable but must not change VPN control state. */
  export async function record(context: common.Context, phase: DiagnosticPhase): Promise<boolean> {
    try {
      const text = await call(context, { op: 'diagnostics-record', operation: phase.operation,
        stage: phase.stage, outcome: phase.outcome, object: phase.object, reason: phase.reason,
        code: phase.code, durationMs: phase.durationMs });
      return (JSON.parse(text) as DiagnosticResponse).recorded === true;
    } catch (_) { return false; }
  }

  async function snapshot(context: common.Context): Promise<boolean> {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const settings = Settings.load(context);
      const text = await call(context, { op: 'diagnostics-record', operation: 'host',
        stage: 'environment', outcome: 'success', environment: {
          appVersion: info.versionName, versionCode: info.versionCode,
          sdkVersion: deviceInfo.sdkApiVersion, osVersion: deviceInfo.osFullName,
          deviceType: deviceInfo.deviceType, abi: deviceInfo.abiList
        }, settings: {
          keepAlive: settings.keepAlive, ipv6: settings.ipv6, allowLan: settings.allowLan,
          logToFile: settings.logToFile, smartAutoConvert: settings.smartAutoConvert,
          autoUpdate: settings.autoUpdate, autoRestore: settings.autoRestore,
          mixedPort: settings.mixedPort, autoUpdateIntervalHours: settings.autoUpdateIntervalHours,
          accessMode: settings.accessMode, mode: settings.mode, logLevel: settings.logLevel
        } });
      return (JSON.parse(text) as DiagnosticResponse).recorded === true;
    } catch (_) { return false; }
  }

  /** Explicit low-traffic checks only: one DNS query or HTTPS HEAD through the
   * selected adapter. No bandwidth transfer or automatic checks at export. */
  export async function check(context: common.Context, kind: DiagnosticCheckKind,
    proxy: string = ''): Promise<DiagnosticCheckResult> {
    await initialize(context);
    const started = Date.now();
    const result: DiagnosticCheckResult = { kind: kind, stage: 'controller_transport',
      outcome: 'unknown', at: new Date(started).toISOString(), durationMs: 0 };
    if (kind === 'bandwidth') {
      result.stage = 'precondition'; result.outcome = 'skipped';
      result.reason = 'requires_explicit_bandwidth_test';
      await persistCheck(context, result, proxy); return result;
    }
    const access = CoreApi.getControllerAccess();
    if (access === null) {
      result.stage = 'controller_credentials'; result.outcome = 'failed';
      result.reason = 'credentials_unavailable';
      await persistCheck(context, result, proxy); return result;
    }
    const request = http.createHttp();
    try {
      const response = await request.request(access.httpBase +
        (kind === 'controller' ? '/version' : '/ohos/diagnostics/check'), {
        method: kind === 'controller' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: { 'Authorization': `Bearer ${access.secret}`, 'Content-Type': 'application/json' },
        extraData: kind === 'controller' ? undefined : JSON.stringify({ kind: kind, proxy: proxy }),
        connectTimeout: 4000, readTimeout: 10000
      });
      if (response.responseCode !== 200) {
        result.stage = response.responseCode === 401 || response.responseCode === 403 ?
          'controller_authorization' : 'controller_http';
        result.outcome = 'failed'; result.error = { kind: 'http_status',
          code: `${response.responseCode}`, message: 'local controller rejected diagnostic request' };
      } else {
        const text = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
        if (kind === 'controller') {
          const version = JSON.parse(text) as Record<string, Object>;
          if (typeof version['version'] !== 'string') { throw new Error('invalid version'); }
          result.stage = 'controller_version'; result.outcome = 'success';
        } else {
          const parsed = JSON.parse(text) as DiagnosticCheckResult;
          if (parsed.kind !== kind || typeof parsed.stage !== 'string' || typeof parsed.at !== 'string' ||
            !['success', 'failed', 'skipped'].includes(parsed.outcome)) { throw new Error('invalid diagnostic result'); }
          // Kernel journal already includes the actual failure cause and phase.
          result.stage = parsed.stage; result.outcome = parsed.outcome; result.reason = parsed.reason;
          result.error = parsed.error; result.details = parsed.details;
        }
      }
    } catch (error) {
      result.outcome = 'failed';
      const code = (error as DiagnosticFailure).code;
      result.error = { kind: 'platform_transport', code: `${code ?? 'unknown'}`,
        message: 'local controller request failed' };
    } finally { request.destroy(); }
    result.durationMs = Date.now() - started;
    await persistCheck(context, result, proxy); return result;
  }

  async function persistCheck(context: common.Context, result: DiagnosticCheckResult,
    proxy: string): Promise<void> {
    const ok = await record(context, { operation: `check_${result.kind}`, stage: result.stage,
      outcome: result.outcome, object: proxy, reason: result.reason,
      code: result.error?.code, durationMs: result.durationMs });
    if (!ok) { result.details = { evidencePersisted: false }; }
  }

  /** A reviewable local JSON file; the page owns DocumentViewPicker/save or
   * share. Reuses one cache file so repeated exports do not grow the sandbox. */
  export async function exportBundle(context: common.Context): Promise<DiagnosticExport> {
    await initialize(context);
    const collected = await snapshot(context);
    const json = await call(context, { op: 'diagnostics-export', contextCollected: collected });
    const response = JSON.parse(json) as DiagnosticResponse;
    if (response.schema !== 'cexing-support-bundle/1') { throw new Error('诊断包生成失败，历史证据未删除'); }
    const path = `${context.cacheDir}/cexing-support.json`;
    const temp = `${path}.pending`;
    const file = fileIo.openSync(temp, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, json); } finally { fileIo.closeSync(file); }
    fileIo.moveFileSync(temp, path);
    return { json: json, path: path, fileName: 'cexing-support.json' };
  }
}
