/** Matches bossman/api/host_groups.py's HostGroupOut — a first-class,
 * many-to-many host group (Block L1), distinct from the legacy flat
 * Agent.groups string list: a group lives inside an OU but a host can
 * belong to any number of groups (the AD model's cross-cutting
 * membership, alongside its single OU placement). */
export interface HostGroup {
  id: string;
  name: string;
  description: string;
  ou_id: string | null;
  created_at: string;
  member_agent_ids: string[];
}

/** Matches bossman/api/host_groups.py's HostGroupIn. */
export interface HostGroupInput {
  name: string;
  description?: string;
  ou_id?: string | null;
}
