/** Matches bossman/api/relationships.py's EdgeOut. */
export interface HostEdge {
  src_agent_id: string;
  src_comm: string;
  dst_addr: string;
  dst_port: number;
  dst_agent_id: string | null;
  event_count: number;
  latency_ms_p50: number | null;
}
