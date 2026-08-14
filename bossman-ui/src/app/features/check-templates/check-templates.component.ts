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
  CheckRule,
  CheckTemplate,
  CheckTemplateGroup,
  CheckTemplateInput,
  CheckTemplateLink,
  CheckTemplateRule,
} from '../../core/models/monitoring.model';
import { MonitoringService } from '../../core/services/monitoring.service';
import { HostGroup } from '../../core/models/host-group.model';
import { HostGroupService } from '../../core/services/host-group.service';

/** The comparison operators the API accepts (`_COMPARISONS` in api/templates.py),
 * with the symbol a human reads. The list is the API's, not a second opinion. */
const COMPARISONS: { value: CheckTemplateRule['comparison']; symbol: string }[] = [
  { value: 'gt', symbol: '>' },
  { value: 'lt', symbol: '<' },
  { value: 'ge', symbol: '≥' },
  { value: 'le', symbol: '≤' },
  { value: 'eq', symbol: '=' },
  { value: 'ne', symbol: '≠' },
];

function emptyRule(): CheckTemplateRule {
  return {
    service_name: '',
    metric: '',
    comparison: 'gt',
    warn_threshold: null,
    crit_threshold: null,
    label_value: null,
    max_attempts: null,
    condition_logic: 'AND',
  };
}

/** Check templates (API: /api/v1/templates, service: services/templates.py) — a named
 * bundle of check rules that can nest other templates and is *linked* to host groups.
 *
 * The subsystem existed complete and tested but had no screen, so its effect was
 * unreachable: rules could be materialized into groups with nothing to author them and
 * nothing to explain where the resulting rules came from. This is that screen.
 *
 * Three things it deliberately makes visible, because the model is causal and a
 * screen that hides the cause cannot be operated:
 *  1. EFFECTIVE rules = own rules + everything the nested templates contribute
 *     (resolved transitively, cycle-safe — the same walk services/templates.py does).
 *  2. MATERIALIZED count per link: how many real CheckRule rows this link actually
 *     produced, read back from /check-rules. That is the observation point that would
 *     falsify "the link worked" — a promise nobody can check is not a status.
 *  3. That saving re-materializes every link (and every link of templates nesting this
 *     one), i.e. the save changes what the fleet is measured against — said before the
 *     click, not discovered after it.
 *
 * Named "Check template" everywhere: the UI already has Config templates and Disk
 * images, so a bare "Templates" would name three different things. */
