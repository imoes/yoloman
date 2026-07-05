import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatDialog } from '@angular/material/dialog';
import { AuthService } from '../../core/auth/auth.service';
import { PlanService } from '../../core/services/plan.service';
import { EnrollService } from '../../core/services/enroll.service';
import { AgentService } from '../../core/services/agent.service';
import { MonitoringService } from '../../core/services/monitoring.service';
import { EnrollInfo } from '../../core/models/enroll.model';
import { Agent } from '../../core/models/agent.model';
import { CheckRule, CheckRuleInput } from '../../core/models/monitoring.model';
import { CheckRuleDialogComponent, CheckRuleDialogData } from '../../shared/components/check-rule-dialog/check-rule-dialog.component';

/**
 * v1 scope, deliberately small: Bossman's REST API has no user-management
 * or trusted-key-management endpoints yet (see docs/plan.md's Bossman
 * Block B6 "known gap" note — no seed script/CLI/API for
 * bossman_users/api_tokens exists beyond direct DB access or
 * services.auth calls). This page only surfaces what's actually backed
 * by a real endpoint today: the logged-in identity, the plan-catalog
 * reload action from Block B8's prompt-caching design, and (Block E1) the
 * enrollment command a new host needs to actually appear anywhere in this
 * UI — without a host, the "Run a plan" dialog has nothing to pick from.
 */
@Component({
  selector: 'app-settings',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule],
  template: `
    <div class="bm-page">
      <h1>Settings</h1>

      <mat-card>
        <mat-card-header>
          <mat-card-title>Session</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>Signed in as <strong>{{ auth.username() }}</strong> ({{ auth.role() }})</p>
        </mat-card-content>
        <mat-card-actions>
          <button mat-button color="warn" (click)="auth.logout()">Log out</button>
        </mat-card-actions>
      </mat-card>

      <mat-card class="bm-enroll-card">
        <mat-card-header>
          <mat-card-title>Enrollment</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          @if (enrollInfo(); as info) {
            @if (info.configured) {
              <p>
                Run this on a server to enroll it as a node agent (Duppy) — it'll then show up here
                and become available to run plans against:
              </p>
              <div class="bm-command-row">
                <code class="bm-command">{{ info.register_command }}</code>
                <button mat-icon-button (click)="copyCommand(info.register_command)" title="Copy">
                  <mat-icon>content_copy</mat-icon>
                </button>
              </div>
              @if (copied()) {
                <p class="bm-success">Copied.</p>
              }
            } @else {
              <p class="bm-empty">
                Enrollment isn't configured on this Bossman instance yet — set
                <code>BOSSMAN_ENROLL_SECRET</code> (and, ideally, <code>BOSSMAN_PUBLIC_URL</code> so
                the exact command can be shown here) to allow new hosts to enroll.
              </p>
            }
          }
        </mat-card-content>
      </mat-card>

      <mat-card class="bm-catalog-card">
        <mat-card-header>
          <mat-card-title>Plan catalog</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>
            The MCP facade's plan catalog is cached and only re-rendered on explicit reload — this
            is what keeps it byte-identical for prompt caching (see docs/plan.md's Bossman plan).
            Reload it here after adding or editing a plan file on disk.
          </p>
          @if (reloadMessage()) {
            <p class="bm-success">{{ reloadMessage() }}</p>
          }
        </mat-card-content>
        <mat-card-actions>
          <button mat-raised-button color="primary" (click)="reloadCatalog()">Reload plan catalog</button>
        </mat-card-actions>
      </mat-card>

      <mat-card class="bm-rules-card">
        <mat-card-header>
          <mat-card-title>Check rules</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>
            Thresholds that derive each host's monitored services (see docs/plan.md's monitoring
            Block E2) — a host-scoped rule always overrides a group rule, which overrides a global
            rule, for the same metric.
          </p>
          @if (checkRules().length) {
            <table class="bm-table">
              <thead>
                <tr>
                  <th>Service</th>
                  <th>Metric</th>
                  <th>Rule</th>
                  <th>Scope</th>
                  <th>Enabled</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                @for (rule of checkRules(); track rule.id) {
                  <tr>
                    <td>{{ rule.service_name }}</td>
                    <td>{{ rule.metric }}</td>
                    <td>
                      {{ rule.comparison }} warn {{ rule.warn_threshold ?? '—' }} / crit
                      {{ rule.crit_threshold ?? '—' }}
                    </td>
                    <td>{{ rule.scope_type }}{{ rule.scope_value ? ': ' + rule.scope_value : '' }}</td>
                    <td>{{ rule.enabled ? 'yes' : 'no' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="editCheckRule(rule)">Edit</button>
                      <button mat-button color="warn" (click)="deleteCheckRule(rule)">Delete</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No check rules defined yet — every host's services list will stay empty.</p>
          }
        </mat-card-content>
        <mat-card-actions>
          <button mat-raised-button color="primary" (click)="createCheckRule()">Add check rule</button>
        </mat-card-actions>
      </mat-card>

      <mat-card class="bm-groups-card">
        <mat-card-header>
          <mat-card-title>Host groups</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>Comma-separated group membership per host — the unit a group-scoped check rule targets.</p>
          @if (agents().length) {
            <table class="bm-table">
              <thead>
                <tr>
                  <th>Host</th>
                  <th>Groups</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                @for (agent of agents(); track agent.id) {
                  <tr>
                    <td>{{ agent.name }}</td>
                    <td>
                      <mat-form-field appearance="outline" class="bm-groups-field">
                        <input matInput [(ngModel)]="groupsDraft[agent.id]" placeholder="e.g. webservers, prod" />
                      </mat-form-field>
                    </td>
                    <td class="bm-actions">
                      <button mat-button (click)="saveGroups(agent)">Save</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No hosts enrolled yet.</p>
          }
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 900px;
        margin: 0 auto;
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 8px;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 8px 10px;
      }
      .bm-table td {
        padding: 8px 10px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-actions {
        text-align: right;
        white-space: nowrap;
      }
      .bm-groups-field {
        width: 100%;
      }
      .bm-success {
        color: var(--bm-green);
      }
      .bm-empty {
        opacity: 0.75;
      }
      .bm-command-row {
        display: flex;
        align-items: center;
        gap: 8px;
      }
      .bm-command {
        display: block;
        flex: 1;
        padding: 10px 12px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent);
        border-radius: 6px;
        font-size: 12.5px;
        overflow-x: auto;
        white-space: pre;
      }
    `,
  ],
})
export class SettingsComponent implements OnInit {
  auth = inject(AuthService);
  private planService = inject(PlanService);
  private enrollService = inject(EnrollService);
  private agentService = inject(AgentService);
  private monitoringService = inject(MonitoringService);
  private dialog = inject(MatDialog);

