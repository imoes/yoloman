/** Matches bossman/api/orchestration.py's PlanVersionOut — one immutable
 * version of an orchestration plan (Block L1): steps for the existing plan
 * engine + Go modules, and the monitoring/notifications this role
 * generates automatically ("what is orchestrated is monitored"). */
export interface OrchestrationPlanVersion {
  id: string;
  version: number;
  created_at: string;
  parameter_schema: Record<string, unknown>;
  default_parameters: Record<string, unknown>;
  requirements: Record<string, unknown>;
  steps: unknown[];
  rollback_steps: unknown[];
  validation_steps: unknown[];
  generated_monitoring: { checks?: string[]; thresholds?: Record<string, unknown> };
  generated_notifications: { routes?: string[] };
}

export type OrchestrationPlanType = 'role' | 'cluster' | 'deployment' | 'remediation' | 'maintenance' | 'bootstrap';

/** Matches bossman/api/orchestration.py's PlanOut. */
export interface OrchestrationPlan {
  id: string;
  name: string;
  display_name: string;
  description: string;
  plan_type: OrchestrationPlanType;
  enabled: boolean;
  current_version: number;
  created_at: string;
  versions: OrchestrationPlanVersion[];
}

/** Matches bossman/api/orchestration.py's PlanVersionIn — v1 UI scope only
 * exposes generated_monitoring (checks); steps/parameters stay API-only
 * for now (documented v1 simplification, mirrors how far the templates
 * dialog goes for structured vs. free-form fields). */
export interface OrchestrationPlanVersionInput {
  generated_monitoring?: { checks?: string[]; thresholds?: Record<string, unknown>; roles?: string[] };
  generated_notifications?: { routes?: string[] };
}

/** Matches bossman/api/orchestration.py's PlanIn. */
export interface OrchestrationPlanInput {
  name: string;
  display_name: string;
  description?: string;
  plan_type: OrchestrationPlanType;
  version?: OrchestrationPlanVersionInput;
}

export type PlanLinkTargetType = 'ou' | 'host' | 'group' | 'label_selector' | 'global';
export type PlanLinkStatus = 'pending_approval' | 'active' | 'rejected';

/** Matches bossman/api/orchestration.py's PlanLinkOut — the L2 approval
 * gate lives in `status`: a link only affects a host's compiled desired
 * state once status is "active" (see docs/plan.md's L2 block). */
export interface OrchestrationPlanLink {
  id: string;
  plan_id: string;
  plan_version: number | null;
  target_type: PlanLinkTargetType;
  ou_id: string | null;
  agent_id: string | null;
  host_group_id: string | null;
  parameters: Record<string, unknown>;
  priority: number;
  link_order: number;
  enforced: boolean;
  enabled: boolean;
  auto_apply: boolean;
  require_approval: boolean;
  status: PlanLinkStatus;
  created_at: string;
}

/** Matches bossman/api/orchestration.py's PlanLinkIn. Leaving auto_apply
 * false + require_approval true (the field defaults) is the safe path —
 * an admin ticking "activate immediately" in the UI is a deliberate,
 * human-driven auto_apply=true, the one case that's allowed to bypass
 * approval (see the L2 design: MCP can never set this itself). */
export interface OrchestrationPlanLinkInput {
  plan_version?: number | null;
  target_type: PlanLinkTargetType;
  ou_id?: string | null;
  agent_id?: string | null;
  host_group_id?: string | null;
  parameters?: Record<string, unknown>;
  priority?: number;
  link_order?: number;
  enforced?: boolean;
  auto_apply?: boolean;
  require_approval?: boolean;
}

/** Matches bossman/api/orchestration.py's CompiledStateOut — the
 * compiler's per-host output (docs/plan.md's L1 block). */
export interface CompiledHostState {
  agent_id: string;
  generation: number;
  config_hash: string;
  state: {
    host: { name: string; ou: string | null };
    monitoring: { checks: string[]; thresholds: Record<string, unknown>; notifications: string[] };
    orchestration: { roles: string[]; plans: { name: string; version: number; type: string; parameters: Record<string, unknown> }[] };
  };
  explain: Record<string, unknown>;
}

/** Matches bossman/api/orchestration.py's PlanLinkPreviewIn. */
export interface PlanLinkPreviewInput {
  plan_version?: number | null;
  target_type: PlanLinkTargetType;
  ou_id?: string | null;
  agent_id?: string | null;
  host_group_id?: string | null;
  parameters?: Record<string, unknown>;
}

/** Matches compiler.preview_plan_link's return shape (surfaced by
 * POST .../preview-link). Never persists anything. */
export interface PlanLinkPreview {
  plan_name: string;
  plan_version: number;
  affected_host_count: number;
  sample_diff: { host: string; checks_added: string[]; roles_added: string[] } | null;
}
