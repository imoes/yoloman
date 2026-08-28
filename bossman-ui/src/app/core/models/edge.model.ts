/** One raw edge — matches bossman/api/relationships.py's EdgeOut. Only returned with `raw=true`. */
export interface HostEdge {
  src_agent_id: string;
  src_comm: string;
  dst_addr: string;
  /** Null for the collapsed client-port edge — see `client_ports`. Never 0: no socket listens on 0. */
  dst_port: number | null;
  /** True when the row is the fold of many client ports, not one measured service port. */
  client_ports: boolean;
  dst_agent_id: string | null;
  event_count: number;
  latency_ms_p50: number | null;
}

/** One process talking to one destination, however many ports that took — the DEFAULT shape.
 *
 * The raw edges are one row per (process, address, PORT), and for ephemeral-port traffic that is not a
 * relationship list: measured on one host, kubelet alone had 14 119 rows to 127.0.0.1, and the whole reply
 * was 5.46 MB for a table nobody can read. `ports` and `edges` say how many raw rows this line stands for. */
export interface HostEdgeGroup {
  src_agent_id: string;
  src_comm: string;
  dst_addr: string;
  /** The port, when the group has exactly one. Null when it has several — naming one of 14 119 would be
   *  presenting an arbitrary example as the answer — and null for the client-port fold. */
  dst_port: number | null;
  ports: number;
  /** True when this group includes the folded client-port edge: the poller collapses a peer's random high
   *  ports into one edge, because a port a client picked at random is not a relationship. Shown as
   *  "client ports" rather than as port 0, which is not a port. */
  client_ports: boolean;
  dst_agent_id: string | null;
  event_count: number;
  /** The p50 of the group's BUSIEST edge. There is no honest median-of-medians, and max() was measured to
   *  report 16 hours — one dead connection's timeout as the group's latency. */
  latency_ms_p50_busiest: number | null;
  edges: number;
}

export interface RelationshipsResponse {
  groups: HostEdgeGroup[];
  /** Only present when raw=true was requested. */
  edges?: HostEdge[] | null;
  total_edges: number;
  total_groups: number;
  truncated: boolean;
}
