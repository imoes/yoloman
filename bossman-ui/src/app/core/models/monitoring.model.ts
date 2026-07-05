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
  acknowledged: boolean;
  ack_comment: string | null;
  ack_by: string | null;
  in_downtime: boolean;
}

/** Matches bossman/api/monitoring.py's ServiceHistoryPointOut. */
export interface ServiceHistoryPoint {
  time: string;
  state: string;
  value: number | null;
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
export type CheckRuleScope = 'global' | 'group' | 'host';

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
  enabled: boolean;
  created_at: string;
}

export type CheckRuleInput = Omit<CheckRule, 'id' | 'created_at'>;

/** Matches bossman/api/monitoring.py's FleetSummaryOut. */
export interface FleetSummary {
  hosts_total: number;
  hosts_by_enrollment: Record<string, number>;
  services_by_state: Record<string, number>;
  open_problems: number;
}
