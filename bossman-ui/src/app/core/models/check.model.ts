/** Block G9 — the check library + assignments. Mirrors bossman/api/checks.py. */

export interface CheckOption {
  type?: string;
  required?: boolean;
  default?: unknown;
  choices?: unknown[];
  description?: string;
}

/** A check in the library (checks.d). */
export interface CheckCatalogEntry {
  name: string;
  kind: string;
  source: string;
  short_description?: string;
  category?: string;
  options: Record<string, CheckOption>;
}

/** One effective check for a host (resolved GPO-style). */
export interface EffectiveCheck {
  check_name: string;
  parameters: Record<string, unknown>;
  source_scope: 'host' | 'group' | 'ou';
  source_scope_id: string | null;
  assignment_id: string;
  contributing: string[];
  short_description?: string;
  options: Record<string, CheckOption>;
  in_library: boolean;
}

export interface CheckAssignment {
  id: string;
  check_name: string;
  scope_type: 'ou' | 'group' | 'host';
  ou_id: string | null;
  agent_id: string | null;
  host_group_id: string | null;
  parameters: Record<string, unknown>;
  enabled: boolean;
  source: string;
}

/** Block G9-P3c — one auto-discovery proposal for a host. */
export interface DiscoveredItemProposal {
  item: string;
  params: Record<string, unknown>;
  metrics: string[];
}

export interface DiscoveryProposal {
  check_name: string;
  short_description: string;
  items: DiscoveredItemProposal[];
  needs_params: string[];
  error: string;
}

export interface CreateCheckAssignment {
  check_name: string;
  scope_type: 'ou' | 'group' | 'host';
  ou_id?: string | null;
  agent_id?: string | null;
  host_group_id?: string | null;
  parameters?: Record<string, unknown>;
  source?: string;
}
