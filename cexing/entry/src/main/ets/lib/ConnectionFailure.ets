import { UiText } from './UiText';
// Only these bounded fields may cross the VPN process boundary or enter a shareable summary.
export interface ConnectionFailure {
  phase: string;
  category: string;
  code: number;
}

interface FailureEnvelope {
  session: string;
  failure: ConnectionFailure;
}

export namespace ConnectionFailures {
  export function classify(phase: string, raw: string): ConnectionFailure {
    const lower = raw.toLowerCase();
    let category = 'unknown';
    if (/permission|denied|reject|cancel|授权|拒绝/.test(lower)) {
      category = 'permission';
    } else if (/parse|yaml|config|配置/.test(lower)) {
      category = 'configuration';
    } else if (/dns|resolve|lookup/.test(lower)) {
      category = 'dns';
    } else if (/tls|certificate|handshake/.test(lower)) {
      category = 'tls';
    } else if (/timeout|timed out|超时/.test(lower)) {
      category = 'timeout';
    } else if (/connect|dial|network|socket/.test(lower)) {
      category = 'network';
    }
    // Raw failures can contain URLs and credentials, including numeric query parameters.
    return { phase, category, code: 0 };
  }

  export function systemCode(phase: string, code: number): ConnectionFailure {
    return { phase, category: 'unknown', code: Number.isInteger(code) && Math.abs(code) <= 999999 ? code : 0 };
  }

  export function encode(session: string, failure: ConnectionFailure): string {
    const envelope: FailureEnvelope = { session, failure };
    return JSON.stringify(envelope);
  }

  export function decode(value: string, session: string = ''): ConnectionFailure | null {
    try {
      const parsed = JSON.parse(value) as FailureEnvelope;
      if (session.length > 0 && parsed.session !== session) { return null; }
      const data = session.length > 0 ? parsed.failure : JSON.parse(value) as ConnectionFailure;
      const phases = ['authorization', 'service', 'vpn', 'protect', 'assets', 'core-init', 'config', 'core-start', 'readiness'];
      const categories = ['unknown', 'permission', 'configuration', 'dns', 'tls', 'timeout', 'network'];
      if (phases.indexOf(data.phase) >= 0 && categories.indexOf(data.category) >= 0 &&
        Number.isInteger(data.code) && Math.abs(data.code) <= 999999) {
        return data;
      }
    } catch (_) {}
    return null;
  }

  export function label(failure: ConnectionFailure): string {
    let phase = UiText.get($r('app.string.failure_phase_start'));
    switch (failure.phase) {
      case 'authorization': phase = UiText.get($r('app.string.failure_phase_authorization')); break;
      case 'service': phase = UiText.get($r('app.string.failure_phase_service')); break;
      case 'vpn': phase = UiText.get($r('app.string.failure_phase_vpn')); break;
      case 'protect': phase = UiText.get($r('app.string.failure_phase_protect')); break;
      case 'assets': phase = UiText.get($r('app.string.failure_phase_assets')); break;
      case 'core-init': phase = UiText.get($r('app.string.failure_phase_core_init')); break;
      case 'config': phase = UiText.get($r('app.string.failure_phase_config')); break;
      case 'core-start': phase = UiText.get($r('app.string.failure_phase_core_start')); break;
      case 'readiness': phase = UiText.get($r('app.string.failure_phase_readiness')); break;
    }
    let category = UiText.get($r('app.string.failure_unknown'));
    switch (failure.category) {
      case 'permission': category = UiText.get($r('app.string.failure_permission')); break;
      case 'configuration': category = UiText.get($r('app.string.failure_configuration')); break;
      case 'dns': category = UiText.get($r('app.string.failure_dns')); break;
      case 'tls': category = UiText.get($r('app.string.failure_tls')); break;
      case 'timeout': category = UiText.get($r('app.string.failure_timeout')); break;
      case 'network': category = UiText.get($r('app.string.failure_network')); break;
    }
    const code = failure.code === 0 ? '' : ` (${failure.code})`;
    return UiText.get($r('app.string.failure_label'), phase, category, code);
  }

  export function summary(status: string, control: string, failure: ConnectionFailure | null,
    version: string = 'unknown', tunCreateObserved: boolean = false,
    kernelReadyReported: boolean = false): string {
    const allowedStatus = ['disconnected', 'connecting', 'connected', 'disconnecting'];
    const allowedControl = ['not-run', 'reachable', 'failed', 'timeout'];
    const safeStatus = allowedStatus.indexOf(status) >= 0 ? status : 'disconnected';
    const safeControl = allowedControl.indexOf(control) >= 0 ? control : 'not-run';
    const safeVersion = /^[0-9A-Za-z.+-]{1,48}$/.test(version) ? version : 'unknown';
    const lines = ['Cexing connection summary v2', `app_version=${safeVersion}`, `vpn_state=${safeStatus}`,
      `system_session=${tunCreateObserved ? 'tun-create-resolved' : 'not-observed'}`,
      `kernel_readiness=${kernelReadyReported ? 'extension-reported' : 'not-reported'}`,
      `controller=${safeControl}`, 'request_forwarding=unverified'];
    if (failure !== null) {
      const safe = decode(JSON.stringify(failure));
      if (safe === null) { return lines.join('\n'); }
      lines.push(`last_failure_phase=${safe.phase}`, `last_failure_category=${safe.category}`,
        `last_failure_code=${safe.code}`);
    }
    return lines.join('\n');
  }
}
