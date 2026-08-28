import { BM_GREEN, BM_GOLD, BM_RED, BM_UNKNOWN } from './bm-colors';
export type BadgeStatus = 'ok' | 'warn' | 'crit' | 'unknown';

/** Same status semantics as the Go node agent's own internal/webui
 * (ok/warn/crit/unknown), applied to Agent.enrollment_state + last_seen_at:
 * revoked -> crit, pending -> warn, no/stale last_seen_at -> unknown,
 * seen recently -> ok. "Recently" is 2x the poller's default interval
 * (60s, see bossman/config.py) so a single missed poll tick doesn't
 * immediately flip a healthy host to unknown. */
export function agentHealthStatus(agent: { enrollment_state: string; last_seen_at: string | null }): BadgeStatus {
  if (agent.enrollment_state === 'revoked') return 'crit';
  if (agent.enrollment_state === 'pending') return 'warn';
  if (!agent.last_seen_at) return 'unknown';
  const ageMs = Date.now() - new Date(agent.last_seen_at).getTime();
  return ageMs < 120_000 ? 'ok' : 'unknown';
}

export function runStatusBadge(status: string): BadgeStatus {
  switch (status) {
    case 'succeeded':
      return 'ok';
    case 'failed':
      return 'crit';
    case 'running':
      return 'warn';
    default:
      return 'unknown';
  }
}

/** Maps a monitoring Service's OK/WARN/CRIT/UNKNOWN state (see
 * bossman/services/monitoring.py's compute_state) onto the same badge
 * palette as everything else in this app. */
export function serviceStateBadge(state: string): BadgeStatus {
  switch (state) {
    case 'OK':
      return 'ok';
    case 'WARN':
      return 'warn';
    case 'CRIT':
      return 'crit';
    default:
      return 'unknown';
  }
}

/** A service state as a COLOUR, for dots and chart strokes.
 *
 * Lives here with the other state→presentation mappings rather than inside host-detail, where it was
 * a private method: the Services tab, the Configuration tab's threshold builder and the process list
 * all ask the same question, and three private copies is how two of them end up disagreeing about
 * what UNKNOWN looks like. Moved for the same reason serviceMetricSpec was.
 *
 * Unknown states fall back to the UNKNOWN colour rather than to a default that would read as OK — an
 * unrecognised state must not look healthy.
 */
export function availabilityColor(state: string): string {
  return { OK: BM_GREEN, WARN: BM_GOLD, CRIT: BM_RED, UNKNOWN: BM_UNKNOWN }[state] ?? BM_UNKNOWN;
}
