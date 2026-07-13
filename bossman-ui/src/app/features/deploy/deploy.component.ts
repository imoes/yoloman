import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { environment } from '../../../environments/environment';
import { AgentService } from '../../core/services/agent.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { PlanService, StoredPlan } from '../../core/services/plan.service';
import { DeploymentRun, DeploymentService } from '../../core/services/deployment.service';
import { Agent } from '../../core/models/agent.model';
import { HostGroup } from '../../core/models/host-group.model';

interface ParamRow { key: string; value: string; }
interface RunbookRef { id: string; name: string; kind: string; }

/**
 * The guided deployment lifecycle (AWX job-template analogue): pick a stored
 * plan or a runbook, pick targets (enrolled hosts, host groups, or a pasted
 * free-text hostname list), fill parameters, dry-run, then apply — all fanned
 * out server-side into one tracked DeploymentRun (see api/deployments.py).
 */
@Component({
  selector: 'app-deploy',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatButtonModule, MatIconModule, MatFormFieldModule,
    MatInputModule, MatSelectModule, MatCheckboxModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-page">
      <h1>Deploy</h1>
      <p class="bm-dim">Run a plan or runbook across many hosts in one action. Passwords in host
        variables stay encrypted; a dry-run previews every host before you apply.</p>

      <mat-card>
        <mat-card-header><mat-card-title>1 · What to run</mat-card-title></mat-card-header>
        <mat-card-content>
          <div class="bm-kind">
            <label><input type="radio" name="kind" value="stored_plan" [(ngModel)]="kind" /> Plan</label>
            <label><input type="radio" name="kind" value="runbook" [(ngModel)]="kind" /> Runbook</label>
          </div>
          @if (kind() === 'stored_plan') {
            <mat-form-field appearance="outline" class="bm-wide">
              <mat-label>Plan</mat-label>
              <mat-select [(ngModel)]="selectedPlan">
                @for (p of plans(); track p.prefix + '/' + p.name) {
                  <mat-option [value]="p.prefix + '/' + p.name">{{ p.folder ? p.folder + '/' : '' }}{{ p.name }} <span class="bm-badge">{{ p.prefix }}</span></mat-option>
                }
              </mat-select>
            </mat-form-field>
          } @else {
            <mat-form-field appearance="outline" class="bm-wide">
              <mat-label>Runbook</mat-label>
              <mat-select [(ngModel)]="selectedRunbook">
                @for (r of runbooks(); track r.id) {
                  <mat-option [value]="r.id" [disabled]="r.kind === 'role'">{{ r.name }}@if (r.kind === 'role') { <span class="bm-badge">role — bind in OU/Policy</span> }</mat-option>
                }
              </mat-select>
            </mat-form-field>
          }
        </mat-card-content>
      </mat-card>

      <mat-card>
        <mat-card-header><mat-card-title>2 · Targets <span class="bm-dim">({{ targetCount() }} selected)</span></mat-card-title></mat-card-header>
        <mat-card-content>
          <div class="bm-targets">
            <div class="bm-col">
              <strong>Hosts</strong>
              <div class="bm-checklist">
                @for (a of agents(); track a.id) {
                  <label><mat-checkbox [checked]="selectedAgents().has(a.id)" (change)="toggleAgent(a.id)"></mat-checkbox> {{ a.name }}@if (!a.address) { <span class="bm-dim"> (no address)</span> }</label>
                }
                @if (!agents().length) { <span class="bm-dim">No enrolled hosts.</span> }
              </div>
            </div>
            <div class="bm-col">
              <strong>Host groups</strong>
              <div class="bm-checklist">
                @for (g of groups(); track g.id) {
                  <label><mat-checkbox [checked]="selectedGroups().has(g.id)" (change)="toggleGroup(g.id)"></mat-checkbox> {{ g.name }}</label>
                }
                @if (!groups().length) { <span class="bm-dim">No host groups.</span> }
              </div>
            </div>
          </div>
        </mat-card-content>
      </mat-card>

      <mat-card>
        <mat-card-header><mat-card-title>3 · Parameters</mat-card-title></mat-card-header>
        <mat-card-content>
          @for (row of paramRows(); track $index) {
            <div class="bm-prow">
              <mat-form-field appearance="outline"><mat-label>name</mat-label><input matInput [ngModel]="row.key" (ngModelChange)="setParamKey($index, $event)" /></mat-form-field>
              <mat-form-field appearance="outline"><mat-label>value</mat-label><input matInput [ngModel]="row.value" (ngModelChange)="setParamVal($index, $event)" /></mat-form-field>
              <button mat-icon-button (click)="removeParam($index)"><mat-icon>close</mat-icon></button>
            </div>
          }
          <button mat-stroked-button (click)="addParam()"><mat-icon>add</mat-icon> Add parameter</button>
        </mat-card-content>
      </mat-card>

      <div class="bm-actions">
        <button mat-raised-button color="primary" (click)="run(true)" [disabled]="!canRun() || running()">
          @if (running()) { <mat-spinner diameter="18"></mat-spinner> } @else { <mat-icon>visibility</mat-icon> } Dry-run
        </button>
        @if (result() && result()!.dry_run && result()!.status !== 'failed') {
          <button mat-raised-button color="warn" (click)="run(false)" [disabled]="running()"><mat-icon>rocket_launch</mat-icon> Apply for real</button>
        }
        @if (error()) { <span class="bm-err">{{ error() }}</span> }
      </div>

      @if (result(); as r) {
        <mat-card class="bm-result" [class.bm-ok]="r.status === 'ok'" [class.bm-partial]="r.status === 'partial'" [class.bm-fail]="r.status === 'failed'">
          <mat-card-header>
            <mat-card-title>{{ r.dry_run ? 'Dry-run' : 'Deployment' }} — {{ r.status }}</mat-card-title>
            <mat-card-subtitle>{{ r.target_ref }} · {{ r.ok_hosts }}/{{ r.total_hosts }} ok@if (r.failed_hosts) { , {{ r.failed_hosts }} failed }</mat-card-subtitle>
          </mat-card-header>
          <mat-card-content>
            @if (r.unknown_hostnames.length) {
              <p class="bm-err">Unknown hosts (not run): {{ r.unknown_hostnames.join(', ') }}</p>
            }
            <table class="bm-hosts">
              <tr><th>Host</th><th>Status</th><th>Changed</th><th>Detail</th></tr>
              @for (h of r.results || []; track h.agent_id) {
                <tr>
                  <td>{{ h.agent_name }}</td>
                  <td><span class="bm-pill" [class.bm-pill-ok]="h.status === 'succeeded' || h.status === 'ok'" [class.bm-pill-fail]="h.status !== 'succeeded' && h.status !== 'ok'">{{ h.status }}</span></td>
                  <td>{{ h.changed === undefined ? '—' : (h.changed ? 'yes' : 'no') }}</td>
                  <td class="bm-dim">{{ h.error || h.run_kind || '' }}</td>
                </tr>
              }
            </table>
          </mat-card-content>
        </mat-card>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1000px; margin: 0 auto; display: flex; flex-direction: column; gap: 16px; }
    .bm-dim { opacity: 0.7; font-weight: 400; }
    .bm-err { color: var(--bm-red); }
    .bm-wide { width: 100%; max-width: 480px; }
    .bm-badge { font-size: 10.5px; padding: 0 6px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); margin-left: 6px; }
    .bm-kind { display: flex; gap: 10px; margin-bottom: 14px; }
    .bm-kind label { display: flex; align-items: center; gap: 8px; cursor: pointer; padding: 8px 16px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; font-weight: 500; }
    .bm-kind label:has(input:checked) { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-targets { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
    @media (max-width: 720px) { .bm-targets { grid-template-columns: 1fr; } }
    .bm-col { display: flex; flex-direction: column; gap: 8px; }
    .bm-col > strong { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.65; }
    .bm-checklist { display: flex; flex-direction: column; gap: 1px; max-height: 240px; overflow: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 6px; }
    .bm-checklist label { display: flex; align-items: center; gap: 8px; font-size: 13px; padding: 5px 8px; border-radius: 6px; }
    .bm-checklist label:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
    .bm-prow { display: flex; gap: 8px; align-items: center; }
    .bm-prow mat-form-field { flex: 1; }
    .bm-actions { display: flex; align-items: center; gap: 12px; }
    .bm-result.bm-ok { border-left: 4px solid #2e7d32; }
    .bm-result.bm-partial { border-left: 4px solid #f9a825; }
    .bm-result.bm-fail { border-left: 4px solid var(--bm-red); }
    .bm-hosts { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .bm-hosts th { text-align: left; font-size: 12px; opacity: 0.7; padding: 6px 8px; }
    .bm-hosts td { padding: 6px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
    .bm-pill { font-size: 11px; padding: 1px 8px; border-radius: 999px; }
    .bm-pill-ok { background: color-mix(in srgb, #2e7d32 25%, transparent); }
    .bm-pill-fail { background: color-mix(in srgb, var(--bm-red) 25%, transparent); }
  `],
})
export class DeployComponent implements OnInit {
  private http = inject(HttpClient);
  private agentService = inject(AgentService);
  private groupService = inject(HostGroupService);
  private planService = inject(PlanService);
  private deployService = inject(DeploymentService);

  kind = signal<'stored_plan' | 'runbook'>('stored_plan');
  plans = signal<StoredPlan[]>([]);
  runbooks = signal<RunbookRef[]>([]);
  agents = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);

  selectedPlan = signal<string | null>(null);       // "prefix/name"
  selectedRunbook = signal<string | null>(null);     // runbook id
  selectedAgents = signal<Set<string>>(new Set());
  selectedGroups = signal<Set<string>>(new Set());
  paramRows = signal<ParamRow[]>([]);

  running = signal(false);
  result = signal<DeploymentRun | null>(null);
  error = signal<string | null>(null);

  targetCount = computed(() => this.selectedAgents().size + this.selectedGroups().size);

  canRun = computed(() => {
    const hasArtifact = this.kind() === 'stored_plan' ? !!this.selectedPlan() : !!this.selectedRunbook();
    return hasArtifact && this.targetCount() > 0;
  });

  ngOnInit(): void {
    this.planService.library().subscribe((r) => this.plans.set(r.plans ?? []));
    this.agentService.list().subscribe((a) => this.agents.set(a ?? []));
    this.groupService.list().subscribe((g) => this.groups.set(g ?? []));
    this.http.get<{ runbooks: RunbookRef[] }>(`${environment.apiUrl}/runbooks`)
      .subscribe((r) => this.runbooks.set(r.runbooks ?? []));
  }

  toggleAgent(id: string): void { this.selectedAgents.update((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); }
  toggleGroup(id: string): void { this.selectedGroups.update((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; }); }
  addParam(): void { this.paramRows.update((r) => [...r, { key: '', value: '' }]); }
  removeParam(i: number): void { this.paramRows.update((r) => r.filter((_, idx) => idx !== i)); }
  setParamKey(i: number, v: string): void { this.paramRows.update((r) => r.map((row, idx) => (idx === i ? { ...row, key: v } : row))); }
  setParamVal(i: number, v: string): void { this.paramRows.update((r) => r.map((row, idx) => (idx === i ? { ...row, value: v } : row))); }

  private coerce(v: string): unknown {
    if (v === 'true' || v === 'false') return v === 'true';
    if (/^-?\d+$/.test(v)) return parseInt(v, 10);
    return v;
  }

  run(dryRun: boolean): void {
    if (!this.canRun()) return;
    this.running.set(true);
    this.error.set(null);
    const params: Record<string, unknown> = {};
    for (const { key, value } of this.paramRows()) { const k = key.trim(); if (k) params[k] = this.coerce(value); }
    const targets = {
      agent_ids: [...this.selectedAgents()],
      group_ids: [...this.selectedGroups()],
    };

    const post = (extra: Record<string, unknown>) => {
      this.deployService.run({ kind: this.kind(), params, dry_run: dryRun, targets, ...extra } as never).subscribe({
        next: (r) => { this.running.set(false); this.result.set(r); },
        error: (e) => { this.running.set(false); this.error.set(e?.error?.detail ?? 'deployment failed'); },
      });
    };

    if (this.kind() === 'stored_plan') {
      const [prefix, ...rest] = this.selectedPlan()!.split('/');
      post({ prefix, name: rest.join('/') });
    } else {
      const rbId = this.selectedRunbook()!;
      const rb = this.runbooks().find((r) => r.id === rbId);
      // The runbook is sent as its NestedText source (like the single-host run).
      this.http.get<{ nt: string; name: string }>(`${environment.apiUrl}/runbooks/${rbId}`).subscribe({
        next: (doc) => post({ runbook_nt: doc.nt, runbook_name: rb?.name ?? doc.name }),
        error: (e) => { this.running.set(false); this.error.set(e?.error?.detail ?? 'could not load runbook'); },
      });
    }
  }
}
