import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';

/**
 * The CLOSED set of tones a status can take on screen. Every status word in the app lands on exactly one of
 * these; there is no eighth, and there is no "no tone" (CLAUDE.md "Formale Logik" rule 3).
 *
 * Each tone is icon + text + colour, never colour alone (WCAG 1.4.1): a colour-blind operator, a greyscale
 * printout and a screen reader all still get the state from the icon and the word. Red is reserved for
 * `error` — a warning, a running job or a cancelled one must not borrow it (Carbon status-indicator pattern).
 */
export type StatusTone = 'ok' | 'running' | 'waiting' | 'warning' | 'error' | 'unknown' | 'gone';

export const STATUS_TONE_ICON: Record<StatusTone, string> = {
  ok: 'check_circle',
  running: 'sync',
  waiting: 'schedule',
  warning: 'warning',
  error: 'error',
  unknown: 'help',
  gone: 'remove_circle_outline',
};

/** Status word → tone. Keys are lower-case with `-`/space folded to `_`; see statusTone(). Words from every
 * vocabulary the API speaks (monitoring states, run/job status, operation outcomes, proposal decisions,
 * agent lifecycle) — add a word here, never a colour in a component. */
const WORDS: Record<string, StatusTone> = {
  // ok — it is as it should be
  ok: 'ok', success: 'ok', succeeded: 'ok', done: 'ok', completed: 'ok', complete: 'ok', healthy: 'ok', up: 'ok',
  pass: 'ok', passed: 'ok', applied: 'ok', approved: 'ok', online: 'ok', compliant: 'ok', resolved: 'ok',
  synced: 'ok', in_sync: 'ok', ready: 'ok', installed: 'ok', enrolled: 'ok', changed: 'ok', unchanged: 'ok',
  finished: 'ok', reachable: 'ok', enabled: 'ok',
  // running — work is in flight right now
  running: 'running', in_progress: 'running', inprogress: 'running', started: 'running', starting: 'running',
  applying: 'running', deploying: 'running', executing: 'running', provisioning: 'running', installing: 'running',
  rolling_back: 'running', stopping: 'running', restarting: 'running', syncing: 'running',
  // waiting — not started yet, or waiting for someone
  pending: 'waiting', queued: 'waiting', waiting: 'waiting', scheduled: 'waiting', awaiting_approval: 'waiting',
  proposed: 'waiting', draft: 'waiting', planned: 'waiting', new: 'waiting', never: 'waiting', paused: 'waiting',
  // warning — needs attention, not broken
  warn: 'warning', warning: 'warning', degraded: 'warning', drift: 'warning', drifted: 'warning',
  partial: 'warning', stale: 'warning', flapping: 'warning', refused: 'warning', timed_out: 'warning',
  timeout: 'warning', out_of_sync: 'warning', outdated: 'warning', acknowledged: 'warning',
  // error — broken
  error: 'error', failed: 'error', failure: 'error', crit: 'error', critical: 'error', down: 'error',
  unreachable: 'error', unknown_module: 'error', emerg: 'error', alert: 'error',
  // unknown — the named "we cannot tell" state
  unknown: 'unknown', none: 'unknown', unknown_state: 'unknown',
  // gone — it existed and is no longer there / no longer counts (nothing vanishes silently)
  gone: 'gone', cancelled: 'gone', canceled: 'gone', deleted: 'gone', removed: 'gone', vanished: 'gone',
  revoked: 'gone', rejected: 'gone', superseded: 'gone', expired: 'gone', skipped: 'gone', disabled: 'gone',
  uninstalled: 'gone', gap: 'gone', retired: 'gone', aborted: 'gone',
};

/** The tone of a status word. An unmapped word is `unknown` — a named state, never silently styled as ok. */
export function statusTone(status: string | null | undefined): StatusTone {
  const key = String(status ?? '').trim().toLowerCase().replace(/[\s-]+/g, '_');
  return WORDS[key] ?? 'unknown';
}

/**
 * The one status pill: `<bm-status-pill [status]="run.status" />`, or with a label that differs from the
 * word (`[label]="'never run'"`). A `title` on the host element passes through as the hover explanation.
 */
@Component({
  selector: 'bm-status-pill',
  standalone: true,
  imports: [MatIconModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<span class="bm-sp bm-sp--{{ tone() }}" [attr.data-tone]="tone()"><mat-icon class="bm-sp-i" aria-hidden="true">{{ icon() }}</mat-icon><span class="bm-sp-t">{{ text() }}</span></span>`,
  styles: [`
    :host { display: inline-flex; vertical-align: middle; }
    .bm-sp { display: inline-flex; align-items: center; gap: 4px; padding: 1px 8px 1px 5px; border-radius: 999px;
      font-size: 11.5px; font-weight: 600; line-height: 18px; white-space: nowrap; letter-spacing: 0.01em;
      color: var(--bm-sp-c); background: color-mix(in srgb, var(--bm-sp-c) 14%, transparent); }
    .bm-sp-i { width: 14px; height: 14px; font-size: 14px; line-height: 14px; flex: none; }
    .bm-sp--ok { --bm-sp-c: var(--bm-green); }
    .bm-sp--running { --bm-sp-c: var(--bm-info); }
    .bm-sp--waiting { --bm-sp-c: color-mix(in srgb, var(--mat-sys-on-surface) 78%, transparent); }
    .bm-sp--warning { --bm-sp-c: var(--bm-gold); }
    .bm-sp--error { --bm-sp-c: var(--bm-red); }
    .bm-sp--unknown { --bm-sp-c: var(--bm-unknown); }
    .bm-sp--gone { --bm-sp-c: color-mix(in srgb, var(--mat-sys-on-surface) 60%, transparent); }
    .bm-sp--gone .bm-sp-t { text-decoration: line-through; text-decoration-thickness: 1px; }
    .bm-sp--running .bm-sp-i { animation: bm-sp-spin 2s linear infinite; }
    @media (prefers-reduced-motion: reduce) { .bm-sp--running .bm-sp-i { animation: none; } }
    @keyframes bm-sp-spin { to { transform: rotate(-360deg); } }
  `],
})
export class StatusPillComponent {
  status = input.required<string | null | undefined>();
  label = input<string | null | undefined>(null);

  tone = computed(() => statusTone(this.status()));
  icon = computed(() => STATUS_TONE_ICON[this.tone()]);
  /** The word itself when no label is given; an empty status says "unknown" rather than rendering nothing. */
  text = computed(() => this.label() || this.status() || 'unknown');
}
