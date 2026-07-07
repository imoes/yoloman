/** Matches bossman/api/notifications.py (Block H8). */

export type NotificationChannel = 'email' | 'webhook';

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
  created_at: string;
}

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
