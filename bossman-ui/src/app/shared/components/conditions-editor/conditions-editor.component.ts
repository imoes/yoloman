import { Component, EventEmitter, Input, OnInit, Output, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { OuService } from '../../../core/services/ou.service';

/** One editor row = one Checkmk match clause. The categories mirror Checkmk's six
 * condition fields (host_tags / host_label_groups / host_name / host_folder /
 * service_description / service_label_groups); "OS" is the conventional `os`
 * host-tag group surfaced as its own category. */
type Category = 'host_tag' | 'os' | 'host_fact' | 'host_var' | 'host_group' | 'host_label' | 'host_name' | 'host_folder' | 'service_name' | 'service_label';

interface Clause {
  cat: Category;
  key: string;   // tag group / label key (unused for name/folder)
  op: string;    // is | is_not | any_of | none_of | matches | equals | not_matches | at_or_below
  value: string; // value, or comma list for any_of/none_of
}

const TAG_OPS = [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }, { v: 'any_of', label: 'is any of' }, { v: 'none_of', label: 'is none of' }];
const OPS: Record<Category, { v: string; label: string }[]> = {
  host_tag: TAG_OPS,
  host_fact: TAG_OPS,
  host_var: TAG_OPS,
  os: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  host_label: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  service_label: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  host_name: [{ v: 'matches', label: 'matches (regex)' }, { v: 'equals', label: 'equals' }, { v: 'not_matches', label: 'does not match' }],
  service_name: [{ v: 'matches', label: 'matches (regex)' }, { v: 'equals', label: 'equals' }, { v: 'not_matches', label: 'does not match' }],
  // Deliberately only any-of / none-of: a host belongs to SEVERAL groups at once, so "group is
  // webservers" would read as an exclusive claim the data cannot make. "is any of" states what is
  // actually checked — membership — and "is none of" is its honest negation (in NONE of them).
  host_group: [{ v: 'any_of', label: 'is any of' }, { v: 'none_of', label: 'is none of' }],
  host_folder: [{ v: 'at_or_below', label: 'at or below' }],
};

const CATS: { v: Category; label: string; hasKey: boolean; keyPh?: string }[] = [
  { v: 'host_tag', label: 'Host tag', hasKey: true, keyPh: 'tag group' },
  { v: 'os', label: 'OS', hasKey: false },
  { v: 'host_fact', label: 'Ansible fact', hasKey: true, keyPh: 'fact (e.g. os.family)' },
  { v: 'host_var', label: 'Variable', hasKey: true, keyPh: 'variable name' },
  { v: 'host_label', label: 'Host label', hasKey: true, keyPh: 'label key' },
  { v: 'host_name', label: 'Host name', hasKey: false },
  { v: 'host_folder', label: 'Host folder (OU)', hasKey: false },
  // 'host_group' is deliberately NOT a row here: it is the "Applies to" control at the top of the
  // editor. Offering it in both places would be two controls writing one field inside one dialog,
  // where a reader cannot tell which of them is in force.
  { v: 'service_name', label: 'Service name', hasKey: false },
  { v: 'service_label', label: 'Service label', hasKey: true, keyPh: 'label key' },
];

/**
 * Miller-row builder for Checkmk rule conditions (the match categories: tags,
 * labels, OS, host/service name, OU folder). Two-way bound via [(conditions)] to
 * the Checkmk-shaped JSON object; empty = matches everywhere. Consumed by the
 * threshold, check-assign and gpedit dialogs so a rule/policy applies only to the
 * hosts/services that match — on top of its structural scope.
 */
