/** Event rules (API: /api/v1/event-rules, engine: services/remediation.py).
 *
 * A rule binds a TRIGGER (a check entering a hard problem state, within a scope) to an ACTION.
 * The action is exactly one of two things, enforced by a CHECK constraint:
 *
 *   runbook_name       the original inline form
 *   event_handler_id   a reusable EventHandler, which may be a script
 *
 * Both would be two answers to "what runs?"; neither would be a rule that fires and does
 * nothing. The editor therefore offers ONE choice, never two fields.
 *
 * The DATABASE tables and ORM classes are still `remediation_*`: renaming a table is a migration
 * and an irreversible step for stored data, so code and table stay aligned and the operator-facing
 * vocabulary is translated in exactly two places — here and api/remediation.py's header. Two names
 * with a stated mapping beats three names.
 */

export type RuleScope = 'global' | 'ou' | 'group' | 'host';
/** auto = act when the trigger fires; propose = record a suggestion for a human to apply. */
export type RuleMode = 'auto' | 'propose';
/** propose = a human applies; auto_verify = apply automatically when the guardrails pass, then
 * verify and escalate or roll back. A global kill-switch must also be on. */
export type RuleAutonomy = 'propose' | 'auto_verify';

export interface EventRule {
  id: string;
  name: string;
  /** Empty means every check — not "no check". */
  match_service_name: string;
  scope_type: RuleScope;
  ou_id: string | null;
  host_group_id: string | null;
  agent_id: string | null;
  conditions: Record<string, unknown>;
  runbook_name: string;
  event_handler_id: string | null;
  /** Values for the handler's declared parameters. Only Bossman configures these. */
  params: Record<string, unknown>;
  max_per_hour: number;
  mode: RuleMode;
  enabled: boolean;
  verify: boolean;
  verify_after_s: number;
  autonomy: RuleAutonomy;
  allow_prod: boolean;
  max_blast_radius: number;
  rollback_runbook: string | null;
}

export type EventRuleInput = Omit<EventRule, 'id'>;

/** One recorded run — the observation point for "what happened and why".
 *
 * `action` is "kind:name" ("runbook:restart-nginx", "handler:clean-logs") and is STORED on the
 * run: policy_id is ON DELETE SET NULL, so a deleted rule would otherwise take the answer with
 * it and leave a history that lists events it cannot explain. */
export interface EventRun {
  id: string;
  policy_id: string | null;
  agent_id: string | null;
  service_name: string;
  runbook_name: string;
  action: string;
  /** pending | ran | rate_limited | failed */
  status: string;
  detail: string | null;
  at: string;
  /** The closed-loop lifecycle: proposed → applied → verified → escalated/rolled back. */
  phase: string;
  applied_at: string | null;
  verified_at: string | null;
  verify_state: string | null;
  verify_ok: boolean | null;
  outcome: string | null;
}
