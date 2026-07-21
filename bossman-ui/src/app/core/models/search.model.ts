/** Matches bossman/api/search.py. The Checkmk-style fleet search. */

export type SearchEntityType = 'host' | 'host_group' | 'service';

/** One grouped dropdown row (the live preview). */
export interface SearchResultItem {
  type: SearchEntityType;
  id?: string | null;
  title: string;
  subtitle?: string | null;
  state?: string | null;
  query_params: { type: string; q: string };
}

export interface UnifiedSearchResponse {
  hosts: SearchResultItem[];
  host_groups: SearchResultItem[];
  services: SearchResultItem[];
  counts: Record<string, number>;
}

/** One host row in the full "hosts matching X" result view. */
export interface HostResult {
  id: string;
  name: string;
  address: string | null;
  criticality: string | null;
  site: string | null;
  groups: string[];
  enrollment_state: string;
  last_seen_at: string | null;
  state_rollup: string;
}

export interface HostSearchResponse {
  hosts: HostResult[];
  total: number;
}

/** One service-check row in the full "service-checks matching X" result view. */
export interface ServiceResult {
  id: string;
  agent_id: string;
  host: string;
  name: string;
  metric: string;
  state: string;
  value: number | null;
  output: string;
  criticality: string | null;
  site: string | null;
  last_checked: string;
}

export interface ServiceSearchResponse {
  services: ServiceResult[];
  total: number;
}

/** Body of POST /agents/mass-update/facets — bulk-assign the searchable
 * facets. Omit a field to leave it; '' clears criticality/site. */
export interface MassAssignFacets {
  agent_ids: string[];
  criticality?: string | null;
  site?: string | null;
  add_tags?: Record<string, string>;
  remove_tags?: string[];
}
