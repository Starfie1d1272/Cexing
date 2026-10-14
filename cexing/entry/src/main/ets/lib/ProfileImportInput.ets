import { Want } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { promptAction } from '@kit.ArkUI';

export interface ProfileImportCandidate { kind: string; value: string; }

/** Untrusted external input is only queued for a visible, explicit confirmation. */
export namespace ProfileImportInput {
  let pending: ProfileImportCandidate | null = null;
  let lastValue: string = '';
  let revision: number = 0;
  let delivery: number = 0;

  export function parseText(input: string): ProfileImportCandidate | null {
    if (input.length > 8192 || /[\u0000-\u001f\u007f]/.test(input)) { return null; }
    let value = input.trim();
    if (/[\u0000-\u001f\u007f]/.test(value)) { return null; }
    const wrapped = /^(?:cexing:\/\/import|clash:\/\/install-config)\?(.+)$/i.exec(value);
    if (wrapped !== null) {
      const values = wrapped[1].split('&').filter((part: string) => part.startsWith('url='));
      if (values.length !== 1) { return null; }
      try { value = decodeURIComponent(values[0].slice(4)); } catch (_) { return null; }
    }
    if (!/^https:\/\/(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?|\[[0-9a-f:]+\])(?::[0-9]{1,5})?(?:[/?][^\s#]*)?$/i.test(value)) {
      return null;
    }
    try {
      if (/[\u0000-\u0020\u007f]/.test(decodeURIComponent(value))) { return null; }
    } catch (_) { return null; }
    return { kind: 'url', value: value };
  }

  export function fromWant(want: Want): ProfileImportCandidate | null {
    if (want.action !== 'ohos.want.action.viewData' && want.action !== 'ohos.want.action.sendData') { return null; }
    const params = want.parameters;
    const text = params?.['ohos.extra.param.key.TEXT'];
    if (typeof text === 'string') { return parseText(text); }
    const link = parseText(want.uri ?? '');
    if (link !== null) { return link; }
    let uri = want.uri ?? '';
    const streams = params?.['ability.params.stream'];
    if (Array.isArray(streams)) {
      if (streams.length !== 1 || typeof streams[0] !== 'string') { return null; }
      uri = streams[0] as string;
    }
    // OS-granted document or application file URIs only. Never allow this app's
    // own sandbox, raw local paths or a caller-supplied fd.
    if (((want.flags ?? 0) & 1) === 0 || uri.length > 8192 ||
      !/^file:\/\/(?:docs|[a-z0-9_-]+(?:\.[a-z0-9_-]+)+)\/[^?#]+\.ya?ml$/i.test(uri) ||
      /^file:\/\/com\.starfie1d\.cexing\//i.test(uri)) { return null; }
    try {
      const decoded = decodeURIComponent(uri);
      if (/[\u0000-\u001f\u007f\\]/.test(decoded) || decoded.split('/').includes('..')) { return null; }
    } catch (_) { return null; }
    return { kind: 'file', value: uri };
  }

  function enqueue(candidate: ProfileImportCandidate): void {
    if (candidate.value === lastValue) { return; }
    lastValue = candidate.value;
    pending = candidate;
    AppStorage.setOrCreate('profileImportRequest', ++revision);
  }

  export function receive(want: Want): void {
    const request = ++delivery;
    const candidate = fromWant(want);
    if (candidate !== null) { enqueue(candidate); return; }
    if (want.action !== 'ohos.want.action.sendData') { unsupported(); return; }
    // Share Kit transports records separately from legacy Want TEXT/URI fields.
    try {
    systemShare.getSharedData(want).then((data: systemShare.SharedData) => {
      if (request !== delivery) { return; }
      const records = data.getRecords();
      if (records.length !== 1) { unsupported(); return; }
      const record = records[0];
      const text = parseText(record.content ?? '');
      if (text !== null) { enqueue(text); return; }
      // getSharedData resolves the system-mediated URI grant for this record.
      const file = fromWant({ action: 'ohos.want.action.viewData', uri: record.uri ?? '', flags: 1 });
      if (file !== null) { enqueue(file); } else { unsupported(); }
    }).catch(() => { if (request === delivery) { unsupported(); } });
    } catch (_) { unsupported(); }
  }

  function unsupported(): void {
    promptAction.showToast({ message: '未识别到订阅链接或 YAML 文件，请重新选择', duration: 2000 });
  }

  export function take(): ProfileImportCandidate | null {
    const result = pending;
    pending = null;
    return result;
  }
}
