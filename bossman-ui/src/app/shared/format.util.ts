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
  if (m.endsWith('_pct') || m.includes('percent') || m.endsWith('_usage') || m.endsWith('_used_pct')) {
    return `${round(value, 1)} %`;
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
  const a = Math.abs(value);
  if (a >= 1000) return Math.round(value).toLocaleString();
  if (a >= 100) return round(value, 0).toString();
  if (a >= 10) return round(value, 1).toString();
  return round(value, 2).toString();
}

function round(v: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(v * f) / f;
}
