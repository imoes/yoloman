import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../core/services/agent.service';
import {
  CloneResult, ProposedSystem, PromoteResult, RehearsalResult,
  SystemsService, SystemSummary, SystemMember,
} from '../../core/services/systems.service';
import { ResourceNodeComponent } from '../../shared/resource-node/resource-node.component';
import { kindForTarget } from '../../shared/resource-node/resource-node-registry';
import { ChatPlanGraphComponent, PlanGraphData } from '../chat/chat-plan-graph.component';

/**
 * Systems — the unit above a host (apps + wiring) and the rehearsal plane
 * (clone-a-prod-system): propose a System from a host's live state, persist it,
 * then clone it into a disposable sandbox, rehearse a change (behavioral test),
 * and promote to prod atomically only on a green rehearsal. The same loop the AI
 * drives via MCP (docs/test-systems.md).
 */
@Component({
  selector: 'app-systems',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ResourceNodeComponent, ChatPlanGraphComponent],
  template: `
    <div class="bm-page">
      <header class="bm-page-head">
        <h1>Systems</h1>
        <span class="bm-dim">clone-a-prod-system · rehearse a change · promote only when green</span>
      </header>

      <!-- Propose from a host -->
      <section class="bm-sys-propose">
        <div class="bm-row">
          <span class="bm-lbl">Propose from</span>
          <select class="bm-in" [(ngModel)]="proposeHost">
            <option value="">— host —</option>
            @for (a of agents(); track a.id) { <option [value]="a.id">{{ a.name }}</option> }
          </select>
          <input class="bm-in" [(ngModel)]="proposeName" placeholder="system name (optional)" />
          <button mat-stroked-button (click)="propose()" [disabled]="!proposeHost() || busy()">Propose</button>
          @if (proposed(); as p) {
            <button mat-raised-button color="primary" (click)="createProposed()" [disabled]="busy()">
              <mat-icon>save</mat-icon> Create ({{ p.member_count }} members)
            </button>
          }
        </div>
        @if (proposed(); as p) {
          <div class="bm-proposed">
            proposed <strong>{{ p.name }}</strong>:
            @for (m of p.members; track m.app) { <span class="bm-chip">{{ m.target }}/{{ m.app }}</span> }
            @if (!p.members.length) { <span class="bm-dim">no members discovered on this host</span> }
          </div>
        }
      </section>

      <div class="bm-sys-body">
        <!-- persisted systems -->
        <aside class="bm-sys-list">
          <div class="bm-sys-lhead">Systems <span class="bm-dim">· {{ systems().length }}</span></div>
          @for (s of systems(); track s.id) {
            <button class="bm-sys-item" [class.sel]="selected()?.id === s.id" (click)="select(s)">
              <span>{{ s.name }}</span><span class="bm-dim">{{ s.member_count }}</span>
            </button>
          }
          @if (!systems().length) { <p class="bm-dim">No systems yet — propose one above.</p> }
        </aside>

        <!-- selected system + rehearsal plane -->
        <section class="bm-sys-detail">
          @if (selected(); as s) {
            <div class="bm-sys-dhead">
              <h2>{{ s.name }}</h2>
              <button mat-button color="warn" (click)="remove(s)" [disabled]="busy()">Delete</button>
            </div>

            <table class="bm-table">
              <thead><tr><th>Target</th><th>App</th><th>Role</th><th>New image (change to rehearse)</th></tr></thead>
              <tbody>
                @for (m of s.members || []; track m.id) {
                  <tr>
                    <td><span class="bm-tier">{{ m.target }}</span></td>
                    <td>{{ m.app }}</td>
                    <td class="bm-dim">{{ m.role_in_system }}</td>
                    <td>
                      @if (m.target === 'docker') {
                        <input class="bm-in bm-ov" [ngModel]="overrides()[m.app] || ''"
                               (ngModelChange)="setOverride(m.app, $event)"
                               placeholder="e.g. {{ imageOf(m) }}:newtag" />
                      } @else { <span class="bm-dim">—</span> }
                    </td>
                  </tr>
                }
              </tbody>
            </table>

            <!-- Resource canvas: the System as a graph of live Resource nodes -->
            <div class="bm-sys-canvas-head">
              <button mat-button (click)="showCanvas.set(!showCanvas())">
                <mat-icon>{{ showCanvas() ? 'expand_less' : 'expand_more' }}</mat-icon>
                Resource canvas ({{ liveMembers(s).length }})
              </button>
            </div>
            @if (showCanvas()) {
              @if (graph(s); as g) {
                @if (g.nodes.length) { <div class="bm-sys-graph"><app-chat-plan-graph [data]="g" /></div> }
              }
              <div class="bm-sys-nodes">
                @for (m of liveMembers(s); track m.app) {
                  <app-resource-node [agentId]="s.seed_agent_id || ''" [kind]="kindOf(m)"
                                     [name]="m.app" [namespace]="nsOf(m)" />
                }
                @if (!liveMembers(s).length) { <p class="bm-dim">No docker/helm members to manage yet.</p> }
              </div>
            }

            <div class="bm-row bm-sys-actions">
              <span class="bm-lbl">Target host</span>
              <select class="bm-in" [(ngModel)]="targetHost">
                <option value="">— host —</option>
                @for (a of agents(); track a.id) { <option [value]="a.id">{{ a.name }}</option> }
              </select>
              <button mat-stroked-button (click)="clone()" [disabled]="!targetHost() || busy()">
                <mat-icon>content_copy</mat-icon> Clone (dry-run)
              </button>
              <button mat-stroked-button (click)="rehearse()" [disabled]="!targetHost() || busy()">
                <mat-icon>science</mat-icon> Rehearse
              </button>
              <button mat-raised-button color="primary" (click)="promote()"
                      [disabled]="!targetHost() || !hasOverrides() || busy()">
                <mat-icon>rocket_launch</mat-icon> Promote
              </button>
            </div>
            @if (busy()) { <p class="bm-dim">{{ busyMsg() }}…</p> }
            @if (err()) { <p class="bm-err">{{ err() }}</p> }

            @if (rehearsal(); as r) {
              <div class="bm-result" [class.ok]="r.passed" [class.bad]="!r.passed">
                <strong>Rehearsal: {{ r.passed ? 'PASSED ✓' : 'FAILED ✗' }}</strong>
                @for (c of r.checks; track $index) {
                  <div class="bm-check">
                    {{ c.container || c.member }} — {{ c.error ? ('error: ' + c.error) : ((c.running ? 'running' : 'not running') + (c.health ? (' · ' + c.health) : '')) }}
                  </div>
                }
              </div>
            }
            @if (promotion(); as p) {
              <div class="bm-result" [class.ok]="p.promoted" [class.bad]="!p.promoted">
                <strong>Promote: {{ p.promoted ? ('DONE ✓ (' + p.applied_count + ')') : ('NOT PROMOTED — ' + p.reason) }}</strong>
                @for (c of p.change_set || []; track $index) {
                  <div class="bm-check">{{ c.member }}: {{ c.from_image }} → {{ c.to_image }} {{ c.ok ? '✓' : (c.error || '') }}</div>
                }
                @if (p.rolled_back?.length) { <div class="bm-check">rolled back: {{ p.rolled_back!.join(', ') }}</div> }
              </div>
            }
            @if (cloneResult(); as c) {
              <div class="bm-result">
                <strong>Clone preview</strong> — sandbox <code>{{ c.sandbox_prefix }}</code>,
                {{ c.source_resource_count }} resources, {{ c.secret_count || 0 }} fresh secrets,
                config Δ {{ c.materialize?.changed_count }}
                @for (d of c.materialize?.docker || []; track $index) { <div class="bm-check bm-mono">{{ d.command }}</div> }
              </div>
            }
          } @else {
            <p class="bm-dim">Select a system, or propose one from a host.</p>
          }
        </section>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1200px; }
    .bm-page-head { display: flex; align-items: baseline; gap: 12px; margin-bottom: 16px; }
    .bm-page-head h1 { margin: 0; font-size: 22px; }
    .bm-dim { opacity: 0.6; font-size: 12.5px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    .bm-lbl { font-size: 12px; opacity: 0.7; }
    .bm-in { padding: 7px 10px; border-radius: 8px; font: inherit; font-size: 13px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-ov { width: 100%; box-sizing: border-box; }
    .bm-sys-propose { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 14px 16px; margin-bottom: 18px; }
    .bm-proposed { margin-top: 10px; display: flex; gap: 6px; flex-wrap: wrap; align-items: center; }
    .bm-chip, .bm-tier { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-sys-body { display: grid; grid-template-columns: 240px 1fr; gap: 18px; }
    .bm-sys-list { display: flex; flex-direction: column; gap: 4px; }
    .bm-sys-lhead { font-weight: 600; margin-bottom: 6px; }
    .bm-sys-item { display: flex; justify-content: space-between; padding: 8px 10px; border-radius: 8px; cursor: pointer;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; }
    .bm-sys-item.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-sys-dhead { display: flex; align-items: center; justify-content: space-between; }
    .bm-sys-dhead h2 { margin: 0; font-size: 17px; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; margin: 8px 0 14px; }
    .bm-table th, .bm-table td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-sys-actions { margin-bottom: 8px; }
    .bm-result { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 14px; margin-top: 10px; font-size: 13px; }
    .bm-result.ok { border-color: #1e9600; background: rgba(30,150,0,0.08); }
    .bm-result.bad { border-color: var(--mat-sys-error, #c62828); background: rgba(198,40,40,0.07); }
    .bm-check { font-size: 12px; opacity: 0.85; margin-top: 3px; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 11px; overflow-x: auto; }
    .bm-sys-canvas-head { margin: 6px 0; }
    .bm-sys-graph { margin: 6px 0 12px; }
    .bm-sys-nodes { display: flex; flex-direction: column; gap: 12px; margin-bottom: 14px; }
  `],
})
export class SystemsComponent {
  private svc = inject(SystemsService);
  private agentSvc = inject(AgentService);

