/** Matches bossman/api/plans.py's PlanParamOut. */
export interface PlanParam {
  type: string;
  required: boolean;
  pattern: string | null;
  default: unknown;
}

/** Matches bossman/api/plans.py's PlanOut. */
export interface Plan {
  name: string;
  description: string;
  params: Record<string, PlanParam>;
}

/** Matches bossman/api/plans.py's step dict shape (see _step_out). */
export interface PlanStep {
  name: string;
  kind: 'module' | 'pipeline' | 'upload';
  check_mode: boolean;
  on_failure: 'abort' | 'continue';
  module: string | null;
  body: Record<string, unknown>;
  pipeline: string[][] | null;
  upload_local_path: string | null;
  upload_remote_name: string | null;
}

/** Matches bossman/api/plans.py's PlanDetailOut. */
export interface PlanDetail extends Plan {
  steps: PlanStep[];
}

export interface RunPlanRequest {
  agent: string;
  params: Record<string, unknown>;
  dry_run: boolean;
}

/** Matches bossman/api/plans.py's RunPlanResponse. */
export interface RunPlanResponse {
  plan_run_id: string;
  status: string;
}