@Component({
  selector: 'app-check-templates',
  standalone: true,
  imports: [
    FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatSelectModule,
    MatIconModule, MatButtonModule, MatCheckboxModule,
  ],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Check templates</h1>
        <div class="bm-actions">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> New template</button>
        </div>
      </div>
      <p class="bm-subtitle">
        A reusable bundle of check rules. Linking a template to a host group <strong>creates real
        check rules</strong> scoped to that group; editing the template updates them everywhere it
        is linked. A template can nest others and then also carries their rules.
      </p>

      <div class="bm-split">
        <!-- ---------------------------------------------------------------- list -->
        <mat-card class="bm-panel bm-list">
          <mat-card-content>
            <div class="bm-count">
              <span class="bm-big">{{ templates().length }}</span> template(s)
              @if (loading()) { <span class="bm-dim">— loading…</span> }
            </div>
            @for (section of sections(); track section.name) {
              <div class="bm-sec">
                <div class="bm-sec-head">{{ section.name }}<span class="bm-sec-count">{{ section.items.length }}</span></div>
                @for (t of section.items; track t.id) {
                  <div class="bm-item" [class.bm-item-selected]="selectedId() === t.id" (click)="select(t)">
                    <div class="bm-item-name">{{ t.name }}</div>
                    <div class="bm-item-meta">
                      {{ t.rules.length }} own
                      @if (t.nested_template_ids.length) {
                        · {{ effectiveRules(t).length - t.rules.length }} nested
                      }
                      · {{ linkCount(t.id) }} group(s)
                    </div>
                  </div>
                }
              </div>
            } @empty {
              @if (!loading()) {
                <p class="bm-dim">
                  No check templates yet. A template becomes useful the moment it is linked to a
                  host group — until then it changes nothing.
                </p>
              }
            }
          </mat-card-content>
        </mat-card>

        <!-- -------------------------------------------------------------- detail -->
        <mat-card class="bm-panel bm-detail">
          <mat-card-content>
            @if (draft(); as d) {
              <div class="bm-detail-head">
                <h2>{{ isNew() ? 'New check template' : d.name }}</h2>
                @if (!isNew()) {
                  <button mat-stroked-button class="bm-danger" (click)="remove()">
                    <mat-icon>delete</mat-icon> Delete
                  </button>
                }
              </div>

              <div class="bm-fields">
                <mat-form-field appearance="outline">
                  <mat-label>Name</mat-label>
                  <input matInput [ngModel]="d.name" (ngModelChange)="patchDraft({ name: $event })" />
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>Group (optional)</mat-label>
                  <mat-select [ngModel]="d.template_group_id" (ngModelChange)="patchDraft({ template_group_id: $event })">
                    <mat-option [value]="null">— none —</mat-option>
                    @for (g of templateGroups(); track g.id) {
                      <mat-option [value]="g.id">{{ g.name }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-wide">
                  <mat-label>Description</mat-label>
                  <input matInput [ngModel]="d.description" (ngModelChange)="patchDraft({ description: $event })" />
                </mat-form-field>
              </div>

              <!-- rules -->
              <h3>Rules <span class="bm-hint">what this template measures and at which thresholds</span></h3>
              <table class="bm-table">
                <thead>
                  <tr><th>Service</th><th>Metric</th><th>Condition</th><th>Warn</th><th>Crit</th><th>Label</th><th></th></tr>
                </thead>
                <tbody>
                  @for (r of d.rules; track $index) {
                    <tr>
                      <td class="bm-mono">{{ r.service_name }}</td>
                      <td class="bm-mono">{{ r.metric }}</td>
                      <td>{{ symbolFor(r.comparison) }}</td>
                      <td class="bm-num">{{ r.warn_threshold ?? '—' }}</td>
                      <td class="bm-num">{{ r.crit_threshold ?? '—' }}</td>
                      <td class="bm-dim">{{ r.label_value || '—' }}</td>
                      <td class="bm-right">
                        <button mat-icon-button (click)="removeRule($index)" aria-label="Remove rule">
                          <mat-icon>close</mat-icon>
                        </button>
                      </td>
                    </tr>
                  }
                  @if (!d.rules.length) {
                    <tr><td colspan="7" class="bm-dim">No rules yet — this template would materialize nothing.</td></tr>
                  }
                </tbody>
              </table>

              @if (addingRule()) {
                <div class="bm-inline-form">
                  <mat-form-field appearance="outline">
                    <mat-label>Service</mat-label>
                    <input matInput [ngModel]="newRule().service_name"
                           (ngModelChange)="patchNewRule({ service_name: $event })" placeholder="cpu" />
                  </mat-form-field>
                  <mat-form-field appearance="outline">
                    <mat-label>Metric</mat-label>
                    <input matInput [ngModel]="newRule().metric"
                           (ngModelChange)="patchNewRule({ metric: $event })" placeholder="cpu_percent" />
                  </mat-form-field>
                  <mat-form-field appearance="outline" class="bm-narrow">
                    <mat-label>Condition</mat-label>
                    <mat-select [ngModel]="newRule().comparison" (ngModelChange)="patchNewRule({ comparison: $event })">
                      @for (c of comparisons; track c.value) {
                        <mat-option [value]="c.value">{{ c.symbol }} ({{ c.value }})</mat-option>
                      }
                    </mat-select>
                  </mat-form-field>
                  <mat-form-field appearance="outline" class="bm-narrow">
                    <mat-label>Warn</mat-label>
                    <input matInput type="number" [ngModel]="newRule().warn_threshold"
                           (ngModelChange)="patchNewRule({ warn_threshold: numOrNull($event) })" />
                  </mat-form-field>
                  <mat-form-field appearance="outline" class="bm-narrow">
                    <mat-label>Crit</mat-label>
                    <input matInput type="number" [ngModel]="newRule().crit_threshold"
                           (ngModelChange)="patchNewRule({ crit_threshold: numOrNull($event) })" />
                  </mat-form-field>
                  <mat-form-field appearance="outline" class="bm-narrow">
                    <mat-label>Label (optional)</mat-label>
                    <input matInput [ngModel]="newRule().label_value"
                           (ngModelChange)="patchNewRule({ label_value: $event || null })" placeholder="/var" />
                  </mat-form-field>
                  <div class="bm-inline-actions">
                    <button mat-flat-button [disabled]="!ruleComplete()" (click)="commitRule()">Add</button>
                    <button mat-button (click)="addingRule.set(false)">Cancel</button>
                  </div>
                  @if (!ruleComplete()) {
                    <p class="bm-hint bm-full">Service, metric and a warn or crit threshold are required.</p>
                  }
                </div>
              } @else {
                <button mat-stroked-button (click)="startRule()"><mat-icon>add</mat-icon> Add rule</button>
              }

              <!-- nesting -->
              <h3>Nests <span class="bm-hint">this template also carries the rules of the templates checked here</span></h3>
              @if (otherTemplates().length) {
                <div class="bm-nest">
                  @for (t of otherTemplates(); track t.id) {
                    <mat-checkbox [checked]="d.nested_template_ids.includes(t.id)" (change)="toggleNest(t.id)">
                      {{ t.name }} <span class="bm-dim">({{ t.rules.length }} rules)</span>
                    </mat-checkbox>
                  }
                </div>
              } @else {
                <p class="bm-dim">No other template to nest.</p>
              }
              <p class="bm-effective">
                Effective: <strong>{{ effectiveDraftCount() }}</strong> rule(s)
                @if (effectiveDraftCount() !== d.rules.length) {
                  <span class="bm-dim">— {{ d.rules.length }} own + {{ effectiveDraftCount() - d.rules.length }} from nested templates</span>
                }
              </p>

              <div class="bm-save-row">
                <button mat-flat-button [disabled]="!d.name.trim() || saving()" (click)="save()">
                  <mat-icon>save</mat-icon> {{ isNew() ? 'Create' : 'Save' }}
                </button>
                <button mat-button (click)="cancelDraft()">Cancel</button>
                @if (!isNew() && linkCount(selectedId()!) > 0) {
                  <span class="bm-warn-inline">
                    Saving re-creates the check rules in {{ linkCount(selectedId()!) }} linked group(s).
                  </span>
                }
              </div>

              <!-- links -->
              @if (!isNew()) {
                <h3>Linked host groups <span class="bm-hint">where these rules actually exist</span></h3>
                <table class="bm-table">
                  <thead><tr><th>Host group</th><th>Materialized check rules</th><th></th></tr></thead>
                  <tbody>
                    @for (l of links(); track l.id) {
                      <tr>
                        <td>
                          {{ l.host_group }}
                          @if (!knownGroup(l.host_group)) {
                            <span class="bm-orphan" title="No host group of this name exists — the link matches nothing">
                              unknown group
                            </span>
                          }
                        </td>
                        <td class="bm-num">
                          {{ materializedCount(l.host_group) }}
                          @if (materializedCount(l.host_group) !== effectiveSavedCount()) {
                            <span class="bm-dim">of {{ effectiveSavedCount() }} expected</span>
                          }
                        </td>
                        <td class="bm-right">
                          <button mat-stroked-button class="bm-danger" (click)="unlink(l)">
                            <mat-icon>link_off</mat-icon> Unlink
                          </button>
                        </td>
                      </tr>
                    }
                    @if (!links().length) {
                      <tr><td colspan="3" class="bm-dim">Not linked anywhere — this template currently affects nothing.</td></tr>
                    }
                  </tbody>
                </table>

                @if (linking()) {
                  <div class="bm-inline-form">
                    <mat-form-field appearance="outline">
                      <mat-label>Host group</mat-label>
                      <mat-select [ngModel]="linkGroup()" (ngModelChange)="linkGroup.set($event)">
                        @for (g of linkableGroups(); track g.id) {
                          <mat-option [value]="g.name">{{ g.name }} <span class="bm-dim">({{ g.member_agent_ids.length }} hosts)</span></mat-option>
                        }
                      </mat-select>
                    </mat-form-field>
                    <div class="bm-inline-actions">
                      <button mat-flat-button [disabled]="!linkGroup()" (click)="commitLink()">Link</button>
                      <button mat-button (click)="linking.set(false)">Cancel</button>
                    </div>
                    @if (!linkableGroups().length) {
                      <p class="bm-hint bm-full">Every host group is already linked to this template.</p>
                    }
                  </div>
                } @else {
                  <button mat-stroked-button (click)="startLink()"><mat-icon>link</mat-icon> Link a host group</button>
                }
              }
            } @else {
              <p class="bm-dim bm-empty">
                Select a template to see its rules, its nesting and the host groups it applies to —
                or create one.
              </p>
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
      .bm-subtitle { opacity: 0.7; margin-top: 4px; max-width: 900px; }
      .bm-split { display: grid; grid-template-columns: minmax(240px, 320px) 1fr; gap: 12px; margin-top: 12px; align-items: start; }
      @media (max-width: 900px) { .bm-split { grid-template-columns: 1fr; } }
      .bm-count { font-size: 15px; margin-bottom: 8px; }
      .bm-big { font-size: 28px; font-weight: 600; color: var(--bm-green); }
      .bm-sec { margin-top: 10px; }
      .bm-sec-head { font-size: 12px; font-weight: 600; opacity: 0.6; text-transform: uppercase; letter-spacing: 0.04em; display: flex; align-items: center; gap: 6px; }
      .bm-sec-count { font-size: 11px; opacity: 0.7; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); border-radius: 999px; padding: 1px 8px; }
      .bm-item { padding: 7px 10px; border-radius: 8px; cursor: pointer; }
      .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-item-selected { background: color-mix(in srgb, var(--bm-green) 14%, transparent); }
      .bm-item-name { font-weight: 500; }
      .bm-item-meta { font-size: 12px; opacity: 0.65; }
      .bm-detail-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
      .bm-detail-head h2 { margin: 0; font-size: 19px; }
      .bm-fields { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 12px; }
      .bm-fields mat-form-field { flex: 1 1 220px; }
      .bm-wide { flex: 1 1 100% !important; }
      .bm-narrow { flex: 0 0 130px !important; }
      h3 { font-size: 14px; margin: 20px 0 6px; display: flex; align-items: baseline; gap: 10px; }
      .bm-hint { font-size: 12px; font-weight: 400; opacity: 0.6; }
      .bm-full { flex-basis: 100%; margin: 0; }
      .bm-table { width: 100%; border-collapse: collapse; }
      .bm-table th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-table td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13.5px; }
      .bm-mono { font-family: monospace; }
      .bm-num { white-space: nowrap; }
      .bm-dim { opacity: 0.6; }
      .bm-right { text-align: right; }
      .bm-inline-form { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-top: 12px; padding: 12px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
      .bm-inline-form mat-form-field { flex: 1 1 170px; }
      .bm-inline-actions { display: flex; gap: 8px; }
      .bm-nest { display: flex; flex-direction: column; gap: 3px; }
      .bm-effective { margin: 10px 0 0; font-size: 13px; }
      .bm-save-row { display: flex; align-items: center; gap: 10px; margin-top: 20px; padding-top: 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-warn-inline { font-size: 12.5px; opacity: 0.75; }
      .bm-danger { color: var(--mat-sys-error); }
      .bm-orphan { margin-left: 8px; font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-error) 18%, transparent); }
      .bm-empty { padding: 28px 4px; }
    `,
  ],
})
export class CheckTemplatesComponent implements OnInit {
  private monitoring = inject(MonitoringService);
  private hostGroups = inject(HostGroupService);
  private snack = inject(MatSnackBar);

  comparisons = COMPARISONS;

  templates = signal<CheckTemplate[]>([]);
  templateGroups = signal<CheckTemplateGroup[]>([]);
  groups = signal<HostGroup[]>([]);
  /** Every link of every template — so the list can show group counts without one
   * request per row. */
  allLinks = signal<CheckTemplateLink[]>([]);
  /** All check rules, used to read back what the links actually produced. */
  checkRules = signal<CheckRule[]>([]);
  loading = signal(true);
  saving = signal(false);

  selectedId = signal<string | null>(null);
  isNew = signal(false);
  draft = signal<CheckTemplateInput | null>(null);

  addingRule = signal(false);
  newRule = signal<CheckTemplateRule>(emptyRule());
  linking = signal(false);
  linkGroup = signal<string | null>(null);

  sections = computed(() => {
    const byGroup = new Map<string, CheckTemplate[]>();
    const groupName = new Map(this.templateGroups().map((g) => [g.id, g.name]));
    for (const t of this.templates()) {
      const key = t.template_group_id ? groupName.get(t.template_group_id) ?? 'Unknown group' : 'Ungrouped';
      (byGroup.get(key) ?? byGroup.set(key, []).get(key)!).push(t);
    }
    return [...byGroup.entries()]
      .map(([name, items]) => ({ name, items: items.sort((a, b) => a.name.localeCompare(b.name)) }))
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  /** Candidates for nesting: every template except the one being edited (the API
   * refuses self-nesting with 422 — so it is not offered in the first place). */
  otherTemplates = computed(() => this.templates().filter((t) => t.id !== this.selectedId()));

  links = computed(() => this.allLinks().filter((l) => l.template_id === this.selectedId()));

  /** Host groups not yet linked to this template — the API answers 409 for a duplicate,
   * so offering one would be offering a refusal. */
  linkableGroups = computed(() => {
    const taken = new Set(this.links().map((l) => l.host_group));
    return this.groups().filter((g) => !taken.has(g.name));
  });

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.monitoring.listCheckTemplates().subscribe({
      next: (rows) => {
        this.templates.set(rows);
        this.loading.set(false);
        // Links live per template; fetch them all so counts are honest everywhere.
        this.allLinks.set([]);
        for (const t of rows) {
          this.monitoring.listCheckTemplateLinks(t.id).subscribe((ls) =>
            this.allLinks.update((cur) => [...cur.filter((l) => l.template_id !== t.id), ...ls]),
          );
        }
        const id = this.selectedId();
        if (id) {
          const again = rows.find((t) => t.id === id);
          if (again && !this.isNew()) this.loadDraft(again);
          else if (!again) { this.selectedId.set(null); this.draft.set(null); }
        }
      },
      error: () => this.loading.set(false),
    });
    this.monitoring.listCheckTemplateGroups().subscribe((g) => this.templateGroups.set(g));
    this.hostGroups.list().subscribe((g) => this.groups.set(g));
    this.monitoring.listCheckRules().subscribe((r) => this.checkRules.set(r));
  }

  select(t: CheckTemplate): void {
    this.isNew.set(false);
    this.selectedId.set(t.id);
    this.loadDraft(t);
    this.addingRule.set(false);
    this.linking.set(false);
  }

  private loadDraft(t: CheckTemplate): void {
    this.draft.set({
      name: t.name,
      description: t.description,
      template_group_id: t.template_group_id,
      // Copies, so Cancel really restores and an unsaved edit never leaks into the list.
      rules: t.rules.map((r) => ({ ...r })),
      nested_template_ids: [...t.nested_template_ids],
    });
  }

  startNew(): void {
    this.isNew.set(true);
    this.selectedId.set(null);
    this.draft.set({ name: '', description: '', template_group_id: null, rules: [], nested_template_ids: [] });
    this.addingRule.set(false);
    this.linking.set(false);
  }

  cancelDraft(): void {
    if (this.isNew()) { this.isNew.set(false); this.draft.set(null); return; }
    const t = this.templates().find((x) => x.id === this.selectedId());
    if (t) this.loadDraft(t);
  }

  patchDraft(patch: Partial<CheckTemplateInput>): void {
    this.draft.update((d) => (d ? { ...d, ...patch } : d));
  }

  patchNewRule(patch: Partial<CheckTemplateRule>): void {
    this.newRule.update((r) => ({ ...r, ...patch }));
  }

  numOrNull(v: unknown): number | null {
    if (v === '' || v === null || v === undefined) return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  startRule(): void {
    this.newRule.set(emptyRule());
    this.addingRule.set(true);
  }

  /** A rule without a threshold measures nothing, and one without service+metric has
   * nothing to measure — so "Add" stays disabled and says why, instead of producing a
   * row that would be silently useless. */
  ruleComplete(): boolean {
    const r = this.newRule();
    return !!r.service_name.trim() && !!r.metric.trim() && (r.warn_threshold !== null || r.crit_threshold !== null);
  }

  commitRule(): void {
    if (!this.ruleComplete()) return;
    const r = this.newRule();
    this.draft.update((d) => (d ? { ...d, rules: [...d.rules, { ...r }] } : d));
    this.addingRule.set(false);
  }

  removeRule(index: number): void {
    this.draft.update((d) => (d ? { ...d, rules: d.rules.filter((_, i) => i !== index) } : d));
  }

  toggleNest(id: string): void {
    this.draft.update((d) => {
      if (!d) return d;
      const has = d.nested_template_ids.includes(id);
      return {
        ...d,
        nested_template_ids: has ? d.nested_template_ids.filter((x) => x !== id) : [...d.nested_template_ids, id],
      };
    });
  }

  symbolFor(c: CheckTemplateRule['comparison']): string {
    return COMPARISONS.find((x) => x.value === c)?.symbol ?? c;
  }

  /** Own rules plus everything nested templates contribute, transitively and
   * cycle-safe — the same walk `collect_effective_rules` does on the server. Computed
   * here too so the number is visible BEFORE saving, not only afterwards. */
  effectiveRules(t: CheckTemplate): CheckTemplateRule[] {
    return this.collect(t.rules, t.nested_template_ids, new Set([t.id]));
  }

  private collect(own: CheckTemplateRule[], nestedIds: string[], seen: Set<string>): CheckTemplateRule[] {
    let out = [...own];
    for (const id of nestedIds) {
      if (seen.has(id)) continue;
      seen.add(id);
      const child = this.templates().find((t) => t.id === id);
      if (child) out = out.concat(this.collect(child.rules, child.nested_template_ids, seen));
    }
    return out;
  }

  /** The effective count of the UNSAVED draft. */
  effectiveDraftCount(): number {
    const d = this.draft();
    if (!d) return 0;
    const seen = new Set<string>();
    const id = this.selectedId();
    if (id) seen.add(id);
    return this.collect(d.rules, d.nested_template_ids, seen).length;
  }

  /** The effective count as currently SAVED — the number the materialized rows are
   * compared against, so an unsaved edit cannot make the link look wrong. */
  effectiveSavedCount(): number {
    const t = this.templates().find((x) => x.id === this.selectedId());
    return t ? this.effectiveRules(t).length : 0;
  }

  linkCount(templateId: string): number {
    return this.allLinks().filter((l) => l.template_id === templateId).length;
  }

  /** How many real check rules this template produced in that group. Read back from
   * /check-rules rather than assumed from the template — that is what makes "the link
   * worked" a checkable claim. */
  materializedCount(hostGroup: string): number {
    const id = this.selectedId();
    if (!id) return 0;
    return this.checkRules().filter((r) => r.template_id === id && r.scope_value === hostGroup).length;
  }

  knownGroup(name: string): boolean {
    return this.groups().some((g) => g.name === name);
  }

  save(): void {
    const d = this.draft();
    if (!d || !d.name.trim()) return;
    this.saving.set(true);
    const done = (msg: string) => {
      this.saving.set(false);
      this.snack.open(msg, 'OK', { duration: 4000 });
      this.reload();
    };
    const fail = (err: { error?: { detail?: string }; status?: number }) => {
      this.saving.set(false);
      this.snack.open(err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`, 'OK', { duration: 8000 });
    };
    if (this.isNew()) {
      this.monitoring.createCheckTemplate(d).subscribe({
        next: (t) => { this.isNew.set(false); this.selectedId.set(t.id); done(`Created “${t.name}”.`); },
        error: fail,
      });
    } else {
      const id = this.selectedId()!;
      this.monitoring.updateCheckTemplate(id, d).subscribe({
        next: (t) => done(`Saved “${t.name}” — check rules updated in ${this.linkCount(id)} linked group(s).`),
        error: fail,
      });
    }
  }

  remove(): void {
    const id = this.selectedId();
    const t = this.templates().find((x) => x.id === id);
    if (!id || !t) return;
    const n = this.linkCount(id);
    const msg = n
      ? `Delete “${t.name}”? This also removes the check rules it created in ${n} linked group(s).`
      : `Delete “${t.name}”?`;
    // Confirm inline in a snack bar with an explicit action: deleting cascades to real
    // check rules, so the consequence is named before it happens.
    const ref = this.snack.open(msg, 'Delete', { duration: 10000 });
    ref.onAction().subscribe(() => {
      this.monitoring.deleteCheckTemplate(id).subscribe({
        next: () => {
          this.selectedId.set(null);
          this.draft.set(null);
          this.snack.open(`Deleted “${t.name}”.`, 'OK', { duration: 4000 });
          this.reload();
        },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 8000 }),
      });
    });
  }

  startLink(): void {
    this.linkGroup.set(null);
    this.linking.set(true);
  }

  commitLink(): void {
    const id = this.selectedId();
    const group = this.linkGroup();
    if (!id || !group) return;
    this.monitoring.linkCheckTemplate(id, group).subscribe({
      next: () => {
        this.linking.set(false);
        this.snack.open(`Linked to “${group}” — its check rules now exist there.`, 'OK', { duration: 5000 });
        this.reload();
      },
      error: (err) => this.snack.open(err?.error?.detail || 'Link failed', 'OK', { duration: 8000 }),
    });
  }

  unlink(l: CheckTemplateLink): void {
    const id = this.selectedId();
    if (!id) return;
    const ref = this.snack.open(
      `Unlink “${l.host_group}”? The ${this.materializedCount(l.host_group)} check rule(s) this created there are removed.`,
      'Unlink',
      { duration: 10000 },
    );
    ref.onAction().subscribe(() => {
      this.monitoring.unlinkCheckTemplate(id, l.id).subscribe({
        next: () => { this.snack.open(`Unlinked “${l.host_group}”.`, 'OK', { duration: 4000 }); this.reload(); },
        error: (err) => this.snack.open(err?.error?.detail || 'Unlink failed', 'OK', { duration: 8000 }),
      });
    });
  }
}
