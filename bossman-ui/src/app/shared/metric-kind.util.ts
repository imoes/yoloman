/**
 * Classify a check/metric as a numeric measurement (cpu %, disk bytes, IOPS …)
 * vs a stateful/boolean condition (a service is running or not, a port is open
 * or not). For a stateful check a comparison operator + warn/crit thresholds are
 * meaningless — the check alerts on its own when it isn't in the expected state —
 * so the threshold dialogs hide those fields when this returns true.
 *
 * Heuristic (no per-check type flag exists in the check catalog): treat it as
 * numeric when the metric name carries a clearly numeric suffix; otherwise treat
 * it as stateful when the metric/service name matches a state-ish word. Anything
 * left over defaults to numeric (the safe default — you keep the threshold UI).
 */
const NUMERIC_SUFFIX = /(_pct|_percent|_bytes|_kb|_mb|_gb|_iops|_count|_num|_total|_seconds|_secs|_ms|_rate|_ratio|_load|_temp|_celsius|_watts|_volts|_rpm|_hz|_bps|_fps|_errors|_drops)$/i;
const STATE_WORD = /\b(service|services|systemd|unit|units|daemon|process|processes|proc|ps|port|ping|reachable|running|stopped|up|down|online|offline|present|absent|exists|mounted|active|inactive|enabled|disabled|status|state|healthy|failed)\b/i;

export function isStatefulMetric(metric?: string | null, serviceName?: string | null): boolean {
  const m = (metric ?? '').toLowerCase();
  const s = (serviceName ?? '').toLowerCase();
  // A clearly numeric metric is never stateful, even if its service name reads
  // state-ish (e.g. "CPU load" — "load" is numeric, handled by the suffix).
  if (NUMERIC_SUFFIX.test(m)) return false;
  return STATE_WORD.test(m) || STATE_WORD.test(s);
}
