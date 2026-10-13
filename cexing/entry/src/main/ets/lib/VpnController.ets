/*
 * VpnController.ets - 主进程 VPN 启停(M0 最小状态机)
 *
 * start: startVpnExtensionAbility(触发系统授权弹窗) -> connectServiceExtensionAbility(带 VPN_CONFIG)
 * stop:  disconnectServiceExtensionAbility -> stopVpnExtensionAbility
 */
import { vpnExtension, connection } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';
import { CoreApi } from './CoreApi';
import { rpc } from '@kit.IPCKit';
import { Settings } from './Settings';
import { ConnectionFailure, ConnectionFailures } from './ConnectionFailure';
import { ProfileStore } from './ProfileStore';
import { VpnPhase, VpnPhaseOutcome, NativeVpnPhases, VpnPhases } from './VpnPhases';

const TAG = 'vpnCtrl';
const VPN_ABILITY_NAME = 'CexingVpnAbility';
// 与 vpnability/CexingVpnAbility.ets 的 LAST_ERROR_FILE 一致（同一应用沙箱共享 filesDir）
const LAST_ERROR_FILE = 'last_start_error.txt';
const LAST_STOP_FILE = 'last_stop_result.json';
const STOP_COMPLETION_TIMEOUT_MS = 15000;

interface StopResult {
  session: string;
  completed: boolean;
}

export enum VpnStatus {
  Disconnected = 0,
  Connecting = 1,
  Connected = 2,
  Disconnecting = 3
}

type StatusListener = (s: VpnStatus) => void;

/**
 * 构建 VpnConfig.routes（FlClash 实证方案）：
 * 1. 显式默认路由 0.0.0.0/0（IPv6 开启时追加 ::/0）——保证 VPN 成为应用的解析网络，
 *    系统 DNS（fake-ip 链路）正确传播；
 * 2. 华为 HTTPDNS 引导服务器（139.9.98.98/139.9.99.99，/32）与边缘段
 *    （139.9/16、49.4/16、121.36/16、125.88/16、119.147/16、183.61/16）
 *    标记为排除路由（isExcludedRoute）——ArkWeb 浏览器的 HTTPDNS/静默代理
 *    （SilentProxy）直连运营商网络完成解析，不再被隧道送到境外节点导致
 *    空代理（x.x.x）解析失败 → ERR_PROXY_CONNECTION_FAILED；
 *    后续内容连接仍走隧道，由内核 SNI 嗅探（override-destination）修正目标。
 */
function buildVpnRoutes(ipv6: boolean): connection.RouteInfo[] {
  const routes: connection.RouteInfo[] = [];
  routes.push({
    interface: 'vpn-tun',
    destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
    gateway: { address: '', family: 1 },
    hasGateway: false,
    isDefaultRoute: true
  });
  const bootstrap: string[] = ['139.9.98.98', '139.9.99.99'];
  for (const ip of bootstrap) {
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: ip, family: 1 }, prefixLength: 32 },
      gateway: { address: '', family: 1 },
      hasGateway: false,
      isDefaultRoute: false,
      isExcludedRoute: true
    });
  }
  const excludedCidrs: string[] = ['139.9.0.0/16', '49.4.0.0/16', '121.36.0.0/16',
    '125.88.0.0/16', '119.147.0.0/16', '183.61.0.0/16'];
  for (const cidr of excludedCidrs) {
    const parts: string[] = cidr.split('/');
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: parts[0], family: 1 }, prefixLength: Number(parts[1]) },
      gateway: { address: '', family: 1 },
      hasGateway: false,
      isDefaultRoute: false,
      isExcludedRoute: true
    });
  }
  if (ipv6) {
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
      gateway: { address: '', family: 2 },
      hasGateway: false,
      isDefaultRoute: true
    });
  }
  return routes;
}

