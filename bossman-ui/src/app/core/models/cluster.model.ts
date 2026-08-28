/** Host clusters (API: /api/v1/clusters, aggregation: services/clustering.py).
 *
 * A cluster IS a host: an `agents` row with mode="cluster" and no address, so it already
 * has services, problems, acknowledgement, downtime, notification rules, OU placement and
 * a UI. Nothing polls it — its services are computed once per poll cycle from its nodes.
 *
 * Called "host cluster" in the UI, never bare "cluster": the app already talks about
 * Kubernetes clusters (Helm releases, kubeconfig) and Proxmox clusters (inventory), and
 * these three are different things. */

/** worst | best | failover — the API's `clustering.MODES`. "native" is deliberately absent:
 * no Starlark check has a cluster entry point, so the mode's only possible outcome would be
 * an error message. */
export type AggregationMode = 'worst' | 'best' | 'failover';

export interface ClusterNodeRef {
  id: string;
  name: string;
  is_primary: boolean;
}

export interface Cluster {
  id: string;
  name: string;
  aggregation_mode: AggregationMode;
  primary_node_id: string | null;
  /** Exact service names, or a trailing "*" as a prefix match ("Disk *"). Decides which
   * services belong to the CLUSTER instead of to the node. */
  service_patterns: string[];
  nodes: ClusterNodeRef[];
  created_at: string;
  /** What the cluster reports RIGHT NOW (service name → state). Server-computed, not part
   * of `version` — it follows the fleet, and a version that moved on its own would reject
   * every save. This is the observation point for "did my patterns match anything?". */
  service_states: Record<string, string>;
  /** Send back as If-Match on PUT: a concurrent edit then becomes a 412 instead of a
   * silent overwrite (api/etag.py). */
  version: string;
}

export interface ClusterInput {
  name: string;
  aggregation_mode: AggregationMode;
  node_ids: string[];
  primary_node_id: string | null;
  service_patterns: string[];
}
