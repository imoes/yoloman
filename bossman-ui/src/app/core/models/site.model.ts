/** Matches bossman/api/sites.py's SiteOut — an AD Sites-and-Services object: a
 * policy scope defined by SUBNETS (CIDRs), not explicit membership. A host
 * belongs to a site when its primary IP is in one of the subnets. GPO
 * precedence: global < host-group < OU < Site < host. */
export interface Site {
  id: string;
  name: string;
  description: string;
  ou_id: string | null;
  subnets: string[];
  created_at: string;
}

/** Matches bossman/api/sites.py's SiteIn. */
export interface SiteInput {
  name: string;
  description?: string;
  ou_id?: string | null;
  subnets?: string[];
}
