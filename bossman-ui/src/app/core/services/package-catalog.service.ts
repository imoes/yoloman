import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A per-OS-family package mapping (packages to install, service unit, main
 * config path). */
export interface PackageFamily {
  packages: string[];
  service: string;
  config_path: string;
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
