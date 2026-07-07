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
  /** The host's HW/SW inventory document (Go agent internal/inventory,
   * Block H2) — {} until the first poll after enrollment. */
  facts: InventoryFacts;
  facts_updated_at: string | null;
}

/** Mirrors internal/inventory.Inventory's JSON shape (all optional —
 * missing sources are omitted by the agent). */
export interface InventoryFacts {
  collected_at?: string;
  system?: {
    manufacturer?: string;
    product_name?: string;
    serial_number?: string;
    uuid?: string;
    family?: string;
    version?: string;
    chassis_type?: string;
    virtualization?: string;
  };
  board?: { vendor?: string; name?: string; serial?: string; version?: string };
  bios?: { vendor?: string; version?: string; date?: string; release?: string };
  cpu?: {
    model?: string;
    vendor?: string;
    sockets?: number;
    cores?: number;
    threads?: number;
    mhz?: string;
    cache?: string;
    architecture?: string;
  };
  memory_mb?: number;
  os?: {
    distribution?: string;
    version?: string;
    id?: string;
    pretty_name?: string;
    codename?: string;
    kernel?: string;
    hostname?: string;
  };
  disks?: { name: string; size_bytes?: number; model?: string; serial?: string; rotational?: boolean }[];
  nics?: { name: string; mac?: string; state?: string; mtu?: number; speed_mbps?: number }[];
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
