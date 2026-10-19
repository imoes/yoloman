import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map, switchMap, of } from 'rxjs';
import { environment } from '../../../environments/environment';
import { ParamSchema } from '../../shared/param-form/param-form.types';

/** How the catalog answered for THIS host's OS family. Exhaustive and mutually exclusive —
 * see bossman/api/package_wizard.py:_resolve_family for the measurement behind it.
 *
 *   exact        the family has its own curated branch
 *   fallback     it has none; another family's names are shown and `reason` says so
 *   unavailable  the catalog states it does not exist here (AppArmor on RHEL) — not installable
 *   unknown      no package names in any family
 */
export type FamilyMatch = 'exact' | 'fallback' | 'unavailable' | 'unknown';

export interface ResolvedPackage {
  packages: string[];
  service: string;
  config_path: string;
  /** The account the service runs as (www-data / apache / wwwrun). Empty = not curated. */
  user: string;
  family_match: FamilyMatch;
  /** Which family's branch supplied the values above — differs from the host's on `fallback`. */
  family_used: string;
  /** Fields this family's own template has for the role's file; null when the role's named template renders here. */
  family_fields?: string[] | null;
  /** Why it is a fallback, or why it cannot be installed. Empty only when `exact`. */
  reason: string;
  installable: boolean;
  /** What to use instead; when it names a catalog entry the UI links to that role. */
  instead?: string;
}

export interface WizardContext {
  host: string; // DNS name of the agent (for display)
  family: string;
  installed: Record<string, string>; // catalog pkg -> installed version
  catalog_resolved: Record<string, ResolvedPackage>;
}

export interface WizardRunbook {
  id: string;
  name: string;
  /** The runbook rendered as Ansible task YAML — the only authoring format. */
  playbook: string;
  parameters: ParamSchema;
}

export interface RunbookStepResult {
  name: string;
  module: string;
  status: string; // ok | changed | failed | skipped
  error?: string;
  response?: unknown;
}
export interface RunbookRunResult {
  ok?: boolean;
  aborted?: boolean;
  changed?: boolean;
  steps: RunbookStepResult[];
}

export interface RoleDeploymentTarget {
  id: string;
  item_id: string;
  agent_id: string;
  /** The host's name (null only when the host row is gone). */
  host?: string | null;
  phase: string;
  state: string;
  last_error?: string | null;
  /** Why a main-phase target has not started yet (the worker's pilot gate), or null. */
  waiting_for?: string | null;
}

export interface RoleDeploymentDetail {
  id: string;
  name: string;
  status: 'draft' | 'pending_approval' | 'active' | 'paused' | 'failed' | 'retired';
  scope_type: 'host' | 'group' | 'ou' | 'site' | 'global';
  agent_id?: string | null;
  host_group_id?: string | null;
  ou_id?: string | null;
  site_id?: string | null;
  created_by?: string | null;
  approved_by?: string | null;
  compliance: Record<string, number>;
  items: {
    id: string; name: string; display_name: string; kind: 'role' | 'feature'; version: number;
    /** Why Uninstall is impossible for this item (not catalog-backed), or null. */
    uninstall_blocked?: string | null;
  }[];
  targets: RoleDeploymentTarget[];
}

export interface RoleArtifact {
  id: string;
  name: string;
  display_name: string;
  description: string;
  kind: 'role' | 'feature';
  current_version: number;
  parameter_schema: ParamSchema;
  default_parameters: Record<string, unknown>;
}

export interface RoleDeploymentRequest {
  target: { type: 'host' | 'group' | 'ou' | 'site' | 'global'; id?: string };
  items: { plan_id?: string; catalog_name?: string; plan_version?: number; parameters: Record<string, unknown> }[];
  pilot_enabled?: boolean;
}

export interface RoleDeploymentPreview {
  preview_hash: string;
  affected_host_count: number;
  agent_ids: string[];
  artifacts: { plan_id: string; name: string; display_name: string; kind: string; version: number }[];
  approval_required: boolean;
  pilot_enabled: boolean;
  pilot_agent_id?: string;
  applicability: {
    plan_id: string;
    name: string;
    applicable_host_count: number;
    not_applicable: { agent_id: string; host?: string; reason: string }[];
    /** Applicable only by using another OS family's package names — counted as applicable, said apart. */
    substituted?: { agent_id: string; host?: string; reason: string }[];
  }[];
}

/** Backs the installation wizard: host context, the seeded install-<pkg>
 * runbooks (by name), and running them (dry-run preview + real apply). */
