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
    let phase = '启动';
    switch (failure.phase) {
      case 'authorization': phase = '系统授权'; break;
      case 'service': phase = '服务连接'; break;
      case 'vpn': phase = '系统隧道'; break;
      case 'protect': phase = '进程网络保护'; break;
      case 'assets': phase = '资源准备'; break;
      case 'core-init': phase = '内核初始化'; break;
      case 'config': phase = '配置解析'; break;
      case 'core-start': phase = '内核启动'; break;
      case 'readiness': phase = '启动状态确认'; break;
    }
    let category = '未知错误';
    switch (failure.category) {
      case 'permission': category = '权限被拒绝'; break;
      case 'configuration': category = '配置错误'; break;
      case 'dns': category = '解析错误'; break;
      case 'tls': category = '安全连接错误'; break;
      case 'timeout': category = '超时'; break;
      case 'network': category = '网络连接错误'; break;
    }
    const code = failure.code === 0 ? '' : ` (${failure.code})`;
    return `${phase}：${category}${code}`;
  }

  export function summary(status: string, control: string, failure: ConnectionFailure | null,
    version: string = 'unknown'): string {
    const allowedStatus = ['disconnected', 'connecting', 'connected', 'disconnecting'];
    const allowedControl = ['not-run', 'reachable', 'failed', 'timeout'];
    const safeStatus = allowedStatus.indexOf(status) >= 0 ? status : 'disconnected';
    const safeControl = allowedControl.indexOf(control) >= 0 ? control : 'not-run';
    const safeVersion = /^[0-9A-Za-z.+-]{1,48}$/.test(version) ? version : 'unknown';
    const lines = ['Cexing connection summary v1', `app_version=${safeVersion}`, `vpn_state=${safeStatus}`,
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
