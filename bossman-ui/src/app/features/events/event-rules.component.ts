import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatSnackBar } from '@angular/material/snack-bar';
import { EventRule, EventRuleInput, EventRun } from '../../core/models/event-rule.model';
import { EventRuleService } from '../../core/services/event-rule.service';
import { EventHandler } from '../../core/models/event-handler.model';
import { EventHandlerService } from '../../core/services/event-handler.service';
import { Agent } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { HostGroup } from '../../core/models/host-group.model';
import { HostGroupService } from '../../core/services/host-group.service';
import { OUNode } from '../../core/models/ou.model';
import { OuService } from '../../core/services/ou.service';
import { WizardService } from '../../core/services/wizard.service';

/** One sentence per guardrail. A number without its consequence is a setting nobody can judge. */
const GUARDRAIL_TEXT = {
  max_per_hour: 'At most this many runs per host per hour. The limit exists so a problem that keeps re-firing cannot turn into a restart loop.',
  mode: 'auto acts when the trigger fires; propose only records a suggestion for someone to apply.',
  autonomy: 'propose means a human applies every run. auto_verify applies automatically when the guardrails below pass, then re-checks and escalates or rolls back — and a global kill-switch must be on as well.',
  allow_prod: 'Without this, auto_verify refuses on hosts marked production (criticality or an env tag).',
  max_blast_radius: 'How many hosts one triggering event may act on automatically. Above it, the run waits for a human.',
  verify: 'After applying, re-check the trigger and escalate if it did not recover — the difference between "we ran something" and "it worked".',
  rollback_runbook: 'Run this if verification fails: a best-effort undo, so an automatic action has a way back.',
} as const;

function emptyDraft(): EventRuleInput {
  return {
    name: '', match_service_name: '', scope_type: 'global',
    ou_id: null, host_group_id: null, agent_id: null, conditions: {},
    runbook_name: '', event_handler_id: null, params: {},
    max_per_hour: 3, mode: 'auto', enabled: true,
    verify: true, verify_after_s: 60, autonomy: 'propose',
    allow_prod: false, max_blast_radius: 1, rollback_runbook: null,
  };
}

/** Event rules — the binding between a TRIGGER and an ACTION (docs/event-handling.md).
 *
 * Lives under Monitor rather than Library: a handler is *authored* (and sits with the other
 * authored things), but a rule REACTS — it is read and judged next to the events it answers, and
 * its run history is monitoring history.
 *
 * The two properties this screen is built around:
 *
 *  1. **One action, offered as one choice.** The schema permits exactly one of `runbook_name` and
 *     `event_handler_id`; showing two fields would invite the combination the database refuses.
 *     Picking a handler also renders ITS declared parameters — the only place those values can be
 *     configured.
 *  2. **The run is the observation point.** A rule without runs is a promise. Each run carries
 *     what ran (`action`), what came back (`detail`), and where it is in the closed loop
 *     (`phase`, `verify_state`, `outcome`) — with Apply/Dismiss for the ones waiting on a human.
 */
