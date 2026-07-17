import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map, switchMap, of } from 'rxjs';
import { environment } from '../../../environments/environment';
import { ParamSchema } from '../../shared/param-form/param-form.types';

export interface WizardContext {
  family: string;
  installed: Record<string, string>; // catalog pkg -> installed version
  catalog_resolved: Record<string, { packages: string[]; service: string; config_path: string }>;
}

export interface WizardRunbook {
  id: string;
  name: string;
  nt: string;
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

/** Backs the installation wizard: host context, the seeded install-<pkg>
 * runbooks (by name), and running them (dry-run preview + real apply). */
@Injectable({ providedIn: 'root' })
export class WizardService {
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  context(agentId: string) {
    return this.http.get<WizardContext>(`${this.base}/agents/${agentId}/package-wizard/context`);
  }

  /** Resolve a seeded runbook by name → its id, NT source and parameter mask. */
  runbookByName(name: string): Observable<WizardRunbook | null> {
    return this.http.get<{ runbooks: { id: string; name: string }[] }>(`${this.base}/runbooks`).pipe(
      map((r) => r.runbooks.find((x) => x.name === name)),
      switchMap((rb) => rb
        ? this.http.get<{ id: string; name: string; nt: string; parameters: ParamSchema }>(`${this.base}/runbooks/${rb.id}`)
            .pipe(map((full) => ({ id: full.id, name: full.name, nt: full.nt, parameters: full.parameters || {} })))
        : of(null)),
    );
  }

  run(agentId: string, nt: string, variables: Record<string, unknown>, dryRun: boolean) {
    // The endpoint spreads the run result at the top level (run_id, steps, ok, …).
    return this.http.post<RunbookRunResult & { run_id: string; runbook: string }>(
      `${this.base}/agents/${agentId}/runbook/run`, { nt, variables, dry_run: dryRun },
    );
  }
}
