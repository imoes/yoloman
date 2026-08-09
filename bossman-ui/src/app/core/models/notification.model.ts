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
}