  reloadMessage = signal<string | null>(null);
  enrollInfo = signal<EnrollInfo | null>(null);
  copied = signal(false);
  checkRules = signal<CheckRule[]>([]);
  agents = signal<Agent[]>([]);
  groupsDraft: Record<string, string> = {};

  ngOnInit(): void {
    this.enrollService.info().subscribe((info) => this.enrollInfo.set(info));
    this.reloadCheckRules();
    this.reloadAgents();
  }

  private reloadCheckRules(): void {
    this.monitoringService.listCheckRules().subscribe((rules) => this.checkRules.set(rules));
  }

  private reloadAgents(): void {
    this.agentService.list().subscribe((agents) => {
      this.agents.set(agents);
      for (const agent of agents) {
        this.groupsDraft[agent.id] = agent.groups.join(', ');
      }
    });
  }

  createCheckRule(): void {
    const ref = this.dialog.open<CheckRuleDialogComponent, CheckRuleDialogData, CheckRuleInput>(CheckRuleDialogComponent, {
      width: '480px',
      data: {},
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.monitoringService.createCheckRule(input).subscribe(() => this.reloadCheckRules());
    });
  }

  editCheckRule(rule: CheckRule): void {
    const ref = this.dialog.open<CheckRuleDialogComponent, CheckRuleDialogData, CheckRuleInput>(CheckRuleDialogComponent, {
      width: '480px',
      data: { rule },
    });
    ref.afterClosed().subscribe((input) => {
      if (!input) return;
      this.monitoringService.updateCheckRule(rule.id, input).subscribe(() => this.reloadCheckRules());
    });
  }

  deleteCheckRule(rule: CheckRule): void {
    this.monitoringService.deleteCheckRule(rule.id).subscribe(() => this.reloadCheckRules());
  }

  saveGroups(agent: Agent): void {
    const groups = (this.groupsDraft[agent.id] ?? '')
      .split(',')
      .map((g) => g.trim())
      .filter(Boolean);
    this.agentService.updateGroups(agent.id, groups).subscribe((updated) => {
      this.agents.update((agents) => agents.map((a) => (a.id === updated.id ? updated : a)));
      this.groupsDraft[updated.id] = updated.groups.join(', ');
    });
  }

  reloadCatalog(): void {
    this.planService.reload().subscribe((res) => {
      this.reloadMessage.set(`Reloaded — catalog is now ${res.catalog_length} characters.`);
    });
  }

  copyCommand(command: string | null): void {
    if (!command) return;
    navigator.clipboard.writeText(command).then(() => {
      this.copied.set(true);
      setTimeout(() => this.copied.set(false), 2000);
    });
  }
}
