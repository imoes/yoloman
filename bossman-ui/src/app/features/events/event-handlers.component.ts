import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatSnackBar } from '@angular/material/snack-bar';
import {
  EventHandler,
  EventHandlerInput,
  HandlerAvailability,
  HandlerMeta,
  HandlerParameter,
} from '../../core/models/event-handler.model';
import { EventHandlerService } from '../../core/services/event-handler.service';
import { WizardService } from '../../core/services/wizard.service';

function emptyDraft(): EventHandlerInput {
  return {
    name: '', description: '', body: 'script', location: 'managed',
    runbook_name: null, interpreter: 'bash',
    source: '#!/bin/bash\n# $BOSSMAN_EVENT_HOST, $BOSSMAN_EVENT_SERVICE and $BOSSMAN_EVENT_STATE\n# are always set; declared parameters arrive as $BOSSMAN_<NAME>.\n',
    local_name: null, parameters: [], timeout_s: 300, enabled: true,
  };
}

/** Event handlers — the reusable ACTION an event rule performs (docs/event-handling.md).
 *
 * A handler is a runbook, or a script that Bossman manages and deploys, or a script that already
 * sits in the agent's own directory. The trigger is elsewhere and unchanged: a check entering a
 * hard problem state, matched by an event rule, which then runs the handler.
 *
 * Three things this screen exists to make visible:
 *
 *  1. **Why a local handler has no parameters.** The server serves that sentence
 *     (`HandlerMeta.local_no_parameters_reason`) and it is SHOWN, not merely implied by a
 *     disabled field: Bossman does not have the script's contents, so it cannot describe
 *     parameters, and a form for values it cannot describe would promise an unverifiable effect.
 *  2. **Whether a local handler's file is actually there.** Its body is outside Bossman, so
 *     "this will run" is untested until the event fires. `/availability` answers it per host in
 *     four named states — a host where it is missing is a row, never an omission.
 *  3. **That script handlers need a current agent.** An older agent ignores the environment
 *     silently, so the run would report success with an empty context; the server refuses such a
 *     run and this screen says so up front rather than letting it be discovered in an audit row.
 *
 * The legal bodies, locations and interpreters come from the API. Repeating them here would be a
 * second source of truth that drifts the moment either side gains one.
 */
