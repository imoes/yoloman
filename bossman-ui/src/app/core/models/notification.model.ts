/** Matches bossman/api/notifications.py (Block H8). */

export type NotificationChannel = 'email' | 'webhook' | 'slack' | 'teams' | 'telegram' | 'pagerduty' | 'discord';

export interface NotificationRule {
  id: string;
  name: string;
  enabled: boolean;
  on_problem: boolean;
  on_recovery: boolean;
  min_state: 'WARN' | 'CRIT' | 'UNKNOWN';
  host_filter: string | null;
  service_filter: string | null;
  channel: NotificationChannel;
  target: string;
  /** On-call escalation: fire only once a hard problem is unacked this many
   * minutes (null = immediate). */
  escalate_after_minutes?: number | null;
  /** L4: only notify while this time period is active. null = always. */
  time_period_id?: string | null;
  created_at: string;
  /** Block L3a: OU binding + GPO precedence (optional; null ou_id = global). */
  ou_id?: string | null;
  enforced?: boolean;
  link_order?: number;
  /** Block N1: the shared scope model. A notification fires (additively) for
   * every event its scope covers. */
  scope_type?: NotificationScope;
  scope_value?: string | null; // group name (group) or agent (host/service)
  scope_service_name?: string | null; // for scope_type=service
  scope_plan_id?: string | null; // for scope_type=policy
}

export type NotificationScope = 'global' | 'ou' | 'group' | 'host' | 'service' | 'policy';

export type NotificationRuleInput = Omit<NotificationRule, 'id' | 'created_at'>;

export interface NotificationLogEntry {
  id: string;
  agent_name: string;
  service_name: string;
  event: 'problem' | 'recovery';
  state: string;
  channel: NotificationChannel;
  target: string;
  status: 'sent' | 'failed';
  error: string | null;
  created_at: string;
}


/** L4: a reusable notification window (matches api/time_periods.py's TimePeriodOut). */
export interface TimePeriod {
  id: string;
  name: string;
  alias: string;
  ranges: Record<string, string[][]>;
  exceptions: Record<string, string[][]>;
  excludes: string[];
  is_builtin: boolean;
  created_at: string;
  /** Evaluated server-side at request time — the dialog shows it so a window that is
   * closed right now is obvious before it silences anything. */
  active_now: boolean;
  /** WHICH clock the window is read in. Shown because a window read in the wrong zone is
   * off by the local offset and that is invisible from the definition alone. */
  timezone: string;
  /** Send back as If-Match on PUT: a concurrent edit is then a 412 instead of a silent
   * overwrite. `active_now`/`timezone` are excluded from it server-side because they move
   * with the clock (api/etag.py). */
  version: string;
}

/** What a client may write — the server owns id, is_builtin, created_at, active_now and the
 * version. */
export interface TimePeriodInput {
  name: string;
  alias: string;
  /** weekday -> [["08:00", "17:00"], ...]. No overnight spans: the validator refuses an
   * end at or before the start, because 22:00-02:00 would be a window that never matches
   * (split it into 22:00-24:00 and 00:00-02:00). */
  ranges: Record<string, string[][]>;
  /** "YYYY-MM-DD" -> spans; an EMPTY list means closed all day. */
  exceptions: Record<string, string[][]>;
  /** Names (not ids) of periods that deactivate this one while they are active. */
  excludes: string[];
}

/** api/time_periods.py's /usage — what a change to this window would affect, asked BEFORE
 * editing rather than discovered after. */
export interface TimePeriodUsage {
  id: string;
  name: string;
  active_now: boolean;
  timezone: string;
  notification_rules: { id: string; name: string; enabled: boolean }[];
  excluded_by: string[];
}