/** 读取 :vpn 进程写入的最近一次启动失败原因（空串=无失败） */
function readLastStartError(context: common.UIAbilityContext): string {
  try {
    const p = `${context.filesDir}/${LAST_ERROR_FILE}`;
    if (fileIo.accessSync(p)) {
      return fileIo.readTextSync(p).trim();
    }
  } catch (e) {
    // 忽略
  }
  return '';
}

function readStopResult(context: common.UIAbilityContext, session: string): boolean | null {
  try {
    const path = `${context.filesDir}/${LAST_STOP_FILE}`;
    if (fileIo.accessSync(path)) {
      const result = JSON.parse(fileIo.readTextSync(path)) as StopResult;
      if (result.session === session && typeof result.completed === 'boolean') {
        return result.completed;
      }
    }
  } catch (_) {}
  return null;
}

async function waitForStopResult(context: common.UIAbilityContext, session: string): Promise<boolean> {
  const deadline = Date.now() + STOP_COMPLETION_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const result = readStopResult(context, session);
    if (result !== null) { return result; }
    await new Promise<void>((resolve) => { setTimeout(resolve, 100); });
  }
  return false;
}

export namespace VpnController {
  export let status: VpnStatus = VpnStatus.Disconnected;
  /** 最近一次内核启动失败原因（空串=正常）。UI 读取后调用 consumeLastStartError 清空。 */
  export let lastStartError: string = '';
  export let lastStartFailure: ConnectionFailure | null = null;
  // Independent observations from this start attempt, not claims of live forwarding.
  let tunCreateObserved: boolean = false;
  let kernelReadyReported: boolean = false;
  let serviceId: number = -1;
  let serviceContext: common.UIAbilityContext | null = null;
  let serviceRemote: rpc.IRemoteObject | null = null;
  let recoveryBinding: Promise<rpc.IRemoteObject | null> | null = null;
  let authorization: Promise<void> | null = null;
  let stopPending: Promise<boolean> | null = null;
  // Retain an unconfirmed stop across the Disconnected UI transition in this
  // process. Disconnected alone does not establish native cleanup.
  let lastStopCompleted: boolean | null = null;
  const listeners: StatusListener[] = [];
  let startAttempt = 0;
  let startSession: string = '';
  let recoveryAttempt = 0;
  const phaseListeners: ((phase: VpnPhase) => void)[] = [];
  let nativeSequence: number = 0;
  let nativeSession: string = '';
  let nativeRemote: rpc.IRemoteObject | null = null;
  let diagnosticUnknownObject: string = 'unidentified-vpn-session';
  let collectingNative: boolean = false;
  let nativeGapReported: boolean = false;

  export function onPhase(listener: (phase: VpnPhase) => void): () => void {
    phaseListeners.push(listener);
    return (): void => {
      const index = phaseListeners.indexOf(listener);
      if (index >= 0) { phaseListeners.splice(index, 1); }
    };
  }

  function phase(stage: string, outcome: VpnPhaseOutcome, session: string,
    code: string = '', durationMs: number = 0, reason: string = ''): void {
    const event: VpnPhase = { operation: 'vpn', stage, outcome,
      object: session.length > 0 ? `vpn-session:${session}` : diagnosticUnknownObject,
      code, reason, durationMs: Math.max(0, durationMs) };
    for (const listener of phaseListeners) { try { listener(event); } catch (_) {} }
  }

