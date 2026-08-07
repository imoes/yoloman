/** Matches bossman/api/monitoring.py's ServiceOut. */
export interface ServiceState {
  id: string;
  agent_id: string;
  agent_name: string;
  name: string;
  metric: string;
  state: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN';
  value: number | null;
  output: string;
  last_state_change: string;
  last_checked: string;
  /** Soft/hard debouncing (Block H7): 'soft' = an unconfirmed non-OK blip
   * (not yet a problem), 'hard' = confirmed over max_attempts checks. */
  state_type: 'soft' | 'hard';
  attempt: number;
  max_attempts: number;
  is_flapping: boolean;
  acknowledged: boolean;
  ack_comment: string | null;
  ack_by: string | null;
  ack_expires_at: string | null;
  in_downtime: boolean;
  /** Block K4: the value-mapped label for `value` (e.g. 0 → "Down"), or null. */
  mapped_value: string | null;
  /** F-17: the owning rule's thresholds + comparison, so the UI can show
   * what the value is graded against. Null for rule-less builtins. */
  warn_threshold: number | null;
  crit_threshold: number | null;
  comparison: CheckRuleComparison | null;
}

/** Matches bossman/api/monitoring.py's ServiceHistoryPointOut. */
export interface ServiceHistoryPoint {
  time: string;
  state: string;
  value: number | null;
}

/** Matches bossman/api/monitoring.py's AvailabilityOut (Block H9). */
export interface AvailabilitySlice {
  state: string;
  seconds: number;
  percent: number;
}

export interface Availability {
  agent_id: string;
  service_name: string;
  start: string;
  end: string;
  window_seconds: number;
  monitored_seconds: number;
  ok_percent: number;
  state_changes: number;
  slices: AvailabilitySlice[];
}

/** Matches bossman/api/monitoring.py's DowntimeOut. */
export interface Downtime {
  id: string;
  agent_id: string;
  service_name: string | null;
  starts_at: string;
  ends_at: string;
  comment: string;
  created_by: string | null;
  created_at: string;
}

export type CheckRuleComparison = 'gt' | 'lt' | 'ge' | 'le' | 'eq' | 'ne';
export type CheckRuleScope = 'global' | 'group' | 'host' | 'ou' | 'site';

/** Matches bossman/api/monitoring.py's CheckRuleOut. */
export interface CheckRule {
  id: string;
  service_name: string;
  metric: string;
  comparison: CheckRuleComparison;
  warn_threshold: number | null;
  crit_threshold: number | null;
  scope_type: CheckRuleScope;
  scope_value: string | null;
  /** Block L3a: OU-scoped rule + GPO precedence. */
  scope_ou_id: string | null;
  /** Site (subnet) scope — set iff scope_type='site' (precedence OU<Site<host).
   * Optional so existing host/OU CheckRuleInput literals need not set it. */
  scope_site_id?: string | null;
  enforced: boolean;
  link_order: number;
  /** Optional label pin (a disk mount) — see CheckRule.label_value (H6). */
  label_value: string | null;
  /** Consecutive non-OK checks before hard (Block H7); null = global default. */
  max_attempts: number | null;
  is_default: boolean;
  enabled: boolean;
  created_at: string;
}

export type CheckRuleInput = Omit<CheckRule, 'id' | 'created_at' | 'is_default'>;

/** Matches bossman/api/monitoring.py's MetricCatalogEntry (Block L3c) — a
 * metric actually collected across the fleet, with a human-readable name. */
export interface MetricCatalogEntry {
  metric: string;
  display_name: string;
  unit: string;
  /** One-line description shown in smaller text under the name in the
   * threshold dialog's Miller list (falls back to "Raw metric: <key>"). */
  description?: string;
}

/** One candidate rule in the effective-parameters view (Block E) — matches
 * bossman/api/monitoring.py's EffectiveRuleCandidateOut. */
export interface EffectiveRuleCandidate {
  rule_id: string;
  scope_type: string;
  scope_label: string;
  level: number;
  enforced: boolean;
  comparison: string | null;
  warn_threshold: number | null;
  crit_threshold: number | null;
  is_winner: boolean;
  reason: string;
}

/** Per metric+label, the rule that WINS on a host and the losers + why —
 * matches bossman/api/monitoring.py's EffectiveThresholdOut. */
export interface EffectiveThreshold {
  metric: string;
  display_name: string;
  label_value: string | null;
  service_name: string;
  candidates: EffectiveRuleCandidate[];
}

/** Matches bossman/api/monitoring.py's FleetSummaryOut. */
export interface FleetSummary {
  hosts_total: number;
  hosts_by_enrollment: Record<string, number>;
  services_by_state: Record<string, number>;
  open_problems: number;
}

/** Matches bossman/api/monitoring.py's FleetHostOut — the host-overview
 * table's data source (see docs/plan.md's monitoring-cockpit ergänzung
 * Block F2/F3): real CPU/mem/disk values + a CheckMK-style state rollup,
 * one row per host including satellites discovered behind a proxy. */
export interface FleetHost {
  id: string;
  name: string;
  parent_agent_id: string | null;
  parent_name: string | null;
  mode: string;
  enrollment_state: string;
  /** Agent build version; "" until the host has answered a /healthz. */
  agent_version: string;
  last_seen_at: string | null;
  state_rollup: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN';
  cpu_load: number | null;
  mem_used_pct: number | null;
  disk_used_pct_max: number | null;
  service_counts: Record<string, number>;
}
