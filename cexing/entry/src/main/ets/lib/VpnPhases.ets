// Fixed fields only; this module performs no storage, networking or VPN control.
export type VpnPhaseOutcome = 'started' | 'success' | 'failed' | 'skipped' | 'unknown' | 'cancelled';
export interface VpnPhase {
  operation: string;
  stage: string;
  outcome: VpnPhaseOutcome;
  object?: string;
  reason?: string;
  code?: string;
  durationMs?: number;
}
export interface NativeVpnPhase {
  sequence: number;
  stage: string;
  outcome: VpnPhaseOutcome;
  code: string;
  durationMs: number;
}
export interface NativeVpnPhases {
  session: string;
  dropped: number;
  events: NativeVpnPhase[];
}
interface NumericFailure { code?: number; }

export namespace VpnPhases {
  export function code(error: Object, fallback: string): string {
    try {
      const value = (error as NumericFailure).code;
      if (typeof value === 'number' && Number.isInteger(value) && value >= -2147483648 && value <= 4294967295) { return `${value}`; }
    } catch (_) {}
    return fallback;
  }

  export function valid(event: NativeVpnPhase): boolean {
    const stages: string[] = ['tun_create', 'protect', 'geodata_prepare', 'smart_model_prepare',
      'panel_assets_prepare', 'core_initialize', 'configuration_prepare', 'core_start',
      'tun_destroy', 'late_tun_destroy', 'core_stop'];
    const outcomes: string[] = ['started', 'success', 'failed', 'skipped', 'unknown', 'cancelled'];
    return Number.isSafeInteger(event.sequence) && event.sequence > 0 &&
      stages.indexOf(event.stage) >= 0 && outcomes.indexOf(event.outcome) >= 0 &&
      typeof event.code === 'string' && /^(?:-?\d{1,16}|[A-Z][A-Z0-9_]{0,63})?$/.test(event.code) &&
      Number.isSafeInteger(event.durationMs) && event.durationMs >= 0;
  }
}