  function nativePhases(remote: rpc.IRemoteObject, session: string, attempt: number): void {
    if (phaseListeners.length === 0 || collectingNative) { return; }
    collectingNative = true;
    (async (): Promise<void> => {
      let data: rpc.MessageSequence | null = null;
      let reply: rpc.MessageSequence | null = null;
      try {
        data = rpc.MessageSequence.create();
        reply = rpc.MessageSequence.create();
        const result = await remote.sendMessageRequest(3, data, reply, new rpc.MessageOption());
        if (result.errCode !== 0) { throw new Error('native evidence unavailable'); }
        const text = result.reply.readString();
        if (text.length > 16384) { throw new Error('native evidence oversized'); }
        const snapshot = JSON.parse(text) as NativeVpnPhases;
        if (attempt !== startAttempt || snapshot.session !== session || !Array.isArray(snapshot.events)) { return; }
        if (nativeSession !== session || (session.length === 0 && nativeRemote !== remote)) { nativeSession = session; nativeRemote = remote; nativeSequence = 0; nativeGapReported = false; }
        if ((snapshot.dropped > 0 || snapshot.events.length > 32) && !nativeGapReported) {
          nativeGapReported = true;
          phase('native_evidence', 'unknown', session, 'NATIVE_EVENTS_TRUNCATED');
        }
        for (const event of snapshot.events.slice(0, 32)) {
          if (!VpnPhases.valid(event)) {
            if (!nativeGapReported) { nativeGapReported = true; phase('native_evidence', 'unknown', session, 'NATIVE_EVENT_INVALID'); }
            continue;
          }
          if (event.sequence <= nativeSequence) { continue; }
          phase(event.stage, event.outcome, session, event.code, event.durationMs, 'extension_event_via_ipc');
          nativeSequence = event.sequence;
        }
      } catch (_) {
        if (attempt === startAttempt && !nativeGapReported) {
          nativeGapReported = true;
          phase('native_evidence', 'unknown', session, 'NATIVE_EVENTS_UNAVAILABLE');
        }
      } finally {
        try { data?.reclaim(); } catch (_) {}
        try { reply?.reclaim(); } catch (_) {}
        collectingNative = false;
      }
    })();
  }

  export function onChanged(cb: StatusListener): void {
    if (listeners.indexOf(cb) < 0) {
      listeners.push(cb);
    }
  }

  export function offChanged(cb: StatusListener): void {
    const index = listeners.indexOf(cb);
    if (index >= 0) {
      listeners.splice(index, 1);
    }
  }

  export function consumeLastStartError(): string {
    const msg = lastStartError;
    lastStartError = '';
    return msg;
  }

  export function getLastStartFailure(): ConnectionFailure | null {
    return lastStartFailure;
  }

  export function getTunCreateObserved(): boolean {
    return tunCreateObserved;
  }

  export function getKernelReadyReported(): boolean {
    return kernelReadyReported;
  }

  export function getLastStopCompleted(): boolean | null {
    return lastStopCompleted;
  }

  function recordFailure(failure: ConnectionFailure): void {
    lastStartFailure = failure;
    lastStartError = ConnectionFailures.label(failure);
  }

  /**
   * 冷启动恢复：UI 进程重建后探测内核是否仍在（REST 不证明系统 TUN 健康）。
   * 可选完成回调 onDone(alive)：探活落定后（含非断开态早退场景）回调，供调用方在
   * Controller 探活完成后再决策；系统会话健康需另外核对。
   * 被取消/取代的探活不提交状态，也不回调过期 onDone。
   */
  export function recover(onDone?: (alive: boolean) => void,
    context?: common.UIAbilityContext): void {
    if (status !== VpnStatus.Disconnected) {
      if (onDone !== undefined) { onDone(status === VpnStatus.Connected); }
      return;
    }
    const attempt = ++recoveryAttempt;
    diagnosticUnknownObject = `vpn-recovery:${Date.now()}:${attempt}`;
    phase('recovery_probe', 'started', '');
    if (context !== undefined) { CoreApi.bindContext(context); }
    (async (): Promise<void> => {
      const alive = await CoreApi.isAlive();
      if (attempt !== recoveryAttempt) { return; }
      phase('recovery_probe', alive ? 'success' : 'unknown', '', alive ? '' : 'CONTROLLER_PROBE_UNCONFIRMED');
      let confirmed = false;
      if (alive && context !== undefined) {
        const remote = await bindExistingService(context);
        if (attempt !== recoveryAttempt) { return; }
        if (remote !== null) {
          try {
            const observation = await readService(remote);
            if (attempt !== recoveryAttempt) { return; }
            startSession = observation.session;
            nativePhases(remote, observation.session, startAttempt);
            if (observation.ready && observation.tun && observation.session.length > 0) {
              startSession = observation.session;
              tunCreateObserved = true;
              kernelReadyReported = true;
              lastStopCompleted = null;
              lastStartFailure = null;
              lastStartError = '';
              confirmed = true;
              setStatus(VpnStatus.Connected);
            }
          } catch (_) {}
        }
        if (!confirmed) {
          lastStopCompleted = false;
          recordFailure(ConnectionFailures.classify('service', 'recovery unavailable'));
          phase('recovery_validation', 'unknown', startSession, 'VPN_SESSION_UNCONFIRMED');
          notifyStatus();
        }
      }
      if (attempt === recoveryAttempt && onDone !== undefined) { onDone(confirmed); }
    })().catch(() => {
      if (attempt === recoveryAttempt && onDone !== undefined) { onDone(false); }
    });
  }

