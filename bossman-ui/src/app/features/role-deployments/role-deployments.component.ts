import { Component, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { MatIconModule } from '@angular/material/icon';
import { forkJoin, switchMap } from 'rxjs';
import { Agent } from '../../core/models/agent.model';
import { HostGroup } from '../../core/models/host-group.model';
import { OUNode } from '../../core/models/ou.model';
import { OrchestrationPlanVersion } from '../../core/models/orchestration.model';
import { Site } from '../../core/models/site.model';
import { AuthService } from '../../core/auth/auth.service';
import { AgentService } from '../../core/services/agent.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { OuService } from '../../core/services/ou.service';
import { SiteService } from '../../core/services/site.service';
import {
  RoleArtifact,
  RoleDeploymentDetail,
  RoleDeploymentPreview,
  RoleDeploymentRequest,
  WizardService,
} from '../../core/services/wizard.service';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { VersionDiffComponent } from '../../shared/version-diff/version-diff.component';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';

const PREVIEW_CURRENT = 'Preview is current.';
type ScopeType = 'host' | 'group' | 'ou' | 'site' | 'global';
const SCOPE_NOUN: Record<ScopeType, string> = { host: 'host', group: 'host group', ou: 'OU', site: 'site', global: 'all hosts' };
const SCOPE_TITLE: Record<ScopeType, string> = { host: 'Host', group: 'Host group', ou: 'OU', site: 'Site', global: 'All hosts' };

/** Central SCCM-like workspace for durable role and feature deployments. */
@Component({
  selector: 'app-role-deployments',
  standalone: true,
  imports: [BlockedReasonDirective, FormsModule, MatButtonModule, MatCardModule, MatIconModule, ParamFormComponent, VersionDiffComponent],
  template: `
    <div class="rd-page">
      <header>
        <div>
          <h1>Role deployments</h1>
          <p>Deploy versioned roles and features as desired state, then track compliance per host.</p>
        </div>
        <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
      </header>

      @if (message()) { <div class="rd-msg" [class.error]="messageError()">{{ message() }}</div> }

      <mat-card class="rd-create">
        <mat-card-header><mat-card-title>New deployment</mat-card-title></mat-card-header>
        <mat-card-content>
          <div class="rd-form">
            <label>Name<input [(ngModel)]="deploymentName" placeholder="Web role — Production" /></label>
            <label>Role or feature
              <select [(ngModel)]="selectedArtifactId" (ngModelChange)="artifactChanged()">
                <option value="">Select…</option>
                @for (artifact of artifacts(); track artifact.id) {
                  <option [value]="artifact.id">{{ artifactLabel(artifact) }}</option>
                }
              </select>
            </label>
            <label>Target type
              <select [(ngModel)]="scopeType" (ngModelChange)="scopeId = ''; invalidatePreview()">
                <option value="host">Host</option>
                <option value="group">Host group</option>
                <option value="ou">OU (with sub-OUs)</option>
                <option value="site">Site (by subnet)</option>
                <option value="global">All hosts</option>
              </select>
            </label>
            @if (scopeType !== 'global') {
              <label>{{ scopeTitle(scopeType) }}
                <select [(ngModel)]="scopeId" (ngModelChange)="invalidatePreview()" [attr.aria-label]="scopeTitle(scopeType)">
                  <option value="">Select…</option>
                  @for (option of scopeOptions(); track option.id) { <option [value]="option.id">{{ option.label }}</option> }
                </select>
              </label>
            }
            @if (selectedArtifact(); as artifact) {
              <details class="wide rd-versions" (toggle)="versionsToggled($event, artifact.id)">
                <summary>Version history · {{ artifact.display_name }} (current v{{ artifact.current_version }})</summary>
                @if (versions().length) {
                  <ul class="rd-version-list">
                    @for (v of versions(); track v.version) {
                      <li><strong>v{{ v.version }}</strong> <span>{{ v.created_at.slice(0, 19).replace('T', ' ') }}</span>
                        @if (v.version === artifact.current_version) { <em>current</em> }</li>
                    }
                  </ul>
                  @if (versions().length > 1) {
                    <div class="rd-compare">
                      <label>Compare
                        <select [(ngModel)]="diffFrom" (ngModelChange)="diffChanged()" aria-label="Older version">
                          @for (v of versions(); track v.version) { <option [ngValue]="v.version">v{{ v.version }}</option> }
                        </select>
                      </label>
                      <label>with
                        <select [(ngModel)]="diffTo" (ngModelChange)="diffChanged()" aria-label="Newer version">
                          @for (v of versions(); track v.version) { <option [ngValue]="v.version">v{{ v.version }}</option> }
                        </select>
                      </label>
                    </div>
                    @if (diffTexts(); as d) {
                      <app-version-diff class="rd-diff" [original]="d.original" [modified]="d.modified"
                        [originalLabel]="'v' + diffFrom" [modifiedLabel]="'v' + diffTo" height="320px" />
                    }
                  } @else {
                    <small>Only one version so far — saving a changed role publishes the next one.</small>
                  }
                } @else {
                  <small>Loading versions…</small>
                }
              </details>
            }
            @for (artifact of selectedArtifactList(); track artifact.id) {
              <div class="wide rd-parameters">
                <strong>Parameters</strong>
                @if (hasParameters(artifact)) {
                  <app-param-form [params]="artifact.parameter_schema" [initial]="artifact.default_parameters"
                    (valuesChange)="parametersChanged($event)" />
                } @else {
                  <span>No parameters required.</span>
                }
              </div>
            }
            <span class="rd-check" [attr.title]="approvalForced() || null">
              <label><input type="checkbox" [ngModel]="requireApproval || !!approvalForced()" (ngModelChange)="requireApproval = $event"
                [disabled]="!!approvalForced()" /> Require approval by a second administrator</label>
            </span>
            <label>Pilot phase
              <select [(ngModel)]="pilotMode" (ngModelChange)="invalidatePreview()">
                <option value="auto">Automatic above 10 hosts (recommended)</option>
                <option value="on">Always for multi-host targets</option>
                <option value="off">Disabled</option>
              </select>
            </label>
          </div>

          <div class="rd-buttons">
            <span class="bm-why"><button mat-stroked-button (click)="previewDeployment()" [bmBlocked]="previewBlocked()" bmBlockedMode="tip">
              <mat-icon>visibility</mat-icon> Preview
            </button></span>
            <span class="bm-why"><button mat-flat-button color="primary" (click)="createDeployment()" [bmBlocked]="createBlocked()">
              <mat-icon>rocket_launch</mat-icon> Create deployment
            </button></span>
          </div>

          @if (preview(); as p) {
            <section class="rd-preview">
              <strong>{{ p.affected_host_count }} affected host{{ p.affected_host_count === 1 ? '' : 's' }}</strong>
              <span>{{ p.approval_required ? 'Approval required by policy (all hosts, or more than 10)'
                : requireApproval ? 'Approval requested — a second administrator must approve'
                : 'Ready to deploy — active on create' }}</span>
              <span>{{ p.pilot_enabled ? 'Pilot enabled' : 'No pilot phase' }}</span>
              @for (entry of p.applicability; track entry.plan_id) {
                <span>{{ entry.applicable_host_count }}/{{ p.affected_host_count }} applicable</span>
                @for (blocked of entry.not_applicable; track blocked.agent_id) {
                  <small class="rd-na">{{ blocked.host || blocked.agent_id }}: {{ blocked.reason }}</small>
                }
                @for (sub of entry.substituted || []; track sub.agent_id) {
                  <small class="rd-sub">{{ sub.host || sub.agent_id }} (applicable by substitution): {{ sub.reason }}</small>
                }
              }
            </section>
          }
        </mat-card-content>
      </mat-card>

      <section class="rd-list">
        <h2>Deployments</h2>
        @for (deployment of deployments(); track deployment.id) {
          <mat-card class="rd-deployment" [attr.data-deployment]="deployment.name">
            <div class="rd-dep-head">
              <div>
                <strong>{{ deployment.name }}</strong>
                <span class="rd-status" [class.pending]="deployment.status === 'pending_approval'">{{ statusLabel(deployment.status) }}</span>
                <p>{{ itemLabel(deployment) }} · {{ scopeLabel(deployment) }} · {{ complianceLabel(deployment) }}
                  · by {{ deployment.created_by || 'unknown' }}@if (deployment.approved_by && deployment.approved_by !== deployment.created_by) {, approved by {{ deployment.approved_by }}}</p>
              </div>
              <div class="rd-actions">
                @if (deployment.status === 'pending_approval') {
                  <span class="bm-why"><button mat-flat-button color="primary"
                    (click)="approve(deployment)" [bmBlocked]="approveBlocked(deployment)" bmBlockedMode="tip">Approve</button></span>
                }
                @if (deployment.status === 'retired') {
                  <span class="rd-dim">Retired — nothing is managed any more.</span>
                } @else {
                  <span class="bm-why"><button mat-stroked-button
                    (click)="reconcile(deployment)" [bmBlocked]="detectBlocked(deployment)" bmBlockedMode="tip"><mat-icon>sync</mat-icon> Detect now</button></span>
                  <span class="bm-why"><button mat-flat-button color="warn"
                    (click)="correct(deployment)" [bmBlocked]="correctBlocked(deployment)" bmBlockedMode="tip"><mat-icon>build</mat-icon> Correct drift</button></span>
                  <span class="bm-why" [attr.title]="busyId() === deployment.id ? 'Working…' : null"><button mat-stroked-button
                    (click)="retire(deployment)" [disabled]="busyId() === deployment.id">Stop managing</button></span>
                  <span class="bm-why"><button mat-stroked-button color="warn"
                    (click)="retire(deployment, true)" [bmBlocked]="uninstallBlocked(deployment)" bmBlockedMode="tip">Uninstall</button></span>
                }
              </div>
            </div>
            <div class="rd-counts">
              @for (state of countEntries(deployment); track state[0]) {
                <span [class.good]="state[0] === 'compliant'" [class.bad]="state[0] === 'noncompliant' || state[0] === 'error'">
                  {{ state[1] }} {{ complianceStateLabel(state[0]) }}
                </span>
              }
            </div>
            @if (deployment.targets.length) {
              <table class="rd-targets">
                <thead><tr><th>Host</th><th>Role / feature</th><th>Phase</th><th>State</th><th>Reason</th></tr></thead>
                <tbody>
                  @for (target of deployment.targets; track target.id) {
                    <tr [attr.data-host]="target.host || target.agent_id" [attr.data-state]="target.state">
                      <td>{{ target.host || target.agent_id }}</td>
                      <td>{{ itemName(deployment, target.item_id) }}</td>
                      <td>{{ target.phase }}</td>
                      <td><span class="rd-state" [class.good]="target.state === 'compliant'"
                        [class.bad]="['noncompliant', 'error', 'blocked'].includes(target.state)">{{ complianceStateLabel(target.state) }}</span></td>
                      <td class="rd-reason">{{ target.last_error || target.waiting_for || '—' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            }
          </mat-card>
        } @empty {
          <p class="rd-empty">No role deployments yet.</p>
        }
      </section>
    </div>
  `,
  styles: [`
    .rd-page { max-width: 1280px; margin: 0 auto; padding: 20px; }
    header, .rd-dep-head, .rd-buttons, .rd-actions, .rd-counts { display: flex; align-items: center; gap: 10px; }
    header, .rd-dep-head { justify-content: space-between; }
    h1, h2 { margin: 0; } header p, .rd-dep-head p { margin: 3px 0 0; opacity: .65; }
    .rd-create { margin: 18px 0 24px; }
    .rd-form { display: grid; grid-template-columns: repeat(2, minmax(220px, 1fr)); gap: 12px 18px; margin-top: 12px; }
    .rd-check { display: flex; align-items: flex-end; font-size: 12px; font-weight: 600; } .rd-check label { display: flex; gap: 6px; align-items: center; }
    .rd-form label:not(.rd-check label) { display: flex; flex-direction: column; gap: 5px; font-size: 12px; font-weight: 600; }
    .rd-form input, .rd-form select, .rd-form textarea { padding: 8px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .wide { grid-column: 1 / -1; } .rd-parameters { display: flex; flex-direction: column; gap: 7px; font-size: 12px; }
    .rd-buttons { margin-top: 14px; }
    .rd-preview { display: flex; flex-wrap: wrap; gap: 9px; margin-top: 14px; padding: 12px; border-radius: 7px; background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .rd-preview span { padding-left: 9px; border-left: 1px solid var(--mat-sys-outline-variant); }
    .rd-preview small { flex-basis: 100%; }
    .rd-preview .rd-na { color: var(--bm-red, #c62828); } .rd-preview .rd-sub { color: var(--bm-gold, #b8860b); }
    .rd-list h2 { margin-bottom: 10px; } .rd-deployment { margin-bottom: 10px; padding: 14px 16px; }
    .rd-status, .rd-counts span { margin-left: 8px; padding: 2px 8px; border-radius: 999px; font-size: 11px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .rd-status.pending { background: color-mix(in srgb, #f9a825 24%, transparent); }
    .rd-counts { margin-top: 10px; flex-wrap: wrap; } .rd-counts span { margin: 0; }
    .rd-counts .good { background: color-mix(in srgb, #2e7d32 22%, transparent); }
    .rd-counts .bad { background: color-mix(in srgb, var(--bm-red, #c62828) 20%, transparent); }
    .rd-error { display: block; color: var(--bm-red, #c62828); margin-top: 7px; }
    .rd-msg { margin-top: 10px; padding: 9px 12px; border-radius: 7px; background: color-mix(in srgb, #2e7d32 18%, transparent); }
    .rd-msg.error { background: color-mix(in srgb, var(--bm-red, #c62828) 18%, transparent); }
    .rd-empty, .rd-dim { opacity: .65; font-size: 12px; }
    .rd-actions { flex-wrap: wrap; justify-content: flex-end; }
    .rd-targets { width: 100%; margin-top: 10px; border-collapse: collapse; font-size: 12px; }
    .rd-targets th { text-align: left; font-weight: 600; opacity: .7; padding: 3px 8px 3px 0; }
    .rd-targets td { padding: 4px 8px 4px 0; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    .rd-reason { overflow-wrap: anywhere; }
    .rd-state { padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .rd-state.good { background: color-mix(in srgb, #2e7d32 22%, transparent); }
    .rd-state.bad { background: color-mix(in srgb, var(--bm-red, #c62828) 20%, transparent); }
    .rd-versions summary { cursor: pointer; font-size: 12px; font-weight: 600; }
    .rd-version-list { margin: 6px 0; padding-left: 18px; font-size: 12px; }
    .rd-version-list span { opacity: .7; margin-left: 6px; } .rd-version-list em { margin-left: 6px; opacity: .8; }
    .rd-compare { display: flex; gap: 12px; align-items: flex-end; margin: 6px 0; }
    .rd-diff { display: block; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; overflow: hidden; }
    @media (max-width: 800px) { .rd-form { grid-template-columns: 1fr; } .wide, .rd-check { grid-column: auto; } .rd-dep-head { align-items: flex-start; flex-direction: column; } .rd-actions { justify-content: flex-start; } .rd-targets th:nth-child(3), .rd-targets td:nth-child(3) { display: none; } }
  `],
})
export class RoleDeploymentsComponent implements OnInit, OnDestroy {
  private wizard = inject(WizardService);
  private agentService = inject(AgentService);
  private groupService = inject(HostGroupService);
  private ouService = inject(OuService);
  private siteService = inject(SiteService);
  private orchestration = inject(OrchestrationService);
  private auth = inject(AuthService);

  artifacts = signal<RoleArtifact[]>([]);
  /** Display names that more than one artifact carries — those options also show the technical name. */
  private duplicateNames = computed(() => {
    const seen = new Map<string, number>();
    for (const a of this.artifacts()) seen.set(a.display_name, (seen.get(a.display_name) ?? 0) + 1);
    return new Set([...seen].filter(([, n]) => n > 1).map(([name]) => name));
  });
  /** ONE NAME PER THING: two options must never read the same. A shared display name gets the artifact's own
   * (unique) name after it — measured, 23 options read "P · role · v1". */
  artifactLabel(a: { display_name: string; name: string; kind: string; current_version: number }): string {
    const shown = this.duplicateNames().has(a.display_name) || !a.display_name ? `${a.display_name || a.name} (${a.name})` : a.display_name;
    return `${shown} · ${a.kind} · v${a.current_version}`;
  }
  agents = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);
  ous = signal<OUNode[]>([]);
  sites = signal<Site[]>([]);
  busyId = signal<string | null>(null);
  // Version history of the selected artifact (loaded when the panel is opened) + the pair being compared.
  versions = signal<OrchestrationPlanVersion[]>([]);
  private versionsFor = '';
  diffFrom: number | null = null;
  diffTo: number | null = null;
  private diffPair = signal<[number | null, number | null]>([null, null]);
  diffTexts = computed(() => {
    const [from, to] = this.diffPair();
    const a = this.versions().find((v) => v.version === from);
    const b = this.versions().find((v) => v.version === to);
    return a && b ? { original: this.versionText(a), modified: this.versionText(b) } : null;
  });
  deployments = signal<RoleDeploymentDetail[]>([]);
  preview = signal<RoleDeploymentPreview | null>(null);
  busy = signal(false);
  message = signal('');
  messageError = signal(false);
  deploymentName = '';
  selectedArtifactId = '';
  scopeType: ScopeType = 'host';
  scopeId = '';
  parameters = signal<Record<string, unknown>>({});
  pilotMode: 'auto' | 'on' | 'off' = 'auto';
  requireApproval = false;
  private timer: ReturnType<typeof setInterval> | null = null;

  // Why Preview / Create are refused ('' = allowed): the one condition both [disabled] and the tooltip read.
  // Methods, not computed(): name/artifact/scope are plain ngModel fields, and a computed() over no signal
  // is evaluated once and cached forever — the Preview button never enabled.
  previewBlocked(): string {
    if (this.busy()) return 'Working…';
    if (!this.deploymentName.trim()) return 'Name the deployment first';
    if (!this.selectedArtifactId) return 'Select a role or feature first';
    if (this.scopeType !== 'global' && !this.scopeId) return `Select a ${SCOPE_NOUN[this.scopeType]} first`;
    return '';
  }
  /** Why the approval box cannot be unticked ('' = the operator decides): policy, read from the preview. */
  approvalForced(): string {
    const p = this.preview();
    if (p?.approval_required) return 'Policy requires a second administrator for all-hosts or more-than-10-host targets';
    if (this.scopeType === 'global') return 'Policy requires a second administrator for an all-hosts target';
    if (this.auth.role() !== 'admin') return 'A deployment created by a non-administrator always needs an administrator\'s approval';
    return '';
  }

  createBlocked(): string {
    if (this.busy()) return 'Working…';
    if (!this.preview()) return 'Preview first — the deployment is created from the previewed target set';
    return '';
  }

  ngOnInit(): void {
    this.reload();
    this.timer = setInterval(() => this.loadDeployments(), 10000);
  }

  ngOnDestroy(): void { if (this.timer) clearInterval(this.timer); }

  reload(): void {
    forkJoin({
      artifacts: this.wizard.listRoleArtifacts(),
      agents: this.agentService.list(),
      groups: this.groupService.list(),
      ous: this.ouService.list(),
      sites: this.siteService.list(),
      deployments: this.wizard.listRoleDeployments(),
    }).subscribe({
      next: ({ artifacts, agents, groups, ous, sites, deployments }) => {
        this.artifacts.set(artifacts.artifacts || []);
        this.agents.set(agents || []);
        this.groups.set(groups || []);
        this.ous.set(ous || []);
        this.sites.set(sites || []);
        this.deployments.set(deployments.deployments || []);
        if (this.versionsFor) this.loadVersions(this.versionsFor);
      },
      error: (e) => this.showError(e, 'Could not load role deployments'),
    });
  }

  private loadDeployments(): void {
    this.wizard.listRoleDeployments().subscribe({ next: (r) => this.deployments.set(r.deployments || []) });
  }

  /** Any change to what the preview locked drops it — and its "Preview is current." message, which would
   *  otherwise keep claiming a currency the form no longer has. */
  invalidatePreview(): void {
    if (this.preview() && this.message() === PREVIEW_CURRENT) this.setMessage('', false);
    this.preview.set(null);
  }

  scopeTitle(type: ScopeType): string { return SCOPE_TITLE[type]; }

  /** The pickable objects for the chosen target type — one list per type, labelled the way the app names them. */
  scopeOptions(): { id: string; label: string }[] {
    switch (this.scopeType) {
      case 'host': return this.agents().map((a) => ({ id: a.id, label: a.name }));
      case 'group': return this.groups().map((g) => ({ id: g.id, label: g.name }));
      case 'ou': return this.ous().map((o) => ({ id: o.id, label: o.path }));
      case 'site': return this.sites().map((x) => ({ id: x.id, label: `${x.name} (${x.subnets.join(', ') || 'no subnets'})` }));
      default: return [];
    }
  }

  scopeLabel(deployment: RoleDeploymentDetail): string {
    const find = <T extends { id: string }>(list: T[], id?: string | null) => list.find((x) => x.id === id);
    switch (deployment.scope_type) {
      case 'host': return `host ${find(this.agents(), deployment.agent_id)?.name ?? deployment.agent_id}`;
      case 'group': return `group ${find(this.groups(), deployment.host_group_id)?.name ?? deployment.host_group_id}`;
      case 'ou': return `OU ${find(this.ous(), deployment.ou_id)?.path ?? deployment.ou_id}`;
      case 'site': return `site ${find(this.sites(), deployment.site_id)?.name ?? deployment.site_id}`;
      default: return 'all hosts';
    }
  }

  itemName(deployment: RoleDeploymentDetail, itemId: string): string {
    const item = deployment.items.find((i) => i.id === itemId);
    return item ? `${item.display_name} v${item.version}` : itemId;
  }

  // Why each row action is refused ('' = allowed) — the one condition [disabled] and the tooltip both read.
  approveBlocked(deployment: RoleDeploymentDetail): string {
    if (this.busyId() === deployment.id) return 'Working…';
    if (this.auth.role() !== 'admin') return 'Only an administrator can approve a deployment';
    if (deployment.created_by && deployment.created_by === this.auth.username()) {
      return 'Four-eyes: another administrator must approve — you created this deployment';
    }
    return '';
  }
  detectBlocked(deployment: RoleDeploymentDetail): string {
    if (this.busyId() === deployment.id) return 'Working…';
    if (deployment.status === 'pending_approval') return 'Nothing is deployed yet — detection starts once the deployment is approved';
    if (deployment.status !== 'active') return `Detection runs only on an active deployment (this one is ${this.statusLabel(deployment.status).toLowerCase()})`;
    return '';
  }
  correctBlocked(deployment: RoleDeploymentDetail): string {
    if (this.busyId() === deployment.id) return 'Working…';
    if (deployment.status !== 'active') return 'Drift is corrected only on an active deployment';
    if (!this.driftTargets(deployment).length) return 'Nothing to correct — no target is drifted, failed or blocked';
    return '';
  }
  uninstallBlocked(deployment: RoleDeploymentDetail): string {
    if (this.busyId() === deployment.id) return 'Working…';
    return deployment.items.map((i) => i.uninstall_blocked).find((reason) => !!reason) || '';
  }

  versionsToggled(event: Event, artifactId: string): void {
    if ((event.target as HTMLDetailsElement).open) this.loadVersions(artifactId);
  }

  private loadVersions(artifactId: string): void {
    this.versionsFor = artifactId;
    this.orchestration.getPlan(artifactId).subscribe({
      next: (plan) => {
        if (this.versionsFor !== artifactId) return;
        const versions = [...(plan.versions || [])].sort((a, b) => a.version - b.version);
        this.versions.set(versions);
        // Default comparison: the previous version against the current one.
        this.diffTo = versions.at(-1)?.version ?? null;
        this.diffFrom = versions.at(-2)?.version ?? this.diffTo;
        this.diffChanged();
      },
      error: (e) => this.showError(e, 'Could not load the version history'),
    });
  }

  diffChanged(): void { this.diffPair.set([this.diffFrom, this.diffTo]); }

  /** What a version IS for comparison: its content, not its bookkeeping (id, timestamp, source hash). */
  private versionText(v: OrchestrationPlanVersion): string {
    const requirements = { ...(v.requirements || {}) } as Record<string, unknown>;
    delete requirements['source_hash'];
    delete requirements['template_bodies'];
    return JSON.stringify({
      parameter_schema: v.parameter_schema, default_parameters: v.default_parameters, requirements,
      steps: v.steps, rollback_steps: v.rollback_steps, validation_steps: v.validation_steps,
      generated_monitoring: v.generated_monitoring, generated_notifications: v.generated_notifications,
    }, null, 2);
  }

  selectedArtifact(): RoleArtifact | undefined {
    return this.artifacts().find((artifact) => artifact.id === this.selectedArtifactId);
  }

  selectedArtifactList(): RoleArtifact[] {
    const artifact = this.selectedArtifact();
    return artifact ? [artifact] : [];
  }

  hasParameters(artifact: RoleArtifact): boolean {
    return Object.values(artifact.parameter_schema || {}).some((spec) => !spec.hidden);
  }

  artifactChanged(): void {
    this.parameters.set({ ...(this.selectedArtifact()?.default_parameters || {}) });
    this.versions.set([]);
    this.versionsFor = '';
    this.invalidatePreview();
  }

  parametersChanged(values: Record<string, unknown>): void {
    this.parameters.set(values);
    this.invalidatePreview();
  }

  /** The operator's parameters only. Hidden runtime values (`_packages`, `_dest`, … — resolved per host from the
   *  catalog) are part of the form's values but are not the operator's to set; sending them is refused (422
   *  "runtime role parameter(s) cannot be overridden"), which made Preview fail for every catalog role whose
   *  form carried them. */
  private operatorParameters(): Record<string, unknown> {
    const schema = this.selectedArtifact()?.parameter_schema || {};
    return Object.fromEntries(Object.entries(this.parameters()).filter(
      ([key]) => !key.startsWith('_') && !(schema[key] as { hidden?: boolean } | undefined)?.hidden));
  }

  private request(): RoleDeploymentRequest | null {
    const request: RoleDeploymentRequest = {
      target: { type: this.scopeType, ...(this.scopeType === 'global' ? {} : { id: this.scopeId }) },
      items: [{ plan_id: this.selectedArtifactId, parameters: this.operatorParameters() }],
    };
    if (this.pilotMode !== 'auto') request.pilot_enabled = this.pilotMode === 'on';
    return request;
  }

  previewDeployment(): void {
    const body = this.request(); if (!body) return;
    this.busy.set(true);
    this.wizard.previewRoleDeployment(body).subscribe({
      next: (result) => { this.preview.set(result); this.busy.set(false); this.setMessage(PREVIEW_CURRENT, false); },
      error: (e) => { this.busy.set(false); this.showError(e, 'Preview failed'); },
    });
  }

  createDeployment(): void {
    const body = this.request(); const preview = this.preview();
    if (!body || !preview) return;
    this.busy.set(true);
    this.wizard.createRoleDeployment({
      ...body, name: this.deploymentName.trim(), preview_hash: preview.preview_hash,
      ...(this.requireApproval ? { require_approval: true } : {}),
    }).subscribe({
      next: (deployment) => {
        this.busy.set(false); this.preview.set(null);
        this.setMessage(deployment.status === 'pending_approval' ? 'Deployment created and awaiting approval.' : 'Deployment created.', false);
        this.loadDeployments();
      },
      error: (e) => {
        this.busy.set(false);
        // A refused create (409: membership changed) means the preview no longer describes the target — drop it,
        // so Create is greyed until the operator previews again, as the message says.
        if (e?.status === 409) this.preview.set(null);
        this.showError(e, 'Creating deployment failed');
      },
    });
  }

  approve(deployment: RoleDeploymentDetail): void {
    this.busyId.set(deployment.id);
    this.wizard.approveRoleDeployment(deployment.id).subscribe({
      next: () => { this.busyId.set(null); this.setMessage('Deployment approved.', false); this.loadDeployments(); },
      error: (e) => { this.busyId.set(null); this.showError(e, 'Approval failed'); },
    });
  }

  reconcile(deployment: RoleDeploymentDetail): void {
    this.busyId.set(deployment.id);
    this.wizard.reconcileRoleDeployment(deployment.id).subscribe({
      next: () => { this.busyId.set(null); this.setMessage('Compliance detection completed.', false); this.loadDeployments(); },
      error: (e) => { this.busyId.set(null); this.showError(e, 'Compliance detection failed'); },
    });
  }

  correct(deployment: RoleDeploymentDetail): void {
    const ids = this.driftTargets(deployment).map((target) => target.id);
    if (!ids.length || !window.confirm(`Reapply desired state to ${ids.length} non-compliant target(s)?`)) return;
    this.busyId.set(deployment.id);
    this.wizard.remediateRoleTargets(deployment.id, ids).pipe(
      switchMap(() => this.wizard.reconcileRoleDeployment(deployment.id)),
    ).subscribe({
      next: () => { this.busyId.set(null); this.setMessage('Drift correction completed.', false); this.loadDeployments(); },
      error: (e) => { this.busyId.set(null); this.showError(e, 'Drift correction failed'); },
    });
  }

  retire(deployment: RoleDeploymentDetail, uninstall = false): void {
    const question = uninstall
      ? 'Uninstall this deployment from every managed target? Configuration files may remain according to package-manager policy.'
      : 'Stop managing this deployment? Installed software and configuration will remain unchanged.';
    if (!window.confirm(question)) return;
    this.busyId.set(deployment.id);
    this.wizard.retireRoleDeployment(deployment.id, uninstall ? 'uninstall' : 'unmanage').subscribe({
      next: () => { this.busyId.set(null); this.setMessage(uninstall ? 'Deployment uninstalled and retired.' : 'Deployment retired; software was left installed.', false); this.loadDeployments(); },
      error: (e) => { this.busyId.set(null); this.showError(e, 'Could not retire deployment'); },
    });
  }

  driftTargets(deployment: RoleDeploymentDetail) {
    return deployment.targets.filter((target) => ['noncompliant', 'error', 'blocked'].includes(target.state));
  }

  countEntries(deployment: RoleDeploymentDetail): [string, number][] {
    return Object.entries(deployment.compliance).sort((a, b) => a[0].localeCompare(b[0]));
  }

  itemLabel(deployment: RoleDeploymentDetail): string {
    return deployment.items.map((item) => `${item.display_name} v${item.version}`).join(', ');
  }

  complianceLabel(deployment: RoleDeploymentDetail): string {
    const good = deployment.compliance['compliant'] || 0;
    const total = Object.values(deployment.compliance).reduce((sum, count) => sum + count, 0);
    return `${good}/${total} compliant`;
  }

  statusLabel(status: string): string {
    return ({ pending_approval: 'Pending approval', active: 'Active', retired: 'Retired', paused: 'Paused', failed: 'Failed', draft: 'Draft' } as Record<string, string>)[status] || status;
  }

  complianceStateLabel(state: string): string {
    return ({ compliant: 'compliant', noncompliant: 'drifted', not_applicable: 'not applicable', pending: 'pending', installing: 'installing', blocked: 'blocked', error: 'errors', unmanaged: 'unmanaged', unknown: 'unknown' } as Record<string, string>)[state] || state;
  }

  private setMessage(message: string, error: boolean): void { this.message.set(message); this.messageError.set(error); }
  private showError(error: { error?: { detail?: string }; message?: string }, fallback: string): void {
    this.setMessage(error?.error?.detail || error?.message || fallback, true);
  }
}
