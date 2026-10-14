import { UiText } from './UiText';
import { DiagnosticCheckResult } from './DiagnosticsService';

interface BundleJournal { events?: Object[]; dropped?: number; writeFailures?: number; logSuppressed?: number; }
interface BundleSource {
  name: string;
  status: string;
  journal?: BundleJournal;
  exportOmitted?: number;
  liveWriteFailures?: number;
  unpersistedEvents?: number;
}
interface BundlePreview {
  schema: string;
  sources: BundleSource[];
  exportContextCollected?: boolean;
  selectedVersion?: Record<string, Object>;
  checkCoverage?: Record<string, Object>;
}

export class DiagnosticsBundleView {
  static title(kind: string): string {
    if (kind === 'dns') { return 'DNS'; }
    if (kind === 'connection') { return UiText.get($r('app.string.diag_title_connection')); }
    if (kind === 'delay') { return UiText.get($r('app.string.diag_title_delay')); }
    if (kind === 'bandwidth') { return UiText.get($r('app.string.diag_title_bandwidth')); }
    return UiText.get($r('app.string.diag_local_service'));
  }

  static result(result: DiagnosticCheckResult): string {
    if (result.reason === 'page_check_timeout') { return UiText.get($r('app.string.diag_timeout')); }
    if (result.stage === 'controller_credentials') { return UiText.get($r('app.string.diag_credentials_failed')); }
    if (result.stage === 'controller_authorization') { return UiText.get($r('app.string.diag_auth_failed')); }
    if (result.reason === 'core_not_ready') { return UiText.get($r('app.string.diag_connect_first')); }
    if (result.reason === 'proxy_not_selected') { return UiText.get($r('app.string.diag_proxy_first')); }
    if (result.kind === 'bandwidth') { return UiText.get($r('app.string.diag_bandwidth_disabled')); }
    if (result.outcome === 'success') {
      return result.kind === 'controller' ? UiText.get($r('app.string.diag_reachable')) : UiText.get($r('app.string.diag_passed'), DiagnosticsBundleView.title(result.kind));
    }
    if (result.outcome === 'skipped') { return UiText.get($r('app.string.diag_skipped')); }
    const code = result.error?.code;
    const suffix = code !== undefined && /^[A-Za-z0-9_-]{1,64}$/.test(code) ? UiText.get($r('app.string.diag_error_code'), code) : '';
    return result.outcome === 'failed' ? UiText.get($r('app.string.diag_failed'), suffix) : UiText.get($r('app.string.diag_unknown'));
  }

  private static count(value?: number): number {
    return value !== undefined && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
  }

  static facts(json: string): string[] {
    if (json.length > 1024 * 1024) { throw new Error('invalid bundle'); }
    const bundle = JSON.parse(json) as BundlePreview;
    if (bundle.schema !== 'cexing-support-bundle/1' || !Array.isArray(bundle.sources)) {
      throw new Error('invalid bundle');
    }
    const facts: string[] = [];
    for (const lane of ['host', 'kernel']) {
      for (const age of ['current', 'previous', 'older']) {
        const name = `${lane}-${age}`;
        const source = bundle.sources.find((item: BundleSource) => item.name === name);
        const label = UiText.get($r('app.string.diag_fact_label'), lane === 'host' ? UiText.get($r('app.string.diag_fact_host')) : UiText.get($r('app.string.diag_fact_kernel')), age === 'current' ? UiText.get($r('app.string.diag_fact_current')) : age === 'previous' ? UiText.get($r('app.string.diag_fact_previous')) : UiText.get($r('app.string.diag_fact_older')));
        if (source === undefined) { facts.push(UiText.get($r('app.string.diag_fact_line'), label, UiText.get($r('app.string.diag_fact_no_evidence')))); continue; }
        if (source.status === 'missing') { facts.push(UiText.get($r('app.string.diag_fact_line'), label, UiText.get($r('app.string.diag_fact_missing')))); }
        else if (source.status !== 'available') {
          facts.push(UiText.get($r('app.string.diag_fact_line'), label, source.status === 'invalid' ? UiText.get($r('app.string.diag_fact_invalid')) : UiText.get($r('app.string.diag_fact_unreadable'))));
        } else { facts.push(UiText.get($r('app.string.diag_fact_count'), label, source.journal?.events?.length ?? 0)); }
        const omitted = DiagnosticsBundleView.count(source.exportOmitted);
        const dropped = DiagnosticsBundleView.count(source.journal?.dropped);
        const failed = Math.max(DiagnosticsBundleView.count(source.journal?.writeFailures), DiagnosticsBundleView.count(source.liveWriteFailures));
        const pending = DiagnosticsBundleView.count(source.unpersistedEvents);
        const suppressed = DiagnosticsBundleView.count(source.journal?.logSuppressed);
        if (omitted + dropped + failed + pending + suppressed > 0) {
          facts.push(UiText.get($r('app.string.diag_fact_losses'), label, dropped, omitted, failed, pending, suppressed));
        }
      }
    }
    if (bundle.exportContextCollected !== true) { facts.push(UiText.get($r('app.string.diag_fact_environment'))); }
    if (bundle.selectedVersion?.['effectiveVersion'] === 'unknown') { facts.push(UiText.get($r('app.string.diag_fact_version'))); }
    for (const kind of ['controller', 'dns', 'connection', 'delay', 'bandwidth']) {
      const value = bundle.checkCoverage?.[kind];
      if (Array.isArray(value) && value.length > 0) {
        facts.push(UiText.get($r('app.string.diag_fact_checks'), DiagnosticsBundleView.title(kind), value.length));
      } else {
        facts.push(UiText.get($r('app.string.diag_fact_no_checks'), DiagnosticsBundleView.title(kind)));
      }
    }
    facts.push(UiText.get($r('app.string.diag_fact_retention')));
    facts.push(UiText.get($r('app.string.diag_fact_bandwidth')));
    return facts;
  }
}
