import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';
import { RoleContract } from '../../features/blueprint/compose-model';

/** A host that provides a capability, from the deterministic matcher (host_capabilities). */
export interface ProviderHit {
  agent_id: string;
  hostname: string | null;
  address: string | null;
  capability: string;
  backend: string | null;
  port: number | null;
  template: string;
  config_path: string | null;
  detail: Record<string, unknown>;
}

/** The catalog role a NEW server would need to provide a capability. */
export interface RoleHit {
  role: string;
  template: string;
  label: string;
  backend: string | null;
  default_port: number | null;
}

export interface ProvidersResponse {
  capability: string;
  backend: string | null;
  providers: ProviderHit[];
  roles: RoleHit[];
}

/**
 * The Blueprint editor's window onto the backend Lego matcher (services/capabilities.py, exposed at
 * /api/v1/capabilities/*). Role-grain plausibility comes from a template's capabilities.json (via the
 * config-templates endpoint); connection SUGGESTIONS (real inventory hosts + candidate roles) come from
 * the matcher. Pure reads — the same deterministic logic that backs the MCP + chat tools.
 */
@Injectable({ providedIn: 'root' })
export class CapabilitiesService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  /** The role-grain contract (provides/requires) for a config template, or null when it has none yet
   *  (e.g. the enrich batch hasn't reached it). */
  templateContract(name: string) {
    return this.http.get<{ name: string; capabilities?: RoleContract }>(`${this.base}/config-templates/${name}`);
  }

  /** Inventory hosts (and candidate roles) that provide `capability`, optionally restricted to a backend
   *  the consumer accepts (the backend expands aliases server-side). */
  providers(capability: string, backend?: string) {
    const params: Record<string, string> = { capability };
    if (backend) params['backend'] = backend;
    return this.http.get<ProvidersResponse>(`${this.base}/capabilities/providers`, { params });
  }
}