@Component({
  selector: 'app-conditions-editor',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule],
  template: `
    <div class="bm-cond">
      <!-- SECURITY FILTERING, the way Windows does it: a rule is linked to a scope (OU/site/global)
           and then narrowed to a set of hosts. AD narrows by security PRINCIPAL; we apply config as
           root, so there is no user identity to filter on and the equivalent lever is the host set.

           This writes conditions.host_groups — the SAME field the matcher reads. It is not a new
           column and not a second representation: "all" is that key being absent. A separate
           separate filter FIELD would have been two sources for one fact that must be kept in sync,
           which is the defect this codebase keeps paying off. The advanced list below no longer
           offers a "Host group" row for exactly that reason: one fact, one control. -->
      <div class="bm-filt">
        <span class="bm-cond-h">Applies to</span>
        <label class="bm-filt-opt">
          <input type="radio" name="bm-filt" [checked]="!groupFilter().length"
                 (change)="setFilterMode('all')" /> All hosts in scope
        </label>
        <label class="bm-filt-opt">
          <input type="radio" name="bm-filt" [checked]="groupFilter().length > 0"
                 (change)="setFilterMode('groups')" /> Only these groups
        </label>
        @if (groupFilter().length) {
          <select class="bm-cin bm-filt-neg" [ngModel]="groupFilterNegated() ? 'none' : 'any'"
                  (ngModelChange)="setFilterNegated($event === 'none')">
            <option value="any">is any of</option>
            <option value="none">is none of</option>
          </select>
          <input class="bm-cin bm-filt-val" placeholder="webservers, prod"
                 [ngModel]="groupFilter().join(', ')" (ngModelChange)="setFilterGroups($event)"
                 list="bm-filt-groups" />
          <!-- Live search over the groups the fleet actually has, so a filter is picked from what
               EXISTS instead of typed blind and silently matching nothing. -->
          <datalist id="bm-filt-groups">
            @for (g of vocab().host_groups; track g) { <option [value]="g"></option> }
          </datalist>
        }
      </div>
      <div class="bm-cond-hd">
        <span class="bm-cond-h">Advanced conditions</span>
        <span class="bm-cond-hint">{{ clauses().length ? 'Applies only where ALL of these match' : 'No conditions — applies wherever the scope reaches' }}</span>
        @if (previewScope && preview(); as p) {
          <span class="bm-cond-preview" [title]="p.matched.join(', ')">
            <mat-icon>groups</mat-icon> matches {{ p.matched_count }} of {{ p.total_in_scope }} host{{ p.total_in_scope === 1 ? '' : 's' }}
          </span>
        }
      </div>
      @for (c of clauses(); track $index) {
        <div class="bm-cond-row">
          <select class="bm-cin bm-cin-cat" [ngModel]="c.cat" (ngModelChange)="setCat($index, $event)">
            @for (cat of cats; track cat.v) { <option [value]="cat.v">{{ cat.label }}</option> }
          </select>
          @if (catOf(c.cat).hasKey) {
            <input class="bm-cin bm-cin-key" [placeholder]="catOf(c.cat).keyPh || 'key'"
                   [ngModel]="c.key" (ngModelChange)="patch($index, { key: $event })" [attr.list]="'bm-cond-keys-' + $index" />
            <!-- Live-search over known keys for this category; typing a new one
                 is accepted (it simply joins the vocabulary once a host has it). -->
            <datalist [id]="'bm-cond-keys-' + $index">
              @for (k of keySuggestions(c); track k) { <option [value]="k"></option> }
            </datalist>
          }
          <select class="bm-cin bm-cin-op" [ngModel]="c.op" (ngModelChange)="patch($index, { op: $event })">
            @for (o of OPS[c.cat]; track o.v) { <option [value]="o.v">{{ o.label }}</option> }
          </select>
          <input class="bm-cin bm-cin-val"
                 [placeholder]="valuePlaceholder(c)"
                 [ngModel]="c.value" (ngModelChange)="patch($index, { value: $event })"
                 [attr.list]="'bm-cond-vals-' + $index" />
          <!-- Values auto-complete from the chosen key, so a tag/fact/variable
               fills in its own known values. -->
          <datalist [id]="'bm-cond-vals-' + $index">
            @for (v of valueSuggestions(c); track v) { <option [value]="v"></option> }
          </datalist>
          <button mat-icon-button class="bm-cond-del" (click)="remove($index)" title="Remove condition"><mat-icon>close</mat-icon></button>
        </div>
      }
      <button mat-stroked-button class="bm-cond-add" (click)="add()"><mat-icon>add</mat-icon> Add condition</button>
    </div>
  `,
  styles: [`
    .bm-cond { margin-top: 6px; display: flex; flex-direction: column; gap: 8px; }
    .bm-filt { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding-bottom: 8px;
      border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-filt-opt { display: flex; align-items: center; gap: 5px; font-size: 12.5px; cursor: pointer; }
    .bm-filt-neg { max-width: 8.5rem; }
    .bm-filt-val { min-width: 14rem; flex: 1; }
    .bm-cond-hd { display: flex; align-items: baseline; gap: 10px; }
    .bm-cond-h { font-size: 12px; font-weight: 600; opacity: 0.8; }
    .bm-cond-hint { font-size: 11.5px; opacity: 0.6; }
    .bm-cond-preview { display: inline-flex; align-items: center; gap: 4px; margin-left: auto; font-size: 12px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-tertiary) 18%, transparent); cursor: default; }
    .bm-cond-preview mat-icon { font-size: 15px; width: 15px; height: 15px; }
    .bm-cond-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
    .bm-cin { padding: 6px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 12.5px; box-sizing: border-box; }
    .bm-cin-cat { flex: 0 0 140px; }
    .bm-cin-key { flex: 0 0 130px; }
    .bm-cin-op { flex: 0 0 130px; }
    .bm-cin-val { flex: 1 1 150px; min-width: 120px; }
    .bm-cond-del { flex: 0 0 auto; }
    .bm-cond-add { align-self: flex-start; }
  `],
})
export class ConditionsEditorComponent implements OnInit {
  private ouService = inject(OuService);
  OPS = OPS;
  cats = CATS;

