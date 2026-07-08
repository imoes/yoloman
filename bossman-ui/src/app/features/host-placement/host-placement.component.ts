import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatSelectModule } from '@angular/material/select';
import { FormsModule } from '@angular/forms';
import { Agent } from '../../core/models/agent.model';
import { OUNode } from '../../core/models/ou.model';
import { CompiledHostState } from '../../core/models/orchestration.model';
import { AgentService } from '../../core/services/agent.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { OuService } from '../../core/services/ou.service';

interface Row {
  kind: 'ou' | 'host' | 'unassigned';
  depth: number;
  ou?: OUNode;
  host?: Agent;
}

/**
 * Host → OU placement tree (Block L3d) — the separate view the user asked
 * for: sort servers (agents) into OUs so it's visible which rules apply to
 * which host. Left: the OU tree with hosts nested under their OU (plus an
 * "Unassigned" bucket); each host row has an OU picker to move it. Right:
 * the selected host's compiled desired state — the effective checks/roles
 * that OU placement + inheritance produce (GET /agents/{id}/desired-state).
 */
@Component({
  selector: 'app-host-placement',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, MatFormFieldModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <h1>Host placement</h1>
      <p class="bm-sub">Sort servers into OUs — a host inherits every rule on its OU path. Select a host to see the effective rules.</p>

      <div class="bm-split">
        <div class="bm-tree">
          @for (row of rows(); track rowKey(row)) {
            @if (row.kind === 'ou' || row.kind === 'unassigned') {
              <div class="bm-node bm-ou" [style.paddingLeft.px]="8 + row.depth * 18">
                <mat-icon class="bm-ou-icon">{{ row.kind === 'unassigned' ? 'help_outline' : 'folder' }}</mat-icon>
                <span class="bm-label">{{ row.kind === 'unassigned' ? 'Unassigned' : row.ou!.name }}</span>
              </div>
            } @else {
              <div class="bm-node bm-host" [class.bm-selected]="selectedHost()?.id === row.host!.id"
                   [style.paddingLeft.px]="8 + row.depth * 18" (click)="selectHost(row.host!)">
                <mat-icon class="bm-host-icon">dns</mat-icon>
                <span class="bm-label">{{ row.host!.name }}</span>
                <mat-form-field appearance="outline" class="bm-move" (click)="$event.stopPropagation()">
                  <mat-select [ngModel]="row.host!.ou_id ?? null" (ngModelChange)="moveHost(row.host!, $event)">
                    <mat-option [value]="null">(unassigned)</mat-option>
                    @for (n of ous(); track n.id) {
                      <mat-option [value]="n.id">{{ n.path }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
              </div>
            }
          }
          @if (!hosts().length) {
            <p class="bm-empty">No hosts enrolled yet.</p>
          }
        </div>

        <div class="bm-detail">
          @if (selectedHost(); as h) {
            <h2>{{ h.name }}</h2>
            @if (desired(); as d) {
              <table class="bm-kv">
                <tr><th>OU</th><td>{{ d.state.host.ou ?? '(unassigned)' }}</td></tr>
                <tr><th>Generation</th><td>{{ d.generation }}</td></tr>
              </table>
              <h3>Effective checks</h3>
              @if (d.state.monitoring.checks.length) {
                <ul class="bm-list">
                  @for (c of d.state.monitoring.checks; track c) { <li>{{ c }}</li> }
                </ul>
              } @else { <p class="bm-empty">No checks from OU rules yet.</p> }
              <h3>Roles</h3>
              @if (d.state.orchestration.roles.length) {
                <ul class="bm-list">
                  @for (r of d.state.orchestration.roles; track r) { <li>{{ r }}</li> }
                </ul>
              } @else { <p class="bm-empty">No orchestration roles.</p> }
            } @else {
              <p class="bm-empty">Loading desired state…</p>
            }
          } @else {
            <p class="bm-empty">Select a host to see which rules apply.</p>
          }
        </div>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
      .bm-sub { opacity: 0.7; margin-top: -8px; }
      .bm-split { display: flex; gap: 16px; align-items: flex-start; margin-top: 12px; }
      .bm-tree, .bm-detail {
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; min-height: 340px;
      }
      .bm-tree { flex: 1 1 58%; padding: 6px 0; overflow-x: auto; }
      .bm-detail { flex: 1 1 42%; padding: 12px 16px; }
      .bm-node { display: flex; align-items: center; gap: 6px; padding: 3px 10px; white-space: nowrap; }
      .bm-host { cursor: pointer; }
      .bm-host:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-selected { background: color-mix(in srgb, var(--bm-green) 16%, transparent); }
      .bm-ou-icon, .bm-host-icon { font-size: 18px; height: 18px; width: 18px; }
      .bm-ou-icon { opacity: 0.8; }
      .bm-host-icon { opacity: 0.65; }
      .bm-label { font-size: 13.5px; flex: 0 0 auto; }
      .bm-move { margin-left: auto; width: 220px; }
      .bm-move ::ng-deep .mat-mdc-form-field-subscript-wrapper { display: none; }
      .bm-empty { opacity: 0.7; padding: 4px 0; }
      .bm-kv { border-collapse: collapse; margin: 8px 0; }
      .bm-kv th { text-align: left; opacity: 0.7; padding: 4px 16px 4px 0; font-weight: 500; }
      .bm-list { margin: 4px 0 12px; padding-left: 18px; }
      h3 { margin: 12px 0 4px; font-size: 13px; opacity: 0.8; }
    `,
  ],
})
export class HostPlacementComponent implements OnInit {
  private ouService = inject(OuService);
  private agentService = inject(AgentService);
  private orchestration = inject(OrchestrationService);

  ous = signal<OUNode[]>([]);
  hosts = signal<Agent[]>([]);
  selectedHost = signal<Agent | null>(null);
  desired = signal<CompiledHostState | null>(null);

  rows = computed<Row[]>(() => {
    const out: Row[] = [];
    const byOu = new Map<string, Agent[]>();
    const unassigned: Agent[] = [];
    for (const h of this.hosts()) {
      if (h.ou_id) {
        const list = byOu.get(h.ou_id) ?? [];
        list.push(h);
        byOu.set(h.ou_id, list);
      } else {
        unassigned.push(h);
      }
    }
    // OUs are server-sorted by path; depth = number of '/' minus 1.
    for (const ou of this.ous()) {
      const depth = ou.path.split('/').length - 2;
      out.push({ kind: 'ou', ou, depth: Math.max(0, depth) });
      for (const h of (byOu.get(ou.id) ?? []).sort((a, b) => a.name.localeCompare(b.name))) {
        out.push({ kind: 'host', host: h, depth: Math.max(0, depth) + 1 });
      }
    }
    if (unassigned.length) {
      out.push({ kind: 'unassigned', depth: 0 });
      for (const h of unassigned.sort((a, b) => a.name.localeCompare(b.name))) {
        out.push({ kind: 'host', host: h, depth: 1 });
      }
    }
    return out;
  });

  ngOnInit(): void {
    this.ouService.list().subscribe((o) => this.ous.set(o));
    this.agentService.list().subscribe((a) => this.hosts.set(a));
  }

  rowKey(row: Row): string {
    if (row.kind === 'host') return `h:${row.host!.id}`;
    if (row.kind === 'unassigned') return 'unassigned';
    return `ou:${row.ou!.id}`;
  }

  selectHost(host: Agent): void {
    this.selectedHost.set(host);
    this.desired.set(null);
    this.orchestration.desiredState(host.id).subscribe((d) => this.desired.set(d));
  }

  moveHost(host: Agent, ouId: string | null): void {
    if ((host.ou_id ?? null) === (ouId ?? null)) return;
    this.ouService.assignAgent(host.id, ouId).subscribe(() => {
      // Reflect the move locally, then refresh the selected host's desired state.
      this.hosts.update((hs) => hs.map((h) => (h.id === host.id ? { ...h, ou_id: ouId } : h)));
      if (this.selectedHost()?.id === host.id) this.selectHost({ ...host, ou_id: ouId });
    });
  }
}