  agents = signal<{ id: string; name: string }[]>([]);
  systems = signal<SystemSummary[]>([]);
  selected = signal<SystemSummary | null>(null);

  proposeHost = signal('');
  proposeName = signal('');
  proposed = signal<ProposedSystem | null>(null);

  targetHost = signal('');
  overrides = signal<Record<string, string>>({});
  showCanvas = signal(false);

  // Resource canvas: members that map to a live Resource node (docker/helm).
  liveMembers(s: SystemSummary): SystemMember[] {
    return (s.members || []).filter((m) => !!kindForTarget(m.target));
  }
  kindOf(m: SystemMember): string { return kindForTarget(m.target) || 'docker'; }
  nsOf(m: SystemMember): string { return (m.config?.['namespace'] as string) || 'default'; }
  // Overview graph: member nodes (synthetic id = target/app, matching discovery
  // edge ids) + the System's dependency edges.
  graph(s: SystemSummary): PlanGraphData {
    return {
      nodes: (s.members || []).map((m) => ({ id: `${m.target}/${m.app}`, label: `${m.target}\n${m.app}` })),
      edges: ((s.edges as { from: string; to: string }[]) || []).map((e) => ({ from: e.from, to: e.to })),
    };
  }

  busy = signal(false);
  busyMsg = signal('');
  err = signal('');
  cloneResult = signal<CloneResult | null>(null);
  rehearsal = signal<RehearsalResult | null>(null);
  promotion = signal<PromoteResult | null>(null);

