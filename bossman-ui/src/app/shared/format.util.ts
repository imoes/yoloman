/**
 * Humane value formatting (docs/design-philosophy.md §12): values shown to a
 * person carry units + sensible precision — never a raw float
 * (37.05206631905181) or raw seconds (1306051). One place, so every table
 * formats identically.
 */

/** Format a metric value for display, unit-aware from the metric key/name. */
export function formatMetricValue(value: number | null | undefined, metric = '', name = ''): string {
  if (value === null || value === undefined) return '—';
  const m = (metric || '').toLowerCase();
  const n = (name || '').toLowerCase();
  if (m === 'uptime' || m.endsWith('_seconds') || m.endsWith('_secs') || n === 'uptime') {
    return formatDuration(value);
  }
  // CPU load is a load average (a float), NOT a percentage — despite the
  // agent's misleading `cpu_pct` metric name. Show it rounded to 2 decimals.
  if (m === 'cpu_pct' || m.startsWith('cpu_load') || n === 'cpu load') {
    return round(value, 2).toString();
  }
  if (m.endsWith('_pct') || m.includes('percent') || m.endsWith('_usage') || m.endsWith('_used_pct')) {
    return `${round(value, 2)} %`;
  }
  if (m.includes('bytes') || m.endsWith('_bytes')) return formatBytes(value);
  return formatNumber(value);
}

/** Seconds → "15 d 3 h" / "3 h 12 min" / "12 min" / "45 s". */
export function formatDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const min = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d} d ${h} h`;
  if (h > 0) return `${h} h ${min} min`;
  if (min > 0) return `${min} min`;
  return `${s} s`;
}

/** Bytes → "4.2 GiB" etc. */
export function formatBytes(bytes: number): string {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  let v = bytes;
  let i = 0;
  while (Math.abs(v) >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${round(v, i === 0 ? 0 : 1)} ${units[i]}`;
}

/** A plain number with precision scaled to magnitude (no long float tails). */
export function formatNumber(value: number): string {
  // Always two decimals, per the operator: a metric value must never be shown unrounded, and the old
  // magnitude-dependent precision (0 decimals ≥100, 1 decimal ≥10) meant most values showed fewer than
  // two. round() drops needless trailing zeros (457.00 → "457"); toLocaleString adds thousands grouping.
  return round(value, 2).toLocaleString(undefined, { maximumFractionDigits: 2 });
}

function round(v: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(v * f) / f;
}

/** The comparison operator as its arithmetic symbol. */
export function comparisonSymbol(comparison: string | null | undefined): string {
  switch (comparison) {
    case 'gt': return '>';
    case 'lt': return '<';
    case 'ge': return '≥';
    case 'le': return '≤';
    case 'eq': return '=';
    case 'ne': return '≠';
    default: return '';
  }
}

/**
 * F-17: the compact "graded against" string for a service — what its value is
 * being compared to, unit-aware. e.g. "warn ≥ 80 %, crit ≥ 90 %". Empty when
 * the service has no rule thresholds (rule-less builtins like Uptime).
 */
export function thresholdContext(
  svc: { warn_threshold: number | null; crit_threshold: number | null; comparison: string | null; metric?: string; name?: string },
): string {
  const sym = comparisonSymbol(svc.comparison);
  const parts: string[] = [];
  if (svc.warn_threshold !== null && svc.warn_threshold !== undefined) {
    parts.push(`warn ${sym} ${formatMetricValue(svc.warn_threshold, svc.metric, svc.name)}`.trim());
  }
  if (svc.crit_threshold !== null && svc.crit_threshold !== undefined) {
    parts.push(`crit ${sym} ${formatMetricValue(svc.crit_threshold, svc.metric, svc.name)}`.trim());
  }
  return parts.join(', ');
}