  // Last object we emitted, so an echoed [conditions] input doesn't reset the rows
  // mid-edit (the parent binds our own output straight back).
  private lastEmitted = '';
  @Input() set conditions(v: Record<string, unknown> | null | undefined) {
    const json = JSON.stringify(v || {});
    if (json === this.lastEmitted) return;
    this.clauses.set(this.deserialize(v || {}));
  }
  @Output() conditionsChange = new EventEmitter<Record<string, unknown>>();
  // Optional: when the host authoring this policy knows its scope, show a live
  // "matches N of M hosts" blast-radius preview via /whatif/scope.
  @Input() previewScope?: { scope_type: string; ou_id?: string; host_group_id?: string; site_id?: string; agent_id?: string };
  preview = signal<{ total_in_scope: number; matched_count: number; matched: string[] } | null>(null);
  private previewTimer: ReturnType<typeof setTimeout> | null = null;

  clauses = signal<Clause[]>([]);
  vocab = signal<{
    host_tags: Record<string, string[]>;
    host_facts: Record<string, string[]>;
    variables: Record<string, string[]>;
    host_labels: Record<string, string[]>;
    ou_folders: string[];
    host_groups: string[];
  }>({ host_tags: {}, host_facts: {}, variables: {}, host_labels: {}, ou_folders: [], host_groups: [] });

  // --- "Applies to" (Security Filtering) ---------------------------------------------------------
  // Held as its OWN state rather than as a clause in the list, because it is a different question:
  // the scope says where a rule lives, this says which hosts inside it are in force, and the
  // advanced conditions refine on top. It still serialises into conditions.host_groups — one field,
  // read by rule_conditions, so "all" is simply that key being absent.
  groupFilter = signal<string[]>([]);
  groupFilterNegated = signal(false);

  setFilterMode(mode: 'all' | 'groups'): void {
    // Switching to "all" CLEARS the list instead of remembering it: a filter that is not in force
    // must not be sitting in the object, or the next reader cannot tell whether it applies.
    if (mode === 'all') {
      this.groupFilter.set([]);
      this.groupFilterNegated.set(false);
    } else if (!this.groupFilter().length) {
      this.groupFilter.set(['']);   // an empty row so the input appears and can be typed into
    }
    this.emit();
  }

