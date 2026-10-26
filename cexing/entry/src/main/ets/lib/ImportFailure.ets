import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { UiText } from './UiText';

const HTTP_CODES: number[] = [301, 302, 303, 304, 307, 308, 400, 401, 403, 404, 405, 408,
  409, 410, 413, 414, 415, 422, 429, 500, 501, 502, 503, 504];

/** Only bounded fields cross the import/presentation boundary; never retain raw errors. */
export class ImportFailure extends Error {
  kind: string;
  stage: string;
  status: number;
  constructor(kind: string, stage: string, status: number = 0) {
    super(kind === 'cancelled' ? '导入已取消' : '配置导入失败');
    this.kind = ['network', 'timeout', 'http', 'format', 'size', 'storage', 'cancelled'].includes(kind) ? kind : 'storage';
    this.stage = ['request', 'read', 'validate', 'prepare', 'write', 'sync', 'close', 'sidecars', 'publish', 'rollback'].includes(stage) ? stage : 'prepare';
    this.status = HTTP_CODES.includes(status) ? status : 0;
  }
}

export namespace ImportFailures {
  export function from(error: Error, stage: string): ImportFailure {
    if (error instanceof ImportFailure) { return new ImportFailure(error.kind, error.stage, error.status); }
    // Exact application-owned messages only. Arbitrary SDK exception text stays private.
    if (error?.message === '导入已取消') { return new ImportFailure('cancelled', stage); }
    if (['配置超过 15 MiB 上限', '文件大小不符或超过上限'].includes(error?.message)) {
      return new ImportFailure('size', stage);
    }
    if (['配置编码无效', '内容为空或过短', '不是合法的 mihomo 配置（缺少 proxies/proxy-groups）'].includes(error?.message)) {
      return new ImportFailure('format', stage);
    }
    // NetworkKit request timeout; no numeric data extracted from exception text.
    const code = (error as BusinessError)?.code;
    if (stage === 'request') {
      return new ImportFailure(code === 2300028 ? 'timeout' : code === 2300063 ? 'size' : 'network', stage);
    }
    return new ImportFailure(stage === 'validate' ? 'format' : 'storage', stage);
  }

  export function http(status: number): ImportFailure {
    return Number.isInteger(status) && status >= 100 && status <= 599 ?
      new ImportFailure('http', 'request', status) : new ImportFailure('network', 'request');
  }

  export function label(error: Error, stage: string): string {
    const failure = from(error, stage);
    if (failure.kind !== 'cancelled') {
      Logger.warn('profileImport', `stage=${failure.stage} kind=${failure.kind} status=${failure.status}`);
    }
    switch (failure.kind) {
      case 'cancelled': return '';
      case 'network': return UiText.get($r('app.string.import_error_network'));
      case 'timeout': return UiText.get($r('app.string.import_error_timeout'));
      case 'http': return failure.status === 0 ? UiText.get($r('app.string.import_error_http_generic')) :
        UiText.get($r('app.string.import_error_http'), failure.status);
      case 'format': return UiText.get($r('app.string.import_error_format'));
      case 'size': return UiText.get($r('app.string.import_error_size'));
      default: return failure.stage === 'rollback' ? UiText.get($r('app.string.import_error_cleanup')) :
        UiText.get($r('app.string.import_error_storage'));
    }
  }
}
