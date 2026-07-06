/** Matches bossman/api/agents.py's AgentOut. */
export interface Agent {
  id: string;
  name: string;
  address: string | null;
  mode: string;
  enrollment_state: string;
  last_seen_at: string | null;
  metadata: Record<string, unknown>;
  groups: string[];
  parent_agent_id: string | null;
}

export interface MetricPoint {
  time: string;
  value: number;
  labels: Record<string, string>;
}

export interface MetricSeriesResponse {
  metric: string;
  points: MetricPoint[];
}

export interface MetricCatalogResponse {
  metrics: string[];
}

/** One metric's newest sample — the "last value / last check" row of the
 * host-detail Metrics tab's latest-data list (matches agents.py's
 * LatestMetricOut). One entry per metric name. */
export interface LatestMetric {
  metric: string;
  time: string;
  value: number;
  labels: Record<string, string>;
}

export interface LatestMetricsResponse {
  metrics: LatestMetric[];
}