@Injectable({ providedIn: 'root' })
export class WizardService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  context(agentId: string, refresh = false) {
    return this.http.get<WizardContext>(`${this.base}/agents/${agentId}/package-wizard/context${refresh ? '?refresh=true' : ''}`);
  }

  /** Every runbook's name and kind. Used by the event-handler editor to offer a body: a handler
   * whose body is a runbook resolves it BY NAME server-side, and `kind` matters because a role
   * cannot be a handler body (the service answers "missing or is a role"). */
  listRunbooks() {
    return this.http.get<{ runbooks: { id: string; name: string; kind: string; folder: string }[] }>(
      `${this.base}/runbooks`,
    );
  }

  /** Resolve a seeded runbook by name → its id, Ansible-YAML source and parameter mask. */
  runbookByName(name: string): Observable<WizardRunbook | null> {
    return this.http.get<{ runbooks: { id: string; name: string }[] }>(`${this.base}/runbooks`).pipe(
      map((r) => r.runbooks.find((x) => x.name === name)),
      switchMap((rb) => rb
        ? this.http.get<{ id: string; name: string; playbook: string; parameters: ParamSchema }>(`${this.base}/runbooks/${rb.id}`)
            .pipe(map((full) => ({ id: full.id, name: full.name, playbook: full.playbook, parameters: full.parameters || {} })))
        : of(null)),
    );
  }

  run(agentId: string, playbook: string, variables: Record<string, unknown>, dryRun: boolean) {
    // The endpoint spreads the run result at the top level (run_id, steps, ok, …).
    return this.http.post<RunbookRunResult & { run_id: string; runbook: string }>(
      `${this.base}/agents/${agentId}/runbook/run`, { playbook, variables, dry_run: dryRun },
    );
  }

  /** Create the durable desired-state deployment behind the host wizard.
   * Preview locks the resolved membership; active single-host deployments are
   * reconciled immediately, while approval-gated ones remain visibly pending. */
  deployCatalog(
    agentId: string,
    hostName: string,
    items: { catalog_name: string; parameters: Record<string, unknown> }[],
  ): Observable<RoleDeploymentDetail> {
    const previewBody = { target: { type: 'host', id: agentId }, items, pilot_enabled: false };
    return this.http.post<{ preview_hash: string }>(`${this.base}/role-deployments/preview`, previewBody).pipe(
      switchMap((preview) => this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments`, {
        ...previewBody,
        name: `Roles & Features — ${hostName}`,
        preview_hash: preview.preview_hash,
      })),
      switchMap((deployment) => deployment.status === 'active'
        ? this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments/${deployment.id}/reconcile`, {})
        : of(deployment)),
    );
  }

  listRoleDeployments() {
    return this.http.get<{ deployments: RoleDeploymentDetail[] }>(`${this.base}/role-deployments`);
  }

  listRoleArtifacts() {
    return this.http.get<{ artifacts: RoleArtifact[] }>(`${this.base}/role-artifacts`);
  }

  previewRoleDeployment(body: RoleDeploymentRequest) {
    return this.http.post<RoleDeploymentPreview>(`${this.base}/role-deployments/preview`, body);
  }

  createRoleDeployment(body: RoleDeploymentRequest & { name: string; preview_hash: string; require_approval?: boolean }) {
    return this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments`, body);
  }

  approveRoleDeployment(deploymentId: string) {
    return this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments/${deploymentId}/approve`, {});
  }

  reconcileRoleDeployment(deploymentId: string) {
    return this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments/${deploymentId}/reconcile`, {});
  }

  remediateRoleTargets(deploymentId: string, targetIds: string[]) {
    return this.http.post<{ requested: number }>(
      `${this.base}/role-deployments/${deploymentId}/remediate`, { target_ids: targetIds },
    );
  }

  retireRoleDeployment(deploymentId: string, behavior: 'unmanage' | 'uninstall' = 'unmanage') {
    return this.http.post<RoleDeploymentDetail>(`${this.base}/role-deployments/${deploymentId}/retire`, {
      behavior,
    });
  }

  removeRoleTarget(deploymentId: string, targetId: string, behavior: 'unmanage' | 'uninstall') {
    return this.http.post<{ ok: boolean; behavior: string }>(
      `${this.base}/role-deployments/${deploymentId}/targets/${targetId}/remove`, { behavior },
    );
  }

  /** Save a runbook (Ansible task YAML) to the library — the wizard's "Save as template" (folder
   * "templates"). 409 if the name is taken. */
  saveRunbook(playbook: string, folder = 'templates') {
    return this.http.post<{ id: string; name: string }>(`${this.base}/runbooks`, { playbook, folder });
  }
}