@Component({
  selector: 'app-event-handlers',
  standalone: true,
  imports: [
    FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatSelectModule,
    MatIconModule, MatButtonModule, MatCheckboxModule,
  ],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Event handlers</h1>
        <div class="bm-actions">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> New handler</button>
        </div>
      </div>
      <p class="bm-subtitle">
        What an event rule <strong>does</strong> when a check goes bad: run a runbook, or run a
        script — one Bossman keeps and deploys, or one that already lives on the host in
        <code>{{ meta()?.handler_dir || '/etc/agentic-mcp/event-handlers' }}</code>. Bossman is
        always the trigger; only the body can live elsewhere.
      </p>

      <div class="bm-split">
        <mat-card class="bm-panel">
          <mat-card-content>
            <div class="bm-count">
              <span class="bm-big">{{ handlers().length }}</span> handler(s)
              @if (loading()) { <span class="bm-dim">— loading…</span> }
            </div>
            @for (h of handlers(); track h.id) {
              <div class="bm-item" [class.bm-item-selected]="selectedId() === h.id" (click)="select(h)">
                <div class="bm-item-name">
                  {{ h.name }}
                  @if (!h.enabled) { <span class="bm-chip">disabled</span> }
                </div>
                <div class="bm-item-meta">
                  {{ h.body }}@if (h.body === 'script') { · {{ h.location }} }
                  @if (h.parameters.length) { · {{ h.parameters.length }} param(s) }
                  @if (h.used_by_rules) { · {{ h.used_by_rules }} rule(s) }
                </div>
              </div>
            } @empty {
              @if (!loading()) {
                <p class="bm-dim">
                  No handlers yet. A handler is only run by an event rule — on its own it changes
                  nothing.
                </p>
              }
            }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-panel">
          <mat-card-content>
            @if (draft(); as d) {
              <div class="bm-detail-head">
                <h2>{{ isNew() ? 'New event handler' : d.name }}</h2>
                @if (!isNew()) {
                  <button mat-stroked-button class="bm-danger" (click)="remove()">
                    <mat-icon>delete</mat-icon> Delete
                  </button>
                }
              </div>

              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Name</mat-label>
                  <input matInput [ngModel]="d.name" (ngModelChange)="patch({ name: $event })"
                         placeholder="restart-unit" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Description</mat-label>
                  <input matInput [ngModel]="d.description" (ngModelChange)="patch({ description: $event })" />
                </mat-form-field>
              </div>

              <!-- body + location -->
              <h3>What runs</h3>
              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Body</mat-label>
                  <mat-select [ngModel]="d.body" (ngModelChange)="setBody($event)">
                    @for (b of meta()?.bodies || []; track b) {
                      <mat-option [value]="b">{{ b }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                @if (d.body === 'script') {
                  <mat-form-field appearance="outline">
                    <mat-label>Where the body lives</mat-label>
                    <mat-select [ngModel]="d.location" (ngModelChange)="setLocation($event)">
                      @for (l of meta()?.locations || []; track l) {
                        <mat-option [value]="l">{{ l === 'managed' ? 'managed by Bossman' : 'already on the host' }}</mat-option>
                      }
                    </mat-select>
                  </mat-form-field>
                }
              </div>
              @if (d.body === 'runbook') {
                <p class="bm-note">
                  A runbook is a document in Bossman's database, so it cannot live on a host —
                  “already on the host” is not offered for it.
                </p>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Runbook</mat-label>
                  <mat-select [ngModel]="d.runbook_name" (ngModelChange)="patch({ runbook_name: $event })">
                    @for (r of runbooks(); track r) {
                      <mat-option [value]="r">{{ r }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
              }

              @if (d.body === 'script' && d.location === 'managed') {
                <div class="bm-fields">
                  <mat-form-field appearance="outline">
                    <mat-label>Interpreter</mat-label>
                    <mat-select [ngModel]="d.interpreter" (ngModelChange)="patch({ interpreter: $event })">
                      @for (i of meta()?.interpreters || []; track i) {
                        <mat-option [value]="i">{{ i }}</mat-option>
                      }
                    </mat-select>
                  </mat-form-field>
                  <mat-form-field appearance="outline" class="bm-narrow">
                    <mat-label>Timeout (s)</mat-label>
                    <input matInput type="number" [ngModel]="d.timeout_s"
                           (ngModelChange)="patch({ timeout_s: +$event })" />
                  </mat-form-field>
                </div>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Script</mat-label>
                  <textarea matInput rows="10" class="bm-code" [ngModel]="d.source"
                            (ngModelChange)="patch({ source: $event })"></textarea>
                </mat-form-field>
                <p class="bm-note">
                  <!-- No literal angle brackets inside the template: Angular parses them as a tag. -->
                  Deployed to <code>{{ handlerDir() }}/{{ d.name || '…' }}</code> (mode 0700)
                  <strong>before every run</strong> — so a host can never hold an older version
                  than the one shown here.
                </p>
              }

              @if (d.body === 'script' && d.location === 'local') {
                <mat-form-field appearance="outline">
                  <mat-label>File name in {{ handlerDir() }}</mat-label>
                  <input matInput [ngModel]="d.local_name" (ngModelChange)="patch({ local_name: $event })"
                         placeholder="cleanup.sh" />
                </mat-form-field>
                <p class="bm-note bm-why">
                  <mat-icon inline>info</mat-icon>
                  <span><strong>No parameters for this kind of handler.</strong>
                  {{ meta()?.local_no_parameters_reason }}</span>
                </p>
              }

              <!-- parameters -->
              @if (parametersPossible()) {
                <h3>Parameters <span class="bm-hint">configured here in Bossman, passed as BOSSMAN_&lt;NAME&gt;</span></h3>
                @if (d.parameters.length) {
                  <table class="bm-table">
                    <thead><tr><th>Name</th><th>Type</th><th>Default</th><th>Required</th><th>Variable</th><th></th></tr></thead>
                    <tbody>
                      @for (p of d.parameters; track $index; let pi = $index) {
                        <tr>
                          <td><input class="bm-in" [ngModel]="p.name" (ngModelChange)="patchParam(pi, { name: $event })" /></td>
                          <td>
                            <select class="bm-in bm-sel" [ngModel]="p.type" (ngModelChange)="patchParam(pi, { type: $event })">
                              <option value="string">string</option>
                              <option value="number">number</option>
                              <option value="boolean">boolean</option>
                            </select>
                          </td>
                          <td><input class="bm-in" [ngModel]="p.default" (ngModelChange)="patchParam(pi, { default: $event })" /></td>
                          <td><mat-checkbox [checked]="p.required" (change)="patchParam(pi, { required: !p.required })"></mat-checkbox></td>
                          <td class="bm-mono bm-dim">{{ envName(p.name) }}</td>
                          <td class="bm-right">
                            <button mat-icon-button (click)="removeParam(pi)" aria-label="Remove parameter">
                              <mat-icon>close</mat-icon>
                            </button>
                          </td>
                        </tr>
                      }
                    </tbody>
                  </table>
                }
                <button mat-stroked-button (click)="addParam()"><mat-icon>add</mat-icon> Add parameter</button>
                <p class="bm-note">
                  Every declared parameter reaches the script, falling back to its default and then
                  to an empty value — an unset variable and an empty one are different failures for
                  a script, and only one of them is what you meant. The event context
                  (<code>BOSSMAN_EVENT_HOST</code>, <code>_SERVICE</code>, <code>_STATE</code>,
                  <code>_VALUE</code>) is always passed on top.
                </p>
              }

              <mat-checkbox [checked]="d.enabled" (change)="patch({ enabled: !d.enabled })">Enabled</mat-checkbox>

              <div class="bm-save-row">
                <button mat-flat-button [disabled]="!canSave() || saving()" (click)="save()">
                  <mat-icon>save</mat-icon> {{ isNew() ? 'Create' : 'Save' }}
                </button>
                <button mat-button (click)="cancel()">Cancel</button>
                @if (blocker(); as b) { <span class="bm-dim">{{ b }}</span> }
              </div>

              <!-- availability: only meaningful for a local body -->
              @if (!isNew() && d.body === 'script' && d.location === 'local') {
                <h3>
                  Is the file there?
                  <span class="bm-hint">its body is not in Bossman, so this is the only way to know before the event</span>
                </h3>
                <div class="bm-avail-row">
                  <button mat-stroked-button [disabled]="checking()" (click)="checkAvailability()">
                    <mat-icon>travel_explore</mat-icon> {{ checking() ? 'Checking…' : 'Check every host' }}
                  </button>
                  @if (availability(); as a) {
                    <span class="bm-avail-sum" [class.bm-avail-bad]="a.present_on === 0">
                      present on {{ a.present_on }} of {{ a.checked }} host(s)
                    </span>
                  }
                </div>
                @if (availability(); as a) {
                  <table class="bm-table">
                    <thead><tr><th>Host</th><th>State</th><th>Detail</th></tr></thead>
                    <tbody>
                      @for (h of a.hosts; track h.agent_id) {
                        <tr>
                          <td>{{ h.host }}</td>
                          <td><span class="bm-state bm-{{ h.state }}">{{ h.state }}</span></td>
                          <td class="bm-dim">{{ h.detail }}</td>
                        </tr>
                      }
                    </tbody>
                  </table>
                }
              }

              @if (!isNew() && d.body === 'script') {
                <p class="bm-note bm-why">
                  <mat-icon inline>warning</mat-icon>
                  <span>A script handler needs an agent that can pass environment variables. On an
                  older agent the run is <strong>refused</strong> with that reason rather than
                  executed with an empty context — the alternative would report success for the
                  wrong work.</span>
                </p>
              }
            } @else {
              <p class="bm-dim bm-empty">Select a handler, or create one.</p>
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
      .bm-item { padding: 7px 10px; border-radius: 8px; cursor: pointer; }
      .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-item-selected { background: color-mix(in srgb, var(--bm-green) 14%, transparent); }
      .bm-item-name { font-weight: 500; }
      .bm-item-meta { font-size: 12px; opacity: 0.65; }
      .bm-chip { margin-left: 8px; font-size: 11px; padding: 1px 8px; border-radius: 999px;
                 background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .bm-detail-head h2 { margin: 0; font-size: 19px; }
      .bm-fields { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 10px; }
      .bm-fields mat-form-field { flex: 1 1 220px; }
      .bm-wide { width: 100%; }
      .bm-narrow { flex: 0 0 130px !important; }
      h3 { font-size: 14px; margin: 20px 0 6px; display: flex; align-items: baseline; gap: 10px; }
      .bm-hint { font-size: 12px; font-weight: 400; opacity: 0.6; }
      .bm-note { font-size: 12.5px; opacity: 0.75; margin: 6px 0 0; max-width: 860px; }
      .bm-why { display: flex; gap: 8px; align-items: flex-start; opacity: 1;
                background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent);
                border-radius: 8px; padding: 10px 12px; }
      .bm-code { font-family: monospace; font-size: 12.5px; }
      .bm-table { width: 100%; border-collapse: collapse; max-width: 900px; }
      .bm-table th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-table td { padding: 4px 12px 4px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
      .bm-in { width: 100%; max-width: 200px; background: transparent; color: inherit; font: inherit;
               font-size: 12.5px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 4px 6px; }
      .bm-sel { max-width: 120px; }
      .bm-mono { font-family: monospace; font-size: 12px; }
      .bm-dim { opacity: 0.62; }
      .bm-right { text-align: right; }
      .bm-save-row { display: flex; align-items: center; gap: 10px; margin-top: 18px; padding-top: 14px;
                     border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-danger { color: var(--mat-sys-error); }
      .bm-empty { padding: 28px 4px; }
      .bm-avail-row { display: flex; align-items: center; gap: 12px; margin-bottom: 6px; }
      .bm-avail-sum { font-size: 13px; }
      .bm-avail-bad { color: var(--mat-sys-error); }
      .bm-state { font-size: 11px; font-weight: 700; padding: 1px 9px; border-radius: 999px; }
      .bm-present { background: color-mix(in srgb, var(--bm-green) 28%, transparent); }
      .bm-missing { background: color-mix(in srgb, var(--mat-sys-error) 26%, transparent); }
      .bm-unreachable { background: color-mix(in srgb, #ffc800 30%, transparent); }
      .bm-unknown { background: color-mix(in srgb, var(--mat-sys-on-surface) 15%, transparent); }
    `,
  ],
})
export class EventHandlersComponent implements OnInit {
  private service = inject(EventHandlerService);
  private wizard = inject(WizardService);
  private snack = inject(MatSnackBar);

  handlers = signal<EventHandler[]>([]);
  meta = signal<HandlerMeta | null>(null);
  runbooks = signal<string[]>([]);
  loading = signal(true);
  saving = signal(false);
  checking = signal(false);
  availability = signal<HandlerAvailability | null>(null);

  selectedId = signal<string | null>(null);
  isNew = signal(false);
  draft = signal<EventHandlerInput | null>(null);

  handlerDir = computed(() => this.meta()?.handler_dir ?? '/etc/agentic-mcp/event-handlers');

  /** Parameters exist for everything except a local script — see the reason the server serves. */
  parametersPossible = computed(() => {
    const d = this.draft();
    return !!d && !(d.body === 'script' && d.location === 'local');
  });

  ngOnInit(): void {
    this.service.meta().subscribe((m) => this.meta.set(m));
    // The DB runbooks, not the file-based plans: a handler's body resolves by name against the
    // Runbook table (api/event_handlers validates exactly that). Roles are filtered out because
    // a role cannot be a handler body — the service would answer "missing or is a role".
    this.wizard.listRunbooks().subscribe({
      next: (r) => this.runbooks.set(
        (r.runbooks || []).filter((x) => (x.kind || 'runbook') !== 'role').map((x) => x.name).sort(),
      ),
      error: () => this.runbooks.set([]),
    });
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.service.list().subscribe({
      next: (rows) => {
        this.handlers.set(rows);
        this.loading.set(false);
        const id = this.selectedId();
        const again = rows.find((h) => h.id === id);
        if (id && again && !this.isNew()) this.load(again);
        else if (id && !again) { this.selectedId.set(null); this.draft.set(null); }
      },
      error: () => this.loading.set(false),
    });
  }

  select(h: EventHandler): void {
    this.isNew.set(false);
    this.selectedId.set(h.id);
    this.availability.set(null);
    this.load(h);
  }

  private load(h: EventHandler): void {
    this.draft.set({
      name: h.name, description: h.description, body: h.body, location: h.location,
      runbook_name: h.runbook_name, interpreter: h.interpreter, source: h.source,
      local_name: h.local_name, parameters: h.parameters.map((p) => ({ ...p })),
      timeout_s: h.timeout_s, enabled: h.enabled,
    });
  }

  startNew(): void {
    this.isNew.set(true);
    this.selectedId.set(null);
    this.availability.set(null);
    this.draft.set(emptyDraft());
  }

  cancel(): void {
    if (this.isNew()) { this.isNew.set(false); this.draft.set(null); return; }
    const h = this.handlers().find((x) => x.id === this.selectedId());
    if (h) this.load(h);
  }

  patch(p: Partial<EventHandlerInput>): void {
    this.draft.update((d) => (d ? { ...d, ...p } : d));
  }

  /** Switching body clears what the other body cannot carry, so a save never sends a shape the
   * schema forbids — and a runbook is forced back to `managed`, because it cannot be local. */
  setBody(body: 'runbook' | 'script'): void {
    this.draft.update((d) => {
      if (!d) return d;
      if (body === 'runbook') {
        return { ...d, body, location: 'managed', interpreter: null, source: null, local_name: null };
      }
      return { ...d, body, runbook_name: null, interpreter: d.interpreter || 'bash', source: d.source || emptyDraft().source };
    });
  }

  setLocation(location: 'managed' | 'local'): void {
    this.draft.update((d) => {
      if (!d) return d;
      if (location === 'local') {
        // Parameters are dropped rather than kept hidden: the server refuses them for a local
        // handler, and keeping them out of sight would make Save fail for an invisible reason.
        return { ...d, location, interpreter: null, source: null, parameters: [] };
      }
      return { ...d, location, local_name: null, interpreter: d.interpreter || 'bash', source: d.source || emptyDraft().source };
    });
  }

  envName(name: string): string {
    return 'BOSSMAN_' + (name || '').trim().toUpperCase().replace(/[^A-Z0-9_]/g, '_');
  }

  addParam(): void {
    this.draft.update((d) =>
      d ? { ...d, parameters: [...d.parameters, { name: '', type: 'string', default: null, description: '', required: false }] } : d,
    );
  }

  patchParam(index: number, p: Partial<HandlerParameter>): void {
    this.draft.update((d) =>
      d ? { ...d, parameters: d.parameters.map((x, i) => (i === index ? { ...x, ...p } : x)) } : d,
    );
  }

  removeParam(index: number): void {
    this.draft.update((d) => (d ? { ...d, parameters: d.parameters.filter((_, i) => i !== index) } : d));
  }

  /** Why saving is impossible right now — shown beside the disabled button, so the operator is
   * never left guessing which field the server will object to. */
  blocker(): string | null {
    const d = this.draft();
    if (!d) return null;
    if (!d.name.trim()) return 'A name is required.';
    if (d.body === 'runbook' && !d.runbook_name) return 'Pick the runbook to run.';
    if (d.body === 'script' && d.location === 'managed') {
      if (!d.interpreter) return 'Pick an interpreter.';
      if (!(d.source || '').trim()) return 'The script text is the handler — it cannot be empty.';
    }
    if (d.body === 'script' && d.location === 'local' && !(d.local_name || '').trim()) {
      return `Name the file inside ${this.handlerDir()}.`;
    }
    const unnamed = d.parameters.some((p) => !p.name.trim());
    if (unnamed) return 'Every parameter needs a name.';
    const names = d.parameters.map((p) => p.name.trim());
    if (new Set(names).size !== names.length) return 'Two parameters share a name.';
    return null;
  }

  canSave(): boolean {
    return this.blocker() === null;
  }

  save(): void {
    const d = this.draft();
    if (!d || !this.canSave()) return;
    this.saving.set(true);
    const fail = (err: { status?: number; error?: { detail?: string } }) => {
      this.saving.set(false);
      const msg =
        err?.status === 412
          ? 'Someone else changed this handler while you were editing. Reload to see their version — your edit was not applied.'
          : err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`;
      this.snack.open(msg, 'OK', { duration: 10000 });
    };
    if (this.isNew()) {
      this.service.create(d).subscribe({
        next: (h) => {
          this.saving.set(false);
          this.isNew.set(false);
          this.selectedId.set(h.id);
          this.snack.open(`Created “${h.name}”. An event rule has to point at it before it runs.`, 'OK', { duration: 6000 });
          this.reload();
        },
        error: fail,
      });
      return;
    }
    const current = this.handlers().find((h) => h.id === this.selectedId());
    this.service.update(this.selectedId()!, d, current?.version ?? '').subscribe({
      next: (h) => {
        this.saving.set(false);
        const n = current?.used_by_rules ?? 0;
        this.snack.open(
          n ? `Saved “${h.name}” — ${n} event rule(s) use it.` : `Saved “${h.name}”.`,
          'OK', { duration: 5000 },
        );
        this.reload();
      },
      error: fail,
    });
  }

  remove(): void {
    const h = this.handlers().find((x) => x.id === this.selectedId());
    if (!h) return;
    if (h.used_by_rules) {
      // Named before the attempt: the API refuses this, and saying so here spares a pointless
      // round trip and a confusing 409.
      this.snack.open(
        `${h.used_by_rules} event rule(s) still use “${h.name}” — point them elsewhere first, or deleting it would leave a rule that fires and does nothing.`,
        'OK', { duration: 9000 },
      );
      return;
    }
    const ref = this.snack.open(`Delete “${h.name}”?`, 'Delete', { duration: 10000 });
    ref.onAction().subscribe(() => {
      this.service.delete(h.id).subscribe({
        next: () => {
          this.selectedId.set(null);
          this.draft.set(null);
          this.snack.open(`Deleted “${h.name}”.`, 'OK', { duration: 4000 });
          this.reload();
        },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 9000 }),
      });
    });
  }

  checkAvailability(): void {
    const id = this.selectedId();
    if (!id) return;
    this.checking.set(true);
    this.service.availability(id).subscribe({
      next: (a) => { this.checking.set(false); this.availability.set(a); },
      error: (err) => {
        this.checking.set(false);
        this.snack.open(err?.error?.detail || 'Could not check availability', 'OK', { duration: 9000 });
      },
    });
  }
}
