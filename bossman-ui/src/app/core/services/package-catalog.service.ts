import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { categorizeConfigPath } from '../../shared/config-categories';

/** A per-OS-family package mapping (packages to install, service unit, main
 * config path). */
export interface PackageFamily {
  packages: string[];
  service: string;
  config_path: string;
}

/** The category to group a catalog entry under. Empty on a DERIVED entry, because the path->category rule
 * lives in shared/config-categories.ts and re-implementing it in the generator would put one rule in two
 * languages. Empty therefore means "ask the path" — see catalogCategory(). */
export function catalogCategory(entry: CatalogPackage): string {
  if (entry.category) { return entry.category; }
  const path = entry.families?.debian?.config_path ?? entry.families?.redhat?.config_path ?? '';
  return path ? categorizeConfigPath(path).key : 'other';
}

/** One configurable server package (a "role" in Server-Manager terms). */
export interface CatalogPackage {
  label: string;
  category: string;
  icon: string;
  description: string;
  template: string | null; // config template name, or null if none yet
  // Windows-Server-Manager terms (see docs/roles-and-features.md):
  //   role    = a primary network service, install + configure + run + a monitoring check.
  //   feature = installed + configured + run like a role, but auxiliary — NO monitoring check.
  //   config  = a base-system config file, not installable (Configuration tab / gpedit only).
  kind?: 'role' | 'feature' | 'config';
  /** How this entry came to exist: absent = curated by hand, "index-promoted" = derived from a measured
   * path->template binding plus a measured systemd unit (bossman/scripts/promote_index_to_catalog.py). A
   * curated entry carries a human's label, service and validate_cmd, so the two must stay distinguishable. */
  source?: string;
  /** Why this entry's `service` is what it is — or why it has none. Shown rather than implied: an entry
   * offering "start this" for a unit nobody verified is an action that fails. */
  service_evidence?: string;
  validate_cmd?: string;
  families: { debian?: PackageFamily; redhat?: PackageFamily };
}

/** The installation-wizard / Roles & Features catalog (Block 0). */
@Injectable({ providedIn: 'root' })
export class PackageCatalogService {
  private http = inject(HttpClient);

  catalog() {
    return this.http.get<{ packages: Record<string, CatalogPackage> }>(`${environment.apiUrl}/package-catalog`);
  }
}
