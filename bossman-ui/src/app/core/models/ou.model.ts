/** Matches bossman/api/ou.py's OUNodeOut — one node in the Policy/
 * Orchestration OU tree (Block L1). A host lives at exactly one OU
 * (AD-style); path is the materialized slash-path (e.g.
 * "/Germany/Munich/Prod"), unique per tenant. */
export interface OUNode {
  id: string;
  parent_id: string | null;
  name: string;
  path: string;
  /** Block L3a: materialized ltree label-path (e.g. "Germany.Munich.Prod"). */
  ltree_path: string;
  /** Block L3a: GPO "Block Inheritance" — drops inherited non-enforced rules from above. */
  block_inheritance: boolean;
  created_at: string;
}

/** Matches bossman/api/ou.py's OUNodeIn. */
export interface OUNodeInput {
  name: string;
  parent_id?: string | null;
}

/** Matches bossman/api/ou.py's OUObject — one policy object attached
 * directly to an OU (Block L3a), the tree's per-node child list. */
export interface OUObject {
  kind: 'check_rule' | 'notification' | 'host_group' | 'orchestration_link' | 'config_policy';
  id: string;
  label: string;
  enforced: boolean;
  enabled: boolean;
  /** orchestration_link only: the underlying plan, so the palette can
   * re-scope a link to another OU by relinking that plan. */
  plan_id?: string | null;
}