  setFilterGroups(csv: string): void {
    this.groupFilter.set(csv.split(',').map((x) => x.trim()).filter(Boolean));
    this.emit();
  }

  setFilterNegated(negated: boolean): void {
    this.groupFilterNegated.set(negated);
    this.emit();
  }

  ngOnInit(): void {
    this.ouService.matchVocabulary().subscribe({ next: (v) => this.vocab.set(v), error: () => {} });
    this.refreshPreview(this.serialize(this.clauses()));
  }

  /** Debounced blast-radius preview for the current conditions at previewScope. */
  private refreshPreview(conditions: Record<string, unknown>): void {
    if (!this.previewScope) return;
    if (this.previewTimer) clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => {
      this.ouService.whatifScope({ ...this.previewScope!, conditions }).subscribe({
        next: (r) => this.preview.set(r),
        error: () => this.preview.set(null),
      });
    }, 300);
  }

  catOf(cat: Category) { return CATS.find((c) => c.v === cat)!; }

  /** Live-search suggestions for the KEY input, by category. */
  keySuggestions(c: Clause): string[] {
    const v = this.vocab();
    switch (c.cat) {
      case 'host_tag': return Object.keys(v.host_tags).filter((g) => g !== 'os');
      case 'host_fact': return Object.keys(v.host_facts);
      case 'host_var': return Object.keys(v.variables);
      case 'host_label':
      case 'service_label': return Object.keys(v.host_labels);
      default: return [];
    }
  }

  /** Live-search suggestions for the VALUE input, derived from the chosen key so
   * a tag/fact/variable auto-fills its own known values. */
  valueSuggestions(c: Clause): string[] {
    const v = this.vocab();
    switch (c.cat) {
      case 'os': return v.host_tags['os'] || [];
      case 'host_tag': return v.host_tags[c.key] || [];
      case 'host_fact': return v.host_facts[c.key] || [];
      case 'host_var': return v.variables[c.key] || [];
      case 'host_label':
      case 'service_label': return v.host_labels[c.key] || [];
      case 'host_folder': return v.ou_folders;
      // The live search for groups: every group name the fleet has, filtered client-side as
      // you type, so a condition is picked from what EXISTS instead of typed blind and
      // silently matching nothing.
      case 'host_group': return v.host_groups;
      default: return [];
    }
  }

  valuePlaceholder(c: Clause): string {
    if (c.op === 'any_of' || c.op === 'none_of') return 'value1, value2, …';
    if (c.cat === 'host_name' || c.cat === 'service_name') return c.op === 'equals' ? 'exact name' : '^regex';
    if (c.cat === 'host_folder') return '/OU/path';
    return 'value';
  }

  add(): void {
    this.clauses.update((cs) => [...cs, { cat: 'host_tag', key: '', op: 'is', value: '' }]);
    this.emit();
  }
  remove(i: number): void {
    this.clauses.update((cs) => cs.filter((_, idx) => idx !== i));
    this.emit();
  }
  patch(i: number, delta: Partial<Clause>): void {
    this.clauses.update((cs) => cs.map((c, idx) => (idx === i ? { ...c, ...delta } : c)));
    this.emit();
  }
  setCat(i: number, cat: Category): void {
    // Reset op to the new category's first valid operator; clear key when the
    // new category has none.
    this.clauses.update((cs) => cs.map((c, idx) => idx === i
      ? { ...c, cat, op: OPS[cat][0].v, key: this.catOf(cat).hasKey ? c.key : '' } : c));
    this.emit();
  }

  private emit(): void {
    const obj = this.serialize(this.clauses());
    this.lastEmitted = JSON.stringify(obj);
    this.conditionsChange.emit(obj);
    this.refreshPreview(obj);
  }

  // --- serialize: clauses → Checkmk conditions object ---
  private serialize(clauses: Clause[]): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    const hostTags: Record<string, unknown> = {};
    const hostFacts: Record<string, unknown> = {};
    const hostVars: Record<string, unknown> = {};
    const hostLabelMembers: [string, string][] = [];
    const svcLabelMembers: [string, string][] = [];
    let hostNames: unknown[] | null = null;
    let hostNameNeg = false;
    let svcNames: unknown[] | null = null;
    let svcNameNeg = false;

    const nameEntry = (op: string, v: string) => (op === 'equals' ? v : { $regex: v });
    const list = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean);
    // is / is-not / any-of / none-of → the tag-condition grammar (shared by
    // host_tags, host_facts and host_vars).
    const tagCond = (op: string, v: string) => op === 'is_not' ? { $ne: v }
      : op === 'any_of' ? { $or: list(v) }
      : op === 'none_of' ? { $nor: list(v) }
      : v;

    for (const c of clauses) {
      const v = (c.value || '').trim();
      if (!v && c.cat !== 'host_folder') continue;
      switch (c.cat) {
        case 'host_tag':
        case 'os': {
          const group = c.cat === 'os' ? 'os' : (c.key || '').trim();
          if (group) hostTags[group] = tagCond(c.op, v);
          break;
        }
        case 'host_fact':
          if (c.key) hostFacts[c.key.trim()] = tagCond(c.op, v);
          break;
        case 'host_var':
          if (c.key) hostVars[c.key.trim()] = tagCond(c.op, v);
          break;
        case 'host_label':
          if (c.key) hostLabelMembers.push([c.op === 'is_not' ? 'not' : 'and', `${c.key.trim()}:${v}`]);
          break;
        case 'service_label':
          if (c.key) svcLabelMembers.push([c.op === 'is_not' ? 'not' : 'and', `${c.key.trim()}:${v}`]);
          break;
        case 'host_name':
          hostNames = hostNames || [];
          hostNames.push(nameEntry(c.op, v));
          if (c.op === 'not_matches') hostNameNeg = true;
          break;
        case 'service_name':
          svcNames = svcNames || [];
          svcNames.push(nameEntry(c.op, v));
          if (c.op === 'not_matches') svcNameNeg = true;
          break;
        case 'host_group':
          // A comma list, same as any_of elsewhere. none_of wraps the WHOLE list in $nor, which the
          // backend reads as "in none of these" — see rule_conditions._matches_any_name for why the
          // negation has to apply to the set rather than per value.
        case 'host_folder':
          if (v) out['host_folder'] = v;
          break;
      }
    }
    if (Object.keys(hostTags).length) out['host_tags'] = hostTags;
    if (Object.keys(hostFacts).length) out['host_facts'] = hostFacts;
    if (Object.keys(hostVars).length) out['host_vars'] = hostVars;
    if (hostLabelMembers.length) out['host_label_groups'] = [['and', hostLabelMembers]];
    if (svcLabelMembers.length) out['service_label_groups'] = [['and', svcLabelMembers]];
    // From the "Applies to" control, not from a clause. An empty list means "all hosts in scope",
    // which is the key being ABSENT — not an empty array, which rule_conditions would also treat as
    // "matches everything" but which would leave a meaningless key in the stored object.
    const filt = this.groupFilter().filter(Boolean);
    if (filt.length) out['host_groups'] = this.groupFilterNegated() ? { $nor: filt } : filt;
    if (hostNames) out['host_name'] = hostNameNeg ? { $nor: hostNames } : hostNames;
    if (svcNames) out['service_description'] = svcNameNeg ? { $nor: svcNames } : svcNames;
    return out;
  }

  // --- deserialize: Checkmk conditions object → clauses ---
  private deserialize(cond: Record<string, unknown>): Clause[] {
    const out: Clause[] = [];
    // host_tags (os split out), host_facts, host_vars all share the tag grammar.
    this.deserializeTagMap(cond['host_tags'], (k) => (k === 'os' ? 'os' : 'host_tag'), out);
    this.deserializeTagMap(cond['host_facts'], () => 'host_fact', out);
    this.deserializeTagMap(cond['host_vars'], () => 'host_var', out);
    this.deserializeLabels(cond['host_label_groups'], 'host_label', out);
    this.deserializeLabels(cond['service_label_groups'], 'service_label', out);
    this.deserializeNames(cond['host_name'], 'host_name', out);
    this.deserializeNames(cond['service_description'], 'service_name', out);
    if (cond['host_folder']) out.push({ cat: 'host_folder', key: '', op: 'at_or_below', value: String(cond['host_folder']) });
    // host_groups feeds the "Applies to" control, not the clause list. A bare list is any-of, a
    // $nor wrapper is none-of; the negation belongs to the WHOLE list ("in none of these"), which is
    // why it is one control and not one row per group.
    const hg = cond['host_groups'];
    if (Array.isArray(hg)) {
      this.groupFilter.set(hg.map(String));
      this.groupFilterNegated.set(false);
    } else if (hg && typeof hg === 'object' && '$nor' in (hg as Record<string, unknown>)) {
      this.groupFilter.set((((hg as Record<string, unknown>)['$nor'] as unknown[]) || []).map(String));
      this.groupFilterNegated.set(true);
    } else {
      this.groupFilter.set([]);
      this.groupFilterNegated.set(false);
    }
    return out;
  }

  /** Deserialize a {key: tag-condition} map (host_tags / host_facts / host_vars)
   * into clauses; `catFor` picks the category per key (host_tags splits out os). */
  private deserializeTagMap(map: unknown, catFor: (key: string) => Category, out: Clause[]): void {
    if (!map || typeof map !== 'object') return;
    for (const [key, c] of Object.entries(map as Record<string, unknown>)) {
      const cat = catFor(key);
      if (c && typeof c === 'object') {
        const o = c as Record<string, unknown>;
        if ('$ne' in o) out.push({ cat, key, op: 'is_not', value: String(o['$ne']) });
        else if ('$or' in o) out.push({ cat, key, op: 'any_of', value: (o['$or'] as unknown[]).join(', ') });
        else if ('$nor' in o) out.push({ cat, key, op: 'none_of', value: (o['$nor'] as unknown[]).join(', ') });
      } else {
        out.push({ cat, key, op: 'is', value: String(c) });
      }
    }
  }

  private deserializeLabels(groups: unknown, cat: 'host_label' | 'service_label', out: Clause[]): void {
    if (!Array.isArray(groups)) return;
    for (const g of groups) {
      const members = Array.isArray(g) && g.length === 2 ? g[1] : g;
      if (!Array.isArray(members)) continue;
      for (const m of members) {
        if (!Array.isArray(m) || m.length !== 2) continue;
        const [op, kv] = m;
        const [key, ...rest] = String(kv).split(':');
        out.push({ cat, key, op: op === 'not' ? 'is_not' : 'is', value: rest.join(':') });
      }
    }
  }

  private deserializeNames(field: unknown, cat: 'host_name' | 'service_name', out: Clause[]): void {
    if (field == null) return;
    let neg = false;
    let entries: unknown[];
    if (!Array.isArray(field) && typeof field === 'object' && '$nor' in (field as object)) {
      neg = true;
      entries = ((field as Record<string, unknown>)['$nor'] as unknown[]) || [];
    } else {
      entries = Array.isArray(field) ? field : [field];
    }
    for (const e of entries) {
      if (e && typeof e === 'object' && '$regex' in (e as object)) {
        out.push({ cat, key: '', op: neg ? 'not_matches' : 'matches', value: String((e as Record<string, unknown>)['$regex']) });
      } else {
        out.push({ cat, key: '', op: neg ? 'not_matches' : 'equals', value: String(e) });
      }
    }
  }
}