  interface ServiceObservation { ready: boolean; error: string; session: string; tun: boolean; }

  async function readService(remote: rpc.IRemoteObject): Promise<ServiceObservation> {
    const data = rpc.MessageSequence.create();
    const reply = rpc.MessageSequence.create();
    try {
      const result = await remote.sendMessageRequest(1, data, reply, new rpc.MessageOption());
      if (result.errCode !== 0) { throw new Error('service unavailable'); }
      return { ready: result.reply.readBoolean(), error: result.reply.readString(),
        session: result.reply.readString(), tun: result.reply.readBoolean() };
    } finally { data.reclaim(); reply.reclaim(); }
  }

  function bindExistingService(context: common.UIAbilityContext): Promise<rpc.IRemoteObject | null> {
    if (serviceRemote !== null) { return Promise.resolve(serviceRemote); }
    if (recoveryBinding !== null) { return recoveryBinding; }
    const attempt = startAttempt;
    serviceContext = context;
    phase('recovery_binding', 'started', startSession);
    recoveryBinding = new Promise<rpc.IRemoteObject | null>((resolve) => {
      const timer = setTimeout(() => resolve(null), 5000);
      try {
        serviceId = context.connectServiceExtensionAbility({
          bundleName: context.applicationInfo.name, abilityName: VPN_ABILITY_NAME,
          parameters: { RECOVER_ONLY: true }
        }, {
          onConnect: (_element, remote: rpc.IRemoteObject) => {
            clearTimeout(timer);
            if (attempt !== startAttempt) { resolve(remote); return; }
            serviceRemote = remote;
            phase('recovery_binding', 'success', startSession);
            resolve(remote);
          },
          onDisconnect: () => {
            clearTimeout(timer); resolve(null);
            serviceLost(attempt);
          },
          onFailed: (_code: number) => {
            phase('recovery_binding', 'failed', startSession, `${_code}`);
            clearTimeout(timer); resolve(null);
            serviceLost(attempt);
          }
        });
        if (serviceId < 0) { clearTimeout(timer); resolve(null); }
      } catch (e) { phase('recovery_binding', 'failed', startSession, VpnPhases.code(e, 'SERVICE_BIND_FAILED')); clearTimeout(timer); resolve(null); }
    });
    const binding = recoveryBinding;
    binding.then(() => {
      if (recoveryBinding === binding && serviceRemote === null && serviceId < 0) {
        recoveryBinding = null;
      }
    });
    return binding;
  }

  function serviceLost(attempt: number, detached: boolean = true): void {
    if (attempt !== startAttempt) { return; }
    if (detached) {
      serviceId = -1;
      serviceContext = null;
      serviceRemote = null;
      recoveryBinding = null;
    }
    if (status === VpnStatus.Connected) {
      lastStopCompleted = false;
      recordFailure(ConnectionFailures.classify('service', 'disconnect'));
      setStatus(VpnStatus.Disconnected);
    }
  }

