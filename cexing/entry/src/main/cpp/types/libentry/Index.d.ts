export interface BridgeStatus {
  loaded: boolean;
  libPath: string;
  lastError: string;
  callCount: number;
  failCount: number;
}

/**
 * 初始化 mihomo 内核（homeDir 为应用 filesDir）。
 * resolve 值为错误串，空串表示成功。
 */
export const initCore: (homeDir: string) => Promise<string>;

/**
 * 用系统下发的 tun fd 启动内核（configJson 为最小 mihomo 配置，JSON 格式；
 * overridesJson 为用户设置覆写，JSON 格式，可选）。
 * resolve 值为错误串，空串表示成功。
 */
export const startTun: (fd: number, configJson: string, overridesJson?: string) => Promise<string>;

/** 停止内核（关 TUN 与全部 listener）。 */
export const stopCore: () => Promise<void>;

/** Parse a candidate on the Go worker without applying it or fetching providers.
 * Empty string means valid; fixed error codes distinguish unresolved resources. */
export const validateOffline: (homeDir: string, configJson: string, overridesJson: string) => Promise<string>;

/** Pinned Verge v2.5.8 Merge preview. Returns only fixed-section counts and digest. */
export const previewMerge: (homeDir: string, original: string, overlay: string, overridesJson: string) => Promise<string>;

/** Atomic private effective-version store operation on the Go worker. */
export const versionAction: (homeDir: string, actionJson: string) => Promise<string>;

/** 桥接层状态（库是否加载、调用计数等）。 */
export const getBridgeStatus: () => BridgeStatus;
