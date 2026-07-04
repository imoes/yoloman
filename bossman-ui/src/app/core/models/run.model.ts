/** Matches bossman/api/runs.py's PlanRunOut. */
export interface PlanRun {
  id: string;
  plan_name: string;
  plan_version: string | null;
  agent_id: string;
  params: Record<string, unknown>;
  dry_run: boolean;
  status: 'running' | 'succeeded' | 'failed' | 'aborted';
  started_at: string;
  finished_at: string | null;
  requested_by: string | null;
}

/** Matches bossman/api/runs.py's PlanRunStepOut. */
export interface PlanRunStep {
  step_index: number;
  step_name: string;
  module: string | null;
  request_body: Record<string, unknown>;
  response_body: Record<string, unknown> | null;
  changed: boolean | null;
  http_status: number | null;
  error: string | null;
  started_at: string;
  finished_at: string | null;
}

/** Matches bossman/api/runs.py's PlanRunDetailOut. */
export interface PlanRunDetail extends PlanRun {
  steps: PlanRunStep[];
}
