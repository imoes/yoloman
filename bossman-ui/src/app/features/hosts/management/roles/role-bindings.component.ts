import { Component, OnInit, computed, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { OrchestrationService } from '../../../../core/services/orchestration.service';
import { AgentService } from '../../../../core/services/agent.service';
import { ResourceNodeComponent } from '../../../../shared/resource-node/resource-node.component';

/** Role bindings snap-in (MMC) — the Resource-protocol view of roles on this
 * host. Each OrchestrationPlan of type `role` renders as a generic ResourceNode
 * (kind=role): observe (bound? from where? active/pending_approval), the role's
 * parameter form, Plan (blast-radius preview), Bind/Unbind, and the applied
 * parameter sets with Rollback. Complements the "Roles & Features" snap-in
 * (which installs catalog packages); this one manages orchestration-role
 * BINDINGS via the same four-verb interface every other tier uses.
 *
 * A bound role only CONVERGES when the host's write gate is open. A freshly
 * PXE-provisioned host enrols read-only (safe default), so the write-access
 * control here lets the owner enable writes over the API (agent self-config
 * carve-out) — otherwise bindings sit as desired state that never applies. */
@Component({
  selector: 'app-role-bindings',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ResourceNodeComponent],
  template: `
    <div class="bm-rb-head">
      <h3>Role bindings</h3>
      <p class="bm-dim">Bind orchestration roles to this host — declare intent; the host converges (approval-gated).</p>
    </div>

    <!-- Write access: a bound role only converges when the gate is open. Provisioned hosts start read-only. -->
    <div class="bm-rb-write">
      <mat-icon>shield</mat-icon>
      <span>Role convergence needs the host's <strong>write gate</strong> open. A freshly provisioned host is
        read-only until you enable writes.</span>
      <span class="bm-rb-spacer"></span>
      <span class="bm-why" [attr.title]="writeBusy() ? 'Working… the agent restarts to apply the change' : null"><button mat-stroked-button [disabled]="writeBusy()" (click)="setWrite(true)">Enable writes</button></span>
      <span class="bm-why" [attr.title]="writeBusy() ? 'Working… the agent restarts to apply the change' : null"><button mat-stroked-button [disabled]="writeBusy()" (click)="setWrite(false)">Set read-only</button></span>
    </div>
    @if (writeMsg()) { <p class="bm-ok">{{ writeMsg() }}</p> }
    @if (writeErr()) { <p class="bm-err">{{ writeErr() }}</p> }

    @if (loading()) { <p class="bm-dim">Loading roles…</p> }
    @if (err()) { <p class="bm-err">{{ err() }}</p> }
    @if (!loading() && !roles().length) {
      <p class="bm-dim">No roles defined yet. Author a role (Ansible task syntax under a <code>role:</code> key) and compile it via the Workflow designer / <code>POST /runbooks/role/compile</code>.</p>
    }

    @if (roles().length) {
      <label class="bm-rb-filter">Filter roles
        <input type="search" [ngModel]="filter()" (ngModelChange)="filter.set($event)" placeholder="name contains…" />
        <span class="bm-dim">{{ shown().length }} of {{ roles().length }}</span>
      </label>
    }
    <div class="bm-rb-list">
      @for (r of shown(); track r.id) {
        <app-resource-node [agentId]="agentId()" kind="role" [name]="r.name" />
      } @empty {
        @if (roles().length) { <p class="bm-dim">No role matches “{{ filter() }}”.</p> }
      }
    </div>
  `,
  styles: [`
    .bm-rb-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-ok { color: var(--bm-green, #2e7d32); font-size: 13px; }
    .bm-rb-write { display: flex; align-items: center; gap: 10px; margin: 14px 0 4px; padding: 8px 12px;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; font-size: 13px; }
    .bm-rb-write mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.7; }
    .bm-rb-spacer { flex: 1; }
    .bm-rb-filter { display: flex; align-items: center; gap: 8px; margin-top: 12px; font-size: 13px; }
    .bm-rb-filter input { padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; min-width: 220px; }
    .bm-rb-list { display: flex; flex-direction: column; gap: 14px; margin-top: 14px; }
  `],
})
export class RoleBindingsComponent implements OnInit {
  private orch = inject(OrchestrationService);
  private agents = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(true);
  err = signal('');
  roles = signal<{ id: string; name: string }[]>([]);
  /** Narrow the list by name — a fleet has ~100 catalog roles, and each node reads its own state. */
  filter = signal('');
  shown = computed(() => {
    const q = this.filter().trim().toLowerCase();
    return q ? this.roles().filter((r) => r.name.toLowerCase().includes(q)) : this.roles();
  });

  writeBusy = signal(false);
  writeMsg = signal('');
  writeErr = signal('');

  ngOnInit(): void {
    this.orch.listPlans().subscribe({
      next: (plans) => {
        this.loading.set(false);
        this.roles.set(plans.filter((p) => p.plan_type === 'role').map((p) => ({ id: p.id, name: p.name })));
      },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail || 'failed to load roles'); },
    });
  }

  /** Open or close the agent's master write gate via its self-config carve-out (config.yaml + restart).
   *  With writes enabled, approved role bindings converge on the next reconcile. */
  setWrite(enabled: boolean): void {
    this.writeBusy.set(true); this.writeMsg.set(''); this.writeErr.set('');
    this.agents.setAgentConfig(this.agentId(), { write: enabled }).subscribe({
      next: () => { this.writeBusy.set(false); this.writeMsg.set(enabled
        ? 'Writes enabled — the agent is restarting; approved roles will converge on the next reconcile.'
        : 'Host set back to read-only — the agent is restarting.'); },
      error: (e) => { this.writeBusy.set(false); this.writeErr.set(e?.error?.detail || 'Could not change write access.'); },
    });
  }
}
