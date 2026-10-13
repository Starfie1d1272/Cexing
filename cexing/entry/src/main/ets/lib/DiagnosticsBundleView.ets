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
    if (kind === 'connection') { return '代理连接'; }
    if (kind === 'delay') { return '代理延迟'; }
    if (kind === 'bandwidth') { return '带宽测速'; }
    return '本机服务';
  }

  static result(result: DiagnosticCheckResult): string {
    if (result.reason === 'page_check_timeout') { return '检查超时'; }
    if (result.stage === 'controller_credentials') { return '连接信息不可用，请重新连接'; }
    if (result.stage === 'controller_authorization') { return '连接认证失败，请断开后重新连接'; }
    if (result.reason === 'core_not_ready') { return '尚未执行，请先连接 VPN'; }
    if (result.reason === 'proxy_not_selected') { return '尚未执行，请先选择测试代理'; }
    if (result.kind === 'bandwidth') { return '本页不执行带宽测速'; }
    if (result.outcome === 'success') {
      return result.kind === 'controller' ? '本机服务可达' : `${DiagnosticsBundleView.title(result.kind)}检查通过`;
    }
    if (result.outcome === 'skipped') { return '检查未执行，原因已记录在诊断包'; }
    const code = result.error?.code;
    const suffix = code !== undefined && /^[A-Za-z0-9_-]{1,64}$/.test(code) ? `（错误码 ${code}）` : '';
    return result.outcome === 'failed' ? `检查失败${suffix}，可保存诊断包排查` : '检查结果待确认，可保存诊断包排查';
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
        const label = `${lane === 'host' ? '应用' : '内核'} · ${age === 'current' ? '当前会话' : age === 'previous' ? '上一会话' : '更早会话'}`;
        if (source === undefined) { facts.push(`${label}：没有保留证据`); continue; }
        if (source.status === 'missing') { facts.push(`${label}：没有保留该会话证据，可能为首次启用或已轮转`); }
        else if (source.status !== 'available') {
          facts.push(`${label}：${source.status === 'invalid' ? '证据文件损坏或超过限制' : '证据无法读取'}`);
        } else { facts.push(`${label}：${source.journal?.events?.length ?? 0} 条记录`); }
        const omitted = DiagnosticsBundleView.count(source.exportOmitted);
        const dropped = DiagnosticsBundleView.count(source.journal?.dropped);
        const failed = Math.max(DiagnosticsBundleView.count(source.journal?.writeFailures), DiagnosticsBundleView.count(source.liveWriteFailures));
        const pending = DiagnosticsBundleView.count(source.unpersistedEvents);
        const suppressed = DiagnosticsBundleView.count(source.journal?.logSuppressed);
        if (omitted + dropped + failed + pending + suppressed > 0) {
          facts.push(`${label}：记录丢弃 ${dropped}，导出省略 ${omitted}，写入失败 ${failed}，未落盘 ${pending}，限流省略 ${suppressed}`);
        }
      }
    }
    if (bundle.exportContextCollected !== true) { facts.push('应用环境快照未采集完整'); }
    if (bundle.selectedVersion?.['effectiveVersion'] === 'unknown') { facts.push('有效配置版本未确认'); }
    for (const kind of ['controller', 'dns', 'connection', 'delay', 'bandwidth']) {
      const value = bundle.checkCoverage?.[kind];
      if (Array.isArray(value) && value.length > 0) {
        facts.push(`${DiagnosticsBundleView.title(kind)}：包内保留 ${value.length} 条检查记录`);
      } else {
        facts.push(`${DiagnosticsBundleView.title(kind)}：没有保留检查结果，不能据此判断是否执行过`);
      }
    }
    facts.push('每个来源保留当前与两次历史进程会话；更早证据可能已轮转。');
    facts.push('带宽测速需单独主动执行；本页仅提供低流量检查。');
    return facts;
  }
}