  hasOverrides = computed(() => Object.values(this.overrides()).some((v) => !!v?.trim()));

  constructor() {
    this.agentSvc.list().subscribe({ next: (a) => this.agents.set(a.map((x) => ({ id: x.id, name: x.name }))), error: () => {} });
    this.reload();
  }

  reload(): void {
    this.svc.list().subscribe({ next: (r) => this.systems.set(r.systems || []), error: () => {} });
  }

  imageOf(m: { image?: string; config?: Record<string, unknown> }): string {
    return m.image || (m.config?.['image'] as string) || 'image';
  }
  setOverride(app: string, val: string): void { this.overrides.update((o) => ({ ...o, [app]: val })); }
  private cleanOverrides(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(this.overrides())) if (v?.trim()) out[k] = v.trim();
    return out;
  }
  private clearResults(): void { this.cloneResult.set(null); this.rehearsal.set(null); this.promotion.set(null); this.err.set(''); }

  propose(): void {
    this.busy.set(true); this.busyMsg.set('Proposing'); this.proposed.set(null); this.err.set('');
    this.svc.propose(this.proposeHost(), this.proposeName()).subscribe({
      next: (p) => { this.busy.set(false); this.proposed.set(p); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'propose failed'); },
    });
  }
  createProposed(): void {
    const p = this.proposed(); if (!p) return;
    this.busy.set(true); this.busyMsg.set('Creating');
    this.svc.create({ name: p.name, seed_agent_id: p.seed.id, members: p.members, edges: p.edges }).subscribe({
      next: () => { this.busy.set(false); this.proposed.set(null); this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'create failed'); },
    });
  }
  select(s: SystemSummary): void {
    this.clearResults(); this.overrides.set({}); this.showCanvas.set(false);
    this.svc.get(s.id).subscribe({ next: (full) => this.selected.set(full), error: () => this.selected.set(s) });
  }
  remove(s: SystemSummary): void {
    this.busy.set(true); this.busyMsg.set('Deleting');
    this.svc.remove(s.id).subscribe({ next: () => { this.busy.set(false); this.selected.set(null); this.reload(); }, error: () => this.busy.set(false) });
  }

  clone(): void {
    const s = this.selected(); if (!s) return;
    this.busy.set(true); this.busyMsg.set('Cloning (dry-run)'); this.clearResults();
    this.svc.clone(s.id, { target_agent_id: this.targetHost(), dry_run: true }).subscribe({
      next: (r) => { this.busy.set(false); this.cloneResult.set(r); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'clone failed'); },
    });
  }
  rehearse(): void {
    const s = this.selected(); if (!s) return;
    this.busy.set(true); this.busyMsg.set('Rehearsing'); this.clearResults();
    this.svc.rehearse(s.id, { target_agent_id: this.targetHost(), image_overrides: this.cleanOverrides() }).subscribe({
      next: (r) => { this.busy.set(false); this.rehearsal.set(r); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'rehearse failed'); },
    });
  }
  promote(): void {
    const s = this.selected(); if (!s) return;
    this.busy.set(true); this.busyMsg.set('Promoting'); this.clearResults();
    this.svc.promote(s.id, { target_agent_id: this.targetHost(), image_overrides: this.cleanOverrides(), rehearse_first: true }).subscribe({
      next: (r) => { this.busy.set(false); this.promotion.set(r); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'promote failed'); },
    });
  }
}
