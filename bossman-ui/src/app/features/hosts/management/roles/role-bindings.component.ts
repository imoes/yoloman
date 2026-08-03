import { Component, OnInit, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { OrchestrationService } from '../../../../core/services/orchestration.service';
import { ResourceNodeComponent } from '../../../../shared/resource-node/resource-node.component';

/** Role bindings snap-in (MMC) — the Resource-protocol view of roles on this
 * host. Each OrchestrationPlan of type `role` renders as a generic ResourceNode
 * (kind=role): observe (bound? from where? active/pending_approval), the role's
 * parameter form, Plan (blast-radius preview), Bind/Unbind, and the applied
 * parameter sets with Rollback. Complements the "Roles & Features" snap-in
 * (which installs catalog packages); this one manages orchestration-role
 * BINDINGS via the same four-verb interface every other tier uses. */
@Component({
  selector: 'app-role-bindings',
  standalone: true,
  imports: [MatIconModule, ResourceNodeComponent],
  template: `
    <div class="bm-rb-head">
      <h3>Role bindings</h3>
      <p class="bm-dim">Bind orchestration roles to this host — declare intent; the host converges (approval-gated).</p>
    </div>

    @if (loading()) { <p class="bm-dim">Loading roles…</p> }
    @if (err()) { <p class="bm-err">{{ err() }}</p> }
    @if (!loading() && !roles().length) {
      <p class="bm-dim">No roles defined yet. Author a role (Ansible task syntax under a <code>role:</code> key) and compile it via the Workflow designer / <code>POST /runbooks/role/compile</code>.</p>
    }

    <div class="bm-rb-list">
      @for (r of roles(); track r.id) {
        <app-resource-node [agentId]="agentId()" kind="role" [name]="r.name" />
      }
    </div>
  `,
  styles: [`
    .bm-rb-head h3 { margin: 0; }
    .bm-dim { opacity: 0.62; margin: 2px 0 0; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-rb-list { display: flex; flex-direction: column; gap: 14px; margin-top: 14px; }
  `],
})
export class RoleBindingsComponent implements OnInit {
  private orch = inject(OrchestrationService);
  agentId = input.required<string>();

  loading = signal(true);
  err = signal('');
  roles = signal<{ id: string; name: string }[]>([]);

  ngOnInit(): void {
    this.orch.listPlans().subscribe({
      next: (plans) => {
        this.loading.set(false);
        this.roles.set(plans.filter((p) => p.plan_type === 'role').map((p) => ({ id: p.id, name: p.name })));
      },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail || 'failed to load roles'); },
    });
  }
}