  /** Recheck the bound session; a Controller response alone cannot verify it. */
  export async function verify(context: common.UIAbilityContext): Promise<void> {
    if (status !== VpnStatus.Connected || serviceRemote === null) { return; }
    const remote = serviceRemote;
    const attempt = startAttempt;
    let valid = false;
    try {
      const observation = await readService(remote);
      valid = observation.ready && observation.tun && observation.session === startSession &&
        await CoreApi.isAlive();
    } catch (_) {}
    if (attempt !== startAttempt || status !== VpnStatus.Connected || serviceRemote !== remote) { return; }
    if (!valid) { phase('runtime_validation', 'unknown', startSession, 'VPN_SESSION_UNCONFIRMED'); serviceLost(attempt, false); }
  }

  /** 使在途冷恢复失效；运行时取消恢复/当前 Ability 销毁可调用，不停止 VPN。 */
  export function cancelRecovery(): void {
    recoveryAttempt++;
  }

  export function needsStop(): boolean {
    return lastStopCompleted === false ||
      (status === VpnStatus.Disconnected && serviceId >= 0);
  }

  function notifyStatus(): void {
    for (const cb of listeners) { cb(status); }
  }

  function setStatus(s: VpnStatus): void {
    if (status === s) {
      return;
    }
    status = s;
    Logger.info(TAG, `status -> ${VpnStatus[s]}`);
    notifyStatus();
  }

  export function start(context: common.UIAbilityContext): boolean {
    if (status !== VpnStatus.Disconnected) {
      Logger.warn(TAG, `start ignored, status=${VpnStatus[status]}`);
      return false;
    }
    if (needsStop() || stopPending !== null) {
      phase('start_precondition', 'skipped', startSession, 'STOP_NOT_CONFIRMED');
      lastStartError = '请先重试断开，确认当前连接已结束';
      notifyStatus();
      return false;
    }
    cancelRecovery();
    lastStopCompleted = null;
    lastStartError = '';
    lastStartFailure = null;
    tunCreateObserved = false;
    kernelReadyReported = false;
    CoreApi.bindContext(context);
    setStatus(VpnStatus.Connecting);
    const attempt = ++startAttempt;
    startSession = `${Date.now()}-${attempt}`;
    const session = startSession;
    const authorizationAt = Date.now();
    nativeSession = session; nativeSequence = 0; nativeGapReported = false;
    phase('authorization', 'started', session);
    const want: Want = { bundleName: context.applicationInfo.name, abilityName: VPN_ABILITY_NAME };
    Logger.info(TAG, 'startVpnExtensionAbility...');
    try { authorization = vpnExtension.startVpnExtensionAbility(want); }
    catch (e) {
      phase('authorization', 'failed', session, VpnPhases.code(e, 'AUTHORIZATION_FAILED'), Date.now() - authorizationAt);
      recordFailure(ConnectionFailures.classify('authorization', JSON.stringify(e)));
      setStatus(VpnStatus.Disconnected);
      return false;
    }
    authorization.then(() => {
      if (attempt !== startAttempt || status !== VpnStatus.Connecting) { phase('authorization', 'cancelled', session, 'START_SUPERSEDED'); return; }
      phase('authorization', 'success', session, '', Date.now() - authorizationAt);
      connectService(context, want);
    }).catch((e: Object) => {
      if (attempt !== startAttempt || status !== VpnStatus.Connecting) { return; }
      phase('authorization', 'failed', session, VpnPhases.code(e, 'AUTHORIZATION_FAILED'), Date.now() - authorizationAt);
      recordFailure(ConnectionFailures.classify('authorization', JSON.stringify(e)));
      Logger.error(TAG, `startVpnExtensionAbility failed: ${lastStartError}`);
      setStatus(VpnStatus.Disconnected);
    });
    return true;
  }

