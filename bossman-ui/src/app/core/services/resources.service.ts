import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/** A docker container's desired/observed spec (the Resource's values). */
export interface DockerSpec {
  name?: string;
  image: string;
  ports: { host: number | string; container: number | string }[];
  env: Record<string, unknown>;
  volumes: string[];
  restart: string;
}

export interface ResourcePlan {
  action: 'create' | 'update' | 'noop';
  changed: Record<string, [unknown, unknown]>;
  changed_count: number;
  observed?: DockerSpec | null;
  desired?: DockerSpec;
  resource_key?: string;
}

export interface ResourceGeneration {
  generation: number;
  spec: DockerSpec;
  note?: string | null;
  applied_by?: string | null;
  applied_at?: string | null;
}

export interface ApplyResult {
  dry_run: boolean;
  ok?: boolean;
  generation?: number;
  error?: string;
  plan?: ResourcePlan;
}

/** Resource / Deployable client (docs/resource-protocol.md) — the four verbs for
 * the docker_container tier: observe / plan / apply / generations / rollback,
 * plus schema (drives the node's form). */
@Injectable({ providedIn: 'root' })
export class ResourcesService {
  private http = inject(HttpClient);
  private base = `${environment.apiUrl}/agents`;

  private docker(id: string, name: string) {
    return `${this.base}/${id}/resources/docker/${encodeURIComponent(name)}`;
  }

  schema(id: string, name: string) {
    return this.http.get<{ resource_key: string; type: string; schema: Record<string, unknown> }>(`${this.docker(id, name)}/schema`);
  }
  observe(id: string, name: string) {
    return this.http.get<{ resource_key: string; observed: DockerSpec | null }>(`${this.docker(id, name)}/observe`);
  }
  plan(id: string, name: string, desired: Partial<DockerSpec>) {
    return this.http.post<ResourcePlan>(`${this.docker(id, name)}/plan`, desired);
  }
  apply(id: string, name: string, desired: Partial<DockerSpec>, dry_run: boolean, note?: string) {
    return this.http.post<ApplyResult>(`${this.docker(id, name)}/apply`, { ...desired, dry_run, note });
  }
  generations(id: string, name: string) {
    return this.http.get<{ resource_key: string; generations: ResourceGeneration[] }>(`${this.docker(id, name)}/generations`);
  }
  rollback(id: string, name: string, generation: number) {
    return this.http.post<ApplyResult>(`${this.docker(id, name)}/rollback`, { generation });
  }
}