@Component({
  selector: 'app-event-rules',
  standalone: true,
  imports: [
    DatePipe, FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatSelectModule,
    MatIconModule, MatButtonModule, MatCheckboxModule,
  ],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Event rules</h1>
        <div class="bm-actions">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> New rule</button>
        </div>
      </div>
      <p class="bm-subtitle">
        When a check goes into a confirmed problem state on a host this rule covers, run its
        action — a runbook or an <strong>event handler</strong>. Bossman is always the trigger;
        the guardrails below decide whether it acts by itself or asks first.
      </p>

      <div class="bm-split">
        <mat-card class="bm-panel">
          <mat-card-content>
            <div class="bm-count">
              <span class="bm-big">{{ rules().length }}</span> rule(s)
              @if (pendingCount()) {
                <span class="bm-pending">{{ pendingCount() }} waiting for a decision</span>
              }
            </div>
            @for (r of rules(); track r.id) {
              <div class="bm-item" [class.bm-item-selected]="selectedId() === r.id" (click)="select(r)">
                <div class="bm-item-name">
                  {{ r.name }}
                  @if (!r.enabled) { <span class="bm-chip">disabled</span> }
                </div>
                <div class="bm-item-meta">
                  {{ r.match_service_name || 'any check' }} · {{ scopeLabel(r) }} · {{ actionLabel(r) }}
                </div>
              </div>
            } @empty {
              @if (!loading()) {
                <p class="bm-dim">No rules yet. Without one, an event handler is never run.</p>
              }
            }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-content>
            @if (draft(); as d) {
              <div class="bm-detail-head">
                <h2>{{ isNew() ? 'New event rule' : d.name }}</h2>
                @if (!isNew()) {
                  <button mat-stroked-button class="bm-danger" (click)="remove()">
                    <mat-icon>delete</mat-icon> Delete
                  </button>
                }
              </div>

              <!-- trigger -->
              <h3>When <span class="bm-hint">the trigger</span></h3>
              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Name</mat-label>
                  <input matInput [ngModel]="d.name" (ngModelChange)="patch({ name: $event })"
                         placeholder="restart nginx when it dies" />
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>Check (empty = every check)</mat-label>
                  <input matInput [ngModel]="d.match_service_name"
                         (ngModelChange)="patch({ match_service_name: $event })" placeholder="Disk /" />
                </mat-form-field>
              </div>
              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Applies to</mat-label>
                  <mat-select [ngModel]="d.scope_type" (ngModelChange)="setScope($event)">
                    <mat-option value="global">every host</mat-option>
                    <mat-option value="ou">one OU</mat-option>
                    <mat-option value="group">one host group</mat-option>
                    <mat-option value="host">one host</mat-option>
                  </mat-select>
                </mat-form-field>
                @if (d.scope_type === 'ou') {
                  <mat-form-field appearance="outline">
                    <mat-label>OU</mat-label>
                    <mat-select [ngModel]="d.ou_id" (ngModelChange)="patch({ ou_id: $event })">
                      @for (o of ous(); track o.id) { <mat-option [value]="o.id">{{ o.name }}</mat-option> }
                    </mat-select>
                  </mat-form-field>
                }
                @if (d.scope_type === 'group') {
                  <mat-form-field appearance="outline">
                    <mat-label>Host group</mat-label>
                    <mat-select [ngModel]="d.host_group_id" (ngModelChange)="patch({ host_group_id: $event })">
                      @for (g of groups(); track g.id) { <mat-option [value]="g.id">{{ g.name }}</mat-option> }
                    </mat-select>
                  </mat-form-field>
                  @if (!groups().length) {
                    <p class="bm-note bm-warn">There are no host groups yet, so this scope would match nothing.</p>
                  }
                }
                @if (d.scope_type === 'host') {
                  <mat-form-field appearance="outline">
                    <mat-label>Host</mat-label>
                    <mat-select [ngModel]="d.agent_id" (ngModelChange)="patch({ agent_id: $event })">
                      @for (a of agents(); track a.id) { <mat-option [value]="a.id">{{ a.name }}</mat-option> }
                    </mat-select>
                  </mat-form-field>
                }
              </div>

              <!-- action: ONE choice -->
              <h3>Then <span class="bm-hint">the action — exactly one</span></h3>
              <div class="bm-src">
                <button type="button" class="bm-src-btn" [class.active]="actionKind() === 'handler'"
                        (click)="setActionKind('handler')">Event handler</button>
                <button type="button" class="bm-src-btn" [class.active]="actionKind() === 'runbook'"
                        (click)="setActionKind('runbook')">Runbook</button>
              </div>
              <p class="bm-note">
                A rule has one action. Offering both at once would invite a combination the
                database refuses — and a rule with neither would fire and do nothing.
              </p>

              @if (actionKind() === 'handler') {
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Handler</mat-label>
                  <mat-select [ngModel]="d.event_handler_id" (ngModelChange)="setHandler($event)">
                    @for (h of handlers(); track h.id) {
                      <mat-option [value]="h.id">
                        {{ h.name }} — {{ h.body }}@if (h.body === 'script') { / {{ h.location }} }
                      </mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                @if (!handlers().length) {
                  <p class="bm-note bm-warn">
                    No handlers exist yet — create one under Library ▸ Event handlers first.
                  </p>
                }
                @if (selectedHandler(); as h) {
                  @if (h.parameters.length) {
                    <h4>Parameters of “{{ h.name }}”</h4>
                    <table class="bm-table">
                      <thead><tr><th>Parameter</th><th>Value</th><th>Variable</th></tr></thead>
                      <tbody>
                        @for (p of h.parameters; track p.name) {
                          <tr>
                            <td>
                              {{ p.name }}
                              @if (p.required) { <span class="bm-req">required</span> }
                              @if (p.description) { <div class="bm-dim bm-sd">{{ p.description }}</div> }
                            </td>
                            <td>
                              <input class="bm-in" [ngModel]="paramValue(p.name)"
                                     (ngModelChange)="setParam(p.name, $event)"
                                     [placeholder]="p.default || ''" />
                            </td>
                            <td class="bm-mono bm-dim">{{ envName(p.name) }}</td>
                          </tr>
                        }
                      </tbody>
                    </table>
                    <p class="bm-note">
                      These values live only here, in Bossman — that is what “parameters are
                      configured in Bossman” means. A required one with no value and no default is
                      refused when saving, not when the event fires.
                    </p>
                  } @else if (h.location === 'local') {
                    <p class="bm-note bm-why">
                      <mat-icon inline>info</mat-icon>
                      <span>This handler's script lives on the host, so Bossman cannot describe its
                      parameters and passes none. It still receives the event context.</span>
                    </p>
                  }
                }
              } @else {
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Runbook</mat-label>
                  <mat-select [ngModel]="d.runbook_name" (ngModelChange)="patch({ runbook_name: $event })">
                    @for (r of runbooks(); track r) { <mat-option [value]="r">{{ r }}</mat-option> }
                  </mat-select>
                </mat-form-field>
              }

              <!-- guardrails -->
              <h3>Guardrails <span class="bm-hint">what stops this from doing damage</span></h3>
              <div class="bm-fields">
                <mat-form-field appearance="outline" class="bm-narrow">
                  <mat-label>Runs per hour</mat-label>
                  <input matInput type="number" min="1" [ngModel]="d.max_per_hour"
                         (ngModelChange)="patch({ max_per_hour: +$event })" />
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>Autonomy</mat-label>
                  <mat-select [ngModel]="d.autonomy" (ngModelChange)="patch({ autonomy: $event })">
                    <mat-option value="propose">propose — a human applies</mat-option>
                    <mat-option value="auto_verify">auto_verify — act, then verify</mat-option>
                  </mat-select>
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-narrow">
                  <mat-label>Blast radius</mat-label>
                  <input matInput type="number" min="1" [ngModel]="d.max_blast_radius"
                         (ngModelChange)="patch({ max_blast_radius: +$event })" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-narrow">
                  <mat-label>Verify after (s)</mat-label>
                  <input matInput type="number" min="1" [ngModel]="d.verify_after_s"
                         (ngModelChange)="patch({ verify_after_s: +$event })" />
                </mat-form-field>
              </div>
              <p class="bm-note">{{ guard.max_per_hour }}</p>
              <p class="bm-note">{{ guard.autonomy }}</p>
              <p class="bm-note">{{ guard.max_blast_radius }}</p>
              <div class="bm-checks">
                <mat-checkbox [checked]="d.verify" (change)="patch({ verify: !d.verify })">
                  Verify after applying
                </mat-checkbox>
                <mat-checkbox [checked]="d.allow_prod" (change)="patch({ allow_prod: !d.allow_prod })">
                  Allow automatic action on production hosts
                </mat-checkbox>
                <mat-checkbox [checked]="d.enabled" (change)="patch({ enabled: !d.enabled })">Enabled</mat-checkbox>
              </div>
              <p class="bm-note">{{ guard.verify }}</p>
              <p class="bm-note">{{ guard.allow_prod }}</p>
              <mat-form-field appearance="outline" class="bm-wide">
                <mat-label>Rollback runbook (optional)</mat-label>
                <mat-select [ngModel]="d.rollback_runbook" (ngModelChange)="patch({ rollback_runbook: $event })">
                  <mat-option [value]="null">— none —</mat-option>
                  @for (r of runbooks(); track r) { <mat-option [value]="r">{{ r }}</mat-option> }
                </mat-select>
              </mat-form-field>
              <p class="bm-note">{{ guard.rollback_runbook }}</p>

              <div class="bm-save-row">
                <button mat-flat-button [disabled]="!canSave() || saving()" (click)="save()">
                  <mat-icon>save</mat-icon> {{ isNew() ? 'Create' : 'Save' }}
                </button>
                <button mat-button (click)="cancel()">Cancel</button>
                @if (blocker(); as b) { <span class="bm-dim">{{ b }}</span> }
              </div>

              <!-- runs -->
              @if (!isNew()) {
                <h3>
                  Runs <span class="bm-hint">what actually happened — a rule without runs is a promise</span>
                </h3>
                @if (runsOf(selectedId()).length) {
                  <table class="bm-table">
                    <thead><tr><th>When</th><th>Host</th><th>Check</th><th>Ran</th><th>Status</th><th>Detail</th><th></th></tr></thead>
                    <tbody>
                      @for (run of runsOf(selectedId()); track run.id) {
                        <tr>
                          <td class="bm-dim">{{ run.at | date: 'short' }}</td>
                          <td>{{ hostName(run.agent_id) }}</td>
                          <td>{{ run.service_name }}</td>
                          <td class="bm-mono">{{ run.action || '—' }}</td>
                          <td>
                            <span class="bm-state bm-{{ run.status }}">{{ run.status }}</span>
                            @if (run.verify_state) { <span class="bm-dim bm-sd">verify: {{ run.verify_state }}</span> }
                          </td>
                          <td class="bm-dim bm-detail">{{ run.detail }}</td>
                          <td class="bm-right">
                            @if (run.status === 'pending') {
                              <button mat-stroked-button (click)="applyRun(run)">Apply</button>
                              <button mat-button (click)="dismissRun(run)">Dismiss</button>
                            }
                          </td>
                        </tr>
                      }
                    </tbody>
                  </table>
                } @else {
                  <p class="bm-dim">
                    No runs recorded for this rule yet — it has not been triggered, or the check it
                    watches has stayed healthy.
                  </p>
                }

                <h4>Trigger it now</h4>
                <div class="bm-fields">
                  <mat-form-field appearance="outline">
                    <mat-label>Host</mat-label>
                    <mat-select [ngModel]="triggerHost()" (ngModelChange)="triggerHost.set($event)">
                      @for (a of agents(); track a.id) { <mat-option [value]="a.id">{{ a.name }}</mat-option> }
                    </mat-select>
                  </mat-form-field>
                  <mat-form-field appearance="outline">
                    <mat-label>Check</mat-label>
                    <input matInput [ngModel]="triggerService()" (ngModelChange)="triggerService.set($event)"
                           [placeholder]="d.match_service_name || 'Disk /'" />
                  </mat-form-field>
                  <button mat-stroked-button [disabled]="!triggerHost() || !triggerService()"
                          (click)="trigger()"><mat-icon>bolt</mat-icon> Run matching rules</button>
                </div>
                <p class="bm-note">
                  Runs every rule matching that (host, check) immediately and bypasses the
                  per-hour limit — an operator-initiated action, recorded like any other.
                </p>
              }
            } @else {
              <p class="bm-dim bm-empty">Select a rule, or create one.</p>
            }
          </mat-card-content>
        </mat-card>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; }
      .bm-header-row { display: flex; align-items: center; justify-content: space-between; }
      .bm-actions { display: flex; gap: 8px; }
      .bm-subtitle { opacity: 0.72; margin-top: 4px; max-width: 900px; }
      .bm-split { display: grid; grid-template-columns: minmax(230px, 300px) 1fr; gap: 12px; margin-top: 12px; align-items: start; }
      @media (max-width: 900px) { .bm-split { grid-template-columns: 1fr; } }
      .bm-count { font-size: 15px; margin-bottom: 8px; }
      .bm-big { font-size: 28px; font-weight: 600; color: var(--bm-green); }
      .bm-pending { margin-left: 10px; font-size: 12px; padding: 2px 9px; border-radius: 999px;
                    background: color-mix(in srgb, #ffc800 34%, transparent); }
      .bm-item { padding: 7px 10px; border-radius: 8px; cursor: pointer; }
      .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-item-selected { background: color-mix(in srgb, var(--bm-green) 14%, transparent); }
      .bm-item-name { font-weight: 500; }
      .bm-item-meta { font-size: 12px; opacity: 0.65; }
      .bm-chip { margin-left: 8px; font-size: 11px; padding: 1px 8px; border-radius: 999px;
                 background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .bm-detail-head h2 { margin: 0; font-size: 19px; }
      .bm-fields { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 10px; align-items: center; }
      .bm-fields mat-form-field { flex: 1 1 210px; }
      .bm-wide { width: 100%; }
      .bm-narrow { flex: 0 0 150px !important; }
      h3 { font-size: 14px; margin: 22px 0 4px; display: flex; align-items: baseline; gap: 10px; }
      h4 { font-size: 13px; margin: 16px 0 4px; }
      .bm-hint { font-size: 12px; font-weight: 400; opacity: 0.6; }
      .bm-note { font-size: 12.5px; opacity: 0.72; margin: 4px 0 0; max-width: 880px; }
      .bm-warn { color: var(--mat-sys-error); opacity: 1; }
      .bm-why { display: flex; gap: 8px; align-items: flex-start; opacity: 1;
                background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent);
                border-radius: 8px; padding: 10px 12px; }
      .bm-src { display: flex; gap: 8px; margin-top: 8px; max-width: 420px; }
      .bm-src-btn { flex: 1; padding: 8px; border-radius: 8px; font: inherit; font-size: 12.5px;
                    border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; }
      .bm-src-btn.active { border-color: var(--bm-green); background: color-mix(in srgb, var(--bm-green) 12%, transparent); }
      .bm-checks { display: flex; flex-direction: column; gap: 4px; margin-top: 10px; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-table td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; vertical-align: top; }
      .bm-in { width: 100%; max-width: 220px; background: transparent; color: inherit; font: inherit;
               font-size: 12.5px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 4px 6px; }
      .bm-mono { font-family: monospace; font-size: 12px; }
      .bm-dim { opacity: 0.62; }
      .bm-sd { font-size: 11.5px; }
      .bm-detail { max-width: 380px; }
      .bm-right { text-align: right; white-space: nowrap; }
      .bm-req { margin-left: 6px; font-size: 10.5px; padding: 1px 6px; border-radius: 999px;
                background: color-mix(in srgb, var(--mat-sys-error) 22%, transparent); }
      .bm-save-row { display: flex; align-items: center; gap: 10px; margin-top: 18px; padding-top: 14px;
                     border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-danger { color: var(--mat-sys-error); }
      .bm-empty { padding: 28px 4px; }
      .bm-state { font-size: 11px; font-weight: 700; padding: 1px 9px; border-radius: 999px; }
      .bm-ran { background: color-mix(in srgb, var(--bm-green) 28%, transparent); }
      .bm-pending { background: color-mix(in srgb, #ffc800 32%, transparent); }
      .bm-failed { background: color-mix(in srgb, var(--mat-sys-error) 28%, transparent); }
      .bm-rate_limited { background: color-mix(in srgb, var(--mat-sys-on-surface) 16%, transparent); }
    `,
  ],
})
export class EventRulesComponent implements OnInit {
  private service = inject(EventRuleService);
  private handlerService = inject(EventHandlerService);
  private agentService = inject(AgentService);
  private groupService = inject(HostGroupService);
  private ouService = inject(OuService);
  private wizard = inject(WizardService);
  private snack = inject(MatSnackBar);

  readonly guard = GUARDRAIL_TEXT;

  rules = signal<EventRule[]>([]);
  runs = signal<EventRun[]>([]);
  handlers = signal<EventHandler[]>([]);
  agents = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);
  ous = signal<OUNode[]>([]);
  runbooks = signal<string[]>([]);
  loading = signal(true);
  saving = signal(false);

  selectedId = signal<string | null>(null);
  isNew = signal(false);
  draft = signal<EventRuleInput | null>(null);
  /** Which of the two actions the editor is showing. Derived from the draft, never a third
   * stored state — the rule itself has only one action. */
  actionKind = signal<'handler' | 'runbook'>('handler');

  triggerHost = signal<string | null>(null);
  triggerService = signal('');

  pendingCount = computed(() => this.runs().filter((r) => r.status === 'pending').length);
  selectedHandler = computed(() => {
    const id = this.draft()?.event_handler_id;
    return id ? this.handlers().find((h) => h.id === id) ?? null : null;
  });

  ngOnInit(): void {
    this.reload();
    this.handlerService.list().subscribe((h) => this.handlers.set(h.filter((x) => x.enabled)));
    this.agentService.list().subscribe((a) => this.agents.set(a));
    this.groupService.list().subscribe((g) => this.groups.set(g));
    this.ouService.list().subscribe({ next: (o) => this.ous.set(o), error: () => this.ous.set([]) });
    this.wizard.listRunbooks().subscribe({
      next: (r) => this.runbooks.set((r.runbooks || []).filter((x) => (x.kind || 'runbook') !== 'role').map((x) => x.name).sort()),
      error: () => this.runbooks.set([]),
    });
  }

  reload(): void {
    this.loading.set(true);
    this.service.list().subscribe({
      next: (rows) => {
        this.rules.set(rows);
        this.loading.set(false);
        const id = this.selectedId();
        const again = rows.find((r) => r.id === id);
        if (id && again && !this.isNew()) this.load(again);
        else if (id && !again) { this.selectedId.set(null); this.draft.set(null); }
      },
      error: () => this.loading.set(false),
    });
    this.service.runs(undefined, 200).subscribe({ next: (r) => this.runs.set(r), error: () => this.runs.set([]) });
  }

  runsOf(ruleId: string | null): EventRun[] {
    return ruleId ? this.runs().filter((r) => r.policy_id === ruleId) : [];
  }

  hostName(agentId: string | null): string {
    if (!agentId) return '—';
    return this.agents().find((a) => a.id === agentId)?.name ?? agentId.slice(0, 8);
  }

  scopeLabel(r: EventRule): string {
    if (r.scope_type === 'global') return 'every host';
    if (r.scope_type === 'ou') return `OU ${this.ous().find((o) => o.id === r.ou_id)?.name ?? '?'}`;
    if (r.scope_type === 'group') return `group ${this.groups().find((g) => g.id === r.host_group_id)?.name ?? '?'}`;
    return `host ${this.hostName(r.agent_id)}`;
  }

  /** What this rule runs, named the way the audit rows are. */
  actionLabel(r: EventRule): string {
    if (r.event_handler_id) {
      const h = this.handlers().find((x) => x.id === r.event_handler_id);
      return `handler:${h?.name ?? r.event_handler_id.slice(0, 8)}`;
    }
    return r.runbook_name ? `runbook:${r.runbook_name}` : 'no action';
  }

  envName(name: string): string {
    return 'BOSSMAN_' + (name || '').trim().toUpperCase().replace(/[^A-Z0-9_]/g, '_');
  }

  select(r: EventRule): void {
    this.isNew.set(false);
    this.selectedId.set(r.id);
    this.load(r);
  }

  private load(r: EventRule): void {
    this.draft.set({
      name: r.name, match_service_name: r.match_service_name, scope_type: r.scope_type,
      ou_id: r.ou_id, host_group_id: r.host_group_id, agent_id: r.agent_id,
      conditions: { ...(r.conditions || {}) },
      runbook_name: r.runbook_name, event_handler_id: r.event_handler_id,
      params: { ...(r.params || {}) },
      max_per_hour: r.max_per_hour, mode: r.mode, enabled: r.enabled,
      verify: r.verify, verify_after_s: r.verify_after_s, autonomy: r.autonomy,
      allow_prod: r.allow_prod, max_blast_radius: r.max_blast_radius,
      rollback_runbook: r.rollback_runbook,
    });
    this.actionKind.set(r.event_handler_id ? 'handler' : 'runbook');
    this.triggerService.set(r.match_service_name || '');
  }

  startNew(): void {
    this.isNew.set(true);
    this.selectedId.set(null);
    this.draft.set(emptyDraft());
    this.actionKind.set('handler');
  }

  cancel(): void {
    if (this.isNew()) { this.isNew.set(false); this.draft.set(null); return; }
    const r = this.rules().find((x) => x.id === this.selectedId());
    if (r) this.load(r);
  }

  patch(p: Partial<EventRuleInput>): void {
    this.draft.update((d) => (d ? { ...d, ...p } : d));
  }

  /** Switching scope clears the other targets, so a save never carries two of them — the API
   * refuses that, and leaving a stale id behind would make the refusal look arbitrary. */
  setScope(scope: 'global' | 'ou' | 'group' | 'host'): void {
    this.patch({
      scope_type: scope,
      ou_id: scope === 'ou' ? this.draft()?.ou_id ?? null : null,
      host_group_id: scope === 'group' ? this.draft()?.host_group_id ?? null : null,
      agent_id: scope === 'host' ? this.draft()?.agent_id ?? null : null,
    });
  }

  /** One action means the other half is cleared on the spot, not merely hidden. */
  setActionKind(kind: 'handler' | 'runbook'): void {
    this.actionKind.set(kind);
    if (kind === 'handler') this.patch({ runbook_name: '' });
    else this.patch({ event_handler_id: null, params: {} });
  }

  setHandler(id: string): void {
    // Values for the previous handler's parameters are dropped: they were named for a different
    // contract, and carrying them over would send variables the new handler never declared.
    this.patch({ event_handler_id: id, params: {} });
  }

  paramValue(name: string): string {
    const raw = (this.draft()?.params ?? {})[name];
    return raw === undefined || raw === null ? '' : String(raw);
  }

  setParam(name: string, value: string): void {
    this.draft.update((d) => (d ? { ...d, params: { ...d.params, [name]: value } } : d));
  }

  blocker(): string | null {
    const d = this.draft();
    if (!d) return null;
    if (!d.name.trim()) return 'A name is required.';
    if (d.scope_type === 'ou' && !d.ou_id) return 'Pick the OU this rule applies to.';
    if (d.scope_type === 'group' && !d.host_group_id) return 'Pick the host group.';
    if (d.scope_type === 'host' && !d.agent_id) return 'Pick the host.';
    if (this.actionKind() === 'handler') {
      if (!d.event_handler_id) return 'Pick the event handler to run.';
      const h = this.selectedHandler();
      const missing = (h?.parameters ?? [])
        .filter((p) => p.required && !this.paramValue(p.name).trim() && !(p.default || '').trim())
        .map((p) => p.name);
      if (missing.length) return `Required parameter(s) without a value: ${missing.join(', ')}.`;
    } else if (!d.runbook_name) {
      return 'Pick the runbook to run.';
    }
    return null;
  }

  canSave(): boolean {
    return this.blocker() === null;
  }

  save(): void {
    const d = this.draft();
    if (!d || !this.canSave()) return;
    this.saving.set(true);
    const done = (msg: string) => { this.saving.set(false); this.snack.open(msg, 'OK', { duration: 5000 }); this.reload(); };
    const fail = (err: { status?: number; error?: { detail?: string } }) => {
      this.saving.set(false);
      this.snack.open(err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`, 'OK', { duration: 10000 });
    };
    if (this.isNew()) {
      this.service.create(d).subscribe({
        next: (r) => { this.isNew.set(false); this.selectedId.set(r.id); done(`Created “${r.name}”.`); },
        error: fail,
      });
      return;
    }
    this.service.update(this.selectedId()!, d).subscribe({
      next: (r) => done(`Saved “${r.name}”.`),
      error: fail,
    });
  }

  remove(): void {
    const r = this.rules().find((x) => x.id === this.selectedId());
    if (!r) return;
    const n = this.runsOf(r.id).length;
    // The consequence is named: the runs stay (policy_id is SET NULL) and keep their `action`, so
    // the history survives — but they will no longer point at this rule.
    const msg = n
      ? `Delete “${r.name}”? Its ${n} recorded run(s) stay in the history but lose their link to this rule.`
      : `Delete “${r.name}”?`;
    const ref = this.snack.open(msg, 'Delete', { duration: 10000 });
    ref.onAction().subscribe(() => {
      this.service.delete(r.id).subscribe({
        next: () => { this.selectedId.set(null); this.draft.set(null); this.snack.open(`Deleted “${r.name}”.`, 'OK', { duration: 4000 }); this.reload(); },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 9000 }),
      });
    });
  }

  applyRun(run: EventRun): void {
    this.service.apply(run.id).subscribe({
      next: (res) => {
        this.snack.open(String(res?.['detail'] ?? 'Applied.'), 'OK', { duration: 8000 });
        this.reload();
      },
      error: (err) => this.snack.open(err?.error?.detail || 'Apply failed', 'OK', { duration: 9000 }),
    });
  }

  dismissRun(run: EventRun): void {
    this.service.dismiss(run.id).subscribe({
      next: () => { this.snack.open('Dismissed.', 'OK', { duration: 3000 }); this.reload(); },
      error: (err) => this.snack.open(err?.error?.detail || 'Dismiss failed', 'OK', { duration: 9000 }),
    });
  }

  trigger(): void {
    const host = this.triggerHost();
    const service = this.triggerService().trim();
    if (!host || !service) return;
    this.service.triggerNow(host, service).subscribe({
      next: (res) => {
        const results = (res?.['results'] as { policy?: string; status?: string; detail?: string }[]) ?? [];
        const msg = results.length
          ? results.map((r) => `${r.policy}: ${r.status}`).join(' · ')
          : 'No rule matched that host and check.';
        this.snack.open(msg, 'OK', { duration: 9000 });
        this.reload();
      },
      error: (err) => this.snack.open(err?.error?.detail || 'Trigger failed', 'OK', { duration: 9000 }),
    });
  }
}