  function connectService(context: common.UIAbilityContext, want: Want): void {
    const linkAddr: connection.LinkAddress = {
      address: { address: '172.19.0.1', family: 1 },
      prefixLength: 30
    };
    // 按应用分流（设置→网络设置）：all=全部走 VPN（仅自身排除）；
    // white=仅名单内走；black=名单内不走。本应用始终直连（订阅下载/REST 不绕路）。
    const s = Settings.load(context);
    const self = context.applicationInfo.name;
    const blocked: string[] = [self];
    const trusted: string[] = [];
    if (s.accessMode === 'black') {
      for (const pkg of s.accessList) {
        if (pkg !== self) {
          blocked.push(pkg);
        }
      }
    } else if (s.accessMode === 'white') {
      for (const pkg of s.accessList) {
        if (pkg !== self) {
          trusted.push(pkg);
        }
      }
    }
    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [linkAddr],
      // 与内核 gVisor 栈 MTU（core/engine.go defaultTunExt 9000）保持一致，
      // 避免 gVisor 产出 9KB 帧打进 1500 MTU 设备被丢弃
      mtu: 9000,
      dnsAddresses: ['223.5.5.5', '8.8.8.8'],
      // 显式默认路由 + 华为 HTTPDNS 排除路由（FlClash 方案，修复 ArkWeb 浏览器
      // 空代理 x.x.x → ERR_PROXY_CONNECTION_FAILED）
      routes: buildVpnRoutes(s.ipv6),
      blockedApplications: blocked,
      isIPv6Accepted: s.ipv6
    };
    // 仅白名单模式且名单非空时才下发 trustedApplications；
    // 空数组会被系统当作有效配置，干扰 excluded 路由（实证：:vpn 进程直连被断）
    if (trusted.length > 0) {
      vpnConfig.trustedApplications = trusted;
    }
    const params: Record<string, Object> = { 'VPN_CONFIG': vpnConfig, 'SESSION_ID': startSession };
    const connectWant: Want = {
      bundleName: want.bundleName,
      abilityName: want.abilityName,
      parameters: params
    };
    const attempt = startAttempt;
    const session = startSession;
    phase('service_binding', 'started', session);
    try {
      serviceContext = context;
      serviceId = context.connectServiceExtensionAbility(connectWant, {
        onConnect: (element, remote: rpc.IRemoteObject) => {
          if (attempt !== startAttempt || status !== VpnStatus.Connecting) { return; }
          serviceRemote = remote;
          phase('service_binding', 'success', session);
          Logger.info(TAG, 'service connected');
          waitForCore(context, remote, attempt).catch((e: Object) => {
            Logger.error(TAG, `core readiness failed: ${JSON.stringify(e)}`);
          });
        },
        onDisconnect: () => {
          if (attempt !== startAttempt) {
            return;
          }
          serviceId = -1;
          serviceRemote = null;
          if (status === VpnStatus.Connected) {
            lastStopCompleted = false;
            recordFailure(ConnectionFailures.classify('service', 'disconnect'));
          }
          Logger.warn(TAG, 'service disconnected unexpectedly');
          if (status === VpnStatus.Connecting) {
            const saved = ConnectionFailures.decode(readLastStartError(context), startSession);
            recordFailure(saved ?? ConnectionFailures.classify('service', 'disconnect'));
          }
          setStatus(VpnStatus.Disconnected);
        },
        onFailed: (code: number) => {
          if (attempt !== startAttempt) {
            return;
          }
          serviceId = -1;
          serviceRemote = null;
          phase('service_binding', 'failed', session, `${code}`);
          Logger.error(TAG, `service connect failed: ${code}`);
          const saved = ConnectionFailures.decode(readLastStartError(context), startSession);
          recordFailure(saved ?? ConnectionFailures.systemCode('service', code));
          setStatus(VpnStatus.Disconnected);
        }
      });
    } catch (e) {
      phase('service_binding', 'failed', session, VpnPhases.code(e, 'SERVICE_BIND_FAILED'));
      recordFailure(ConnectionFailures.classify('service', JSON.stringify(e)));
      Logger.error(TAG, `connectServiceExtensionAbility failed: ${lastStartError}`);
      setStatus(VpnStatus.Disconnected);
    }
  }

  async function waitForCore(context: common.UIAbilityContext, remote: rpc.IRemoteObject,
    attempt: number): Promise<void> {
    const deadline = Date.now() + 120000;
    while (status === VpnStatus.Connecting && attempt === startAttempt) {
      const data = rpc.MessageSequence.create();
      const reply = rpc.MessageSequence.create();
      let ready = false;
      let error = '';
      try {
        const result = await remote.sendMessageRequest(1, data, reply, new rpc.MessageOption());
        if (result.errCode !== 0) {
          throw new Error(`启动状态读取失败 (${result.errCode})`);
        }
        ready = result.reply.readBoolean();
        error = result.reply.readString();
        const remoteSession = result.reply.readString();
        const remoteTunCreated = result.reply.readBoolean();
        if (remoteSession !== startSession) {
          error = 'service session mismatch';
          ready = false;
        } else if (remoteTunCreated && attempt === startAttempt && status === VpnStatus.Connecting) {
          tunCreateObserved = true;
        }
      } catch (e) {
        error = (e as Error).message ?? '启动状态读取失败';
      } finally {
        data.reclaim();
        reply.reclaim();
      }
      if (status !== VpnStatus.Connecting || attempt !== startAttempt) {
        return;
      }
      nativePhases(remote, startSession, attempt);
      if (ready) {
        phase('kernel_readiness', 'success', startSession);
        kernelReadyReported = true;
        lastStartError = '';
        lastStartFailure = null;
        setStatus(VpnStatus.Connected);
        const settings = Settings.load(context);
        settings.vpnWasConnected = true;
        Settings.save(context, settings);
        return;
      }
      if (error.length > 0 || Date.now() >= deadline) {
        const failure = error.length > 0 ? ConnectionFailures.decode(error, startSession) :
          ConnectionFailures.classify('readiness', 'timeout');
        if (failure === null && error.startsWith('{') && Date.now() < deadline) {
          await new Promise<void>((resolve) => { setTimeout(resolve, 500); });
          continue;
        }
        recordFailure(failure ?? ConnectionFailures.classify('readiness', error));
        stop(context, true);
        return;
      }
      await new Promise<void>((resolve) => { setTimeout(resolve, 500); });
    }
  }

  async function requestCleanup(remote: rpc.IRemoteObject, session: string,
    request: string): Promise<boolean> {
    const data = rpc.MessageSequence.create();
    const reply = rpc.MessageSequence.create();
    try {
      data.writeString(session);
      data.writeString(request);
      const result = await remote.sendMessageRequest(2, data, reply, new rpc.MessageOption());
      return result.errCode === 0 && result.reply.readString() === request && result.reply.readBoolean();
    } catch (_) { return false; }
    finally { data.reclaim(); reply.reclaim(); }
  }

  async function boundedCleanup(remote: rpc.IRemoteObject, session: string,
    request: string): Promise<boolean> {
    let timer: number = -1;
    try {
      return await Promise.race([
        requestCleanup(remote, session, request),
        new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), STOP_COMPLETION_TIMEOUT_MS); })
      ]);
    } finally { if (timer >= 0) { clearTimeout(timer); } }
  }

  /** True means this session's extension cleanup and system stop both completed. False is unknown. */
  export function stop(context: common.UIAbilityContext, preserveFailure: boolean = false): Promise<boolean> {
    cancelRecovery();
    if (stopPending !== null) { return stopPending; }
    if (status !== VpnStatus.Connected && status !== VpnStatus.Connecting && serviceId < 0 && lastStopCompleted !== false) {
      Logger.warn(TAG, `stop ignored, status=${VpnStatus[status]}`);
      return Promise.resolve(false);
    }
    const retryUnknown = lastStopCompleted === false;
    const attempt = ++startAttempt;
    let session = startSession;
    const pendingAuthorization = authorization;
    const pendingBinding = recoveryBinding;
    const boundRemote = serviceRemote;
    const stoppingAt = Date.now();
    phase('stop', 'started', startSession);
    let connectedService = serviceId >= 0;
    // Only a pre-binding Connecting cancellation proves native startup was never entered.
    // Lost bindings still require system stop and the retained session cleanup receipt.
    const nativeNotEntered = status === VpnStatus.Connecting && !connectedService;
    let stoppingServiceId = serviceId;
    let stoppingContext = serviceContext ?? context;
    lastStopCompleted = false;
    // 用户主动停止：清除「会话曾连接」标记（冷启动不再自动恢复）
    let saved = true;
    try {
      const s = Settings.load(context);
      s.vpnWasConnected = false;
      Settings.save(context, s);
    } catch (_) {
      saved = false;
      Logger.error(TAG, 'disconnect preference save failed');
    }
    // 用户主动停止：清除残留失败信息，避免断开回调误报
    if (!preserveFailure) {
      lastStartError = '';
      lastStartFailure = null;
    }
    setStatus(VpnStatus.Disconnecting);
    const want: Want = { bundleName: context.applicationInfo.name, abilityName: VPN_ABILITY_NAME };
    stopPending = (async (): Promise<boolean> => {
      let extensionCompleted = nativeNotEntered;
      let remote = boundRemote;
      let disconnectedBinding = false;
      if (remote === null && retryUnknown && serviceId < 0) {
        remote = await bindExistingService(context);
        connectedService = serviceId >= 0;
        stoppingServiceId = serviceId;
        stoppingContext = serviceContext ?? context;
        if (remote !== null) {
          try { session = (await readService(remote)).session; startSession = session; } catch (_) {}
        }
      }
      if (remote === null && pendingBinding !== null) { remote = await pendingBinding; }
      if (session.length === 0 && remote !== null) {
        try { session = (await readService(remote)).session; } catch (_) {}
      }
      // The request-scoped IPC ACK covers even an empty recovered session ID.
      // It cannot be replaced by an old file receipt or a late ACK from another stop.
      const cleanup = remote !== null ? boundedCleanup(remote, session, `${Date.now()}-stop-${attempt}`) : null;
      if (cleanup !== null) { extensionCompleted = await cleanup; if (remote !== null) { nativePhases(remote, session, attempt); } }
      if (connectedService) {
        try { await stoppingContext.disconnectServiceExtensionAbility(stoppingServiceId); disconnectedBinding = true; }
        catch (_) { Logger.error(TAG, 'service disconnect failed'); }
      }
      let systemStopped = false;
      try {
        await vpnExtension.stopVpnExtensionAbility(want);
        systemStopped = true;
      } catch (_) { Logger.error(TAG, 'VPN Extension stop failed'); }
      // Even a failed early stop must reclaim a late authorization launch.
      if (nativeNotEntered && pendingAuthorization !== null) {
        try { await pendingAuthorization; } catch (_) {}
        try {
          await vpnExtension.stopVpnExtensionAbility(want);
          systemStopped = true;
        } catch (_) {
          systemStopped = false;
          Logger.error(TAG, 'late VPN Extension stop failed');
        }
      }
      if (cleanup === null && !nativeNotEntered && systemStopped && session.length > 0) {
        extensionCompleted = await waitForStopResult(context, session);
      }
      // Retain the unknown result after failure; a released binding is reacquired
      // by an explicit retry. Late cleanup cannot clear this result.
      const completed = saved && extensionCompleted && systemStopped;
      lastStopCompleted = completed;
      phase('stop', completed ? 'success' : 'unknown', session, completed ? '' : 'STOP_NOT_CONFIRMED', Date.now() - stoppingAt);
      if (completed || disconnectedBinding) {
        serviceId = -1;
        serviceContext = null;
        serviceRemote = null;
        recoveryBinding = null;
        if (completed) { authorization = null; }
      }
      if (completed) {
        try { ProfileStore.clearApplyUncertain(context); }
        catch (_) { Logger.error(TAG, 'confirmed stop marker cleanup failed'); }
      }
      stopPending = null;
      setStatus(VpnStatus.Disconnected);
      return completed;
    })();
    return stopPending;
  }
}
