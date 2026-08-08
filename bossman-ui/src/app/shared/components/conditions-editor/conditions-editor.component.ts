import { Component, EventEmitter, Input, OnInit, Output, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { OuService } from '../../../core/services/ou.service';

/** One editor row = one Checkmk match clause. The categories mirror Checkmk's six
 * condition fields (host_tags / host_label_groups / host_name / host_folder /
 * service_description / service_label_groups); "OS" is the conventional `os`
 * host-tag group surfaced as its own category. */
type Category = 'host_tag' | 'os' | 'host_label' | 'host_name' | 'host_folder' | 'service_name' | 'service_label';

interface Clause {
  cat: Category;
  key: string;   // tag group / label key (unused for name/folder)
  op: string;    // is | is_not | any_of | none_of | matches | equals | not_matches | at_or_below
  value: string; // value, or comma list for any_of/none_of
}

const OPS: Record<Category, { v: string; label: string }[]> = {
  host_tag: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }, { v: 'any_of', label: 'is any of' }, { v: 'none_of', label: 'is none of' }],
  os: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  host_label: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  service_label: [{ v: 'is', label: 'is' }, { v: 'is_not', label: 'is not' }],
  host_name: [{ v: 'matches', label: 'matches (regex)' }, { v: 'equals', label: 'equals' }, { v: 'not_matches', label: 'does not match' }],
  service_name: [{ v: 'matches', label: 'matches (regex)' }, { v: 'equals', label: 'equals' }, { v: 'not_matches', label: 'does not match' }],
  host_folder: [{ v: 'at_or_below', label: 'at or below' }],
};

const CATS: { v: Category; label: string; hasKey: boolean }[] = [
  { v: 'host_tag', label: 'Host tag', hasKey: true },
  { v: 'os', label: 'OS', hasKey: false },
  { v: 'host_label', label: 'Host label', hasKey: true },
  { v: 'host_name', label: 'Host name', hasKey: false },
  { v: 'host_folder', label: 'Host folder (OU)', hasKey: false },
  { v: 'service_name', label: 'Service name', hasKey: false },
  { v: 'service_label', label: 'Service label', hasKey: true },
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
      <div class="bm-cond-hd">
        <span class="bm-cond-h">Conditions</span>
        <span class="bm-cond-hint">{{ clauses().length ? 'Applies only where ALL of these match' : 'No conditions — applies wherever the scope reaches' }}</span>
      </div>
      @for (c of clauses(); track $index) {
        <div class="bm-cond-row">
          <select class="bm-cin bm-cin-cat" [ngModel]="c.cat" (ngModelChange)="setCat($index, $event)">
            @for (cat of cats; track cat.v) { <option [value]="cat.v">{{ cat.label }}</option> }
          </select>
          @if (catOf(c.cat).hasKey) {
            <input class="bm-cin bm-cin-key" [placeholder]="c.cat === 'host_tag' ? 'tag group' : 'label key'"
                   [ngModel]="c.key" (ngModelChange)="patch($index, { key: $event })" [attr.list]="'bm-cond-keys-' + c.cat" />
          }
          <select class="bm-cin bm-cin-op" [ngModel]="c.op" (ngModelChange)="patch($index, { op: $event })">
            @for (o of OPS[c.cat]; track o.v) { <option [value]="o.v">{{ o.label }}</option> }
          </select>
          <input class="bm-cin bm-cin-val"
                 [placeholder]="valuePlaceholder(c)"
                 [ngModel]="c.value" (ngModelChange)="patch($index, { value: $event })"
                 [attr.list]="valueListId(c)" />
          <button mat-icon-button class="bm-cond-del" (click)="remove($index)" title="Remove condition"><mat-icon>close</mat-icon></button>
        </div>
      }
      <button mat-stroked-button class="bm-cond-add" (click)="add()"><mat-icon>add</mat-icon> Add condition</button>

      <!-- Suggestion lists (free text still allowed). -->
      <datalist id="bm-cond-keys-host_tag">@for (g of tagGroups(); track g) { <option [value]="g"></option> }</datalist>
      <datalist id="bm-cond-keys-host_label">@for (k of labelKeys(); track k) { <option [value]="k"></option> }</datalist>
      <datalist id="bm-cond-keys-service_label">@for (k of labelKeys(); track k) { <option [value]="k"></option> }</datalist>
      <datalist id="bm-cond-os">@for (v of osValues(); track v) { <option [value]="v"></option> }</datalist>
      <datalist id="bm-cond-folders">@for (p of vocab().ou_folders; track p) { <option [value]="p"></option> }</datalist>
    </div>
  `,
  styles: [`
    .bm-cond { margin-top: 6px; display: flex; flex-direction: column; gap: 8px; }
    .bm-cond-hd { display: flex; align-items: baseline; gap: 10px; }
    .bm-cond-h { font-size: 12px; font-weight: 600; opacity: 0.8; }
    .bm-cond-hint { font-size: 11.5px; opacity: 0.6; }
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

  clauses = signal<Clause[]>([]);
  vocab = signal<{ host_tags: Record<string, string[]>; host_labels: Record<string, string[]>; ou_folders: string[] }>(
    { host_tags: {}, host_labels: {}, ou_folders: [] });

  ngOnInit(): void {
    this.ouService.matchVocabulary().subscribe({ next: (v) => this.vocab.set(v), error: () => {} });
  }

  catOf(cat: Category) { return CATS.find((c) => c.v === cat)!; }
  tagGroups(): string[] { return Object.keys(this.vocab().host_tags).filter((g) => g !== 'os'); }
  labelKeys(): string[] { return Object.keys(this.vocab().host_labels); }
  osValues(): string[] { return this.vocab().host_tags['os'] || []; }

  valuePlaceholder(c: Clause): string {
    if (c.op === 'any_of' || c.op === 'none_of') return 'value1, value2, …';
    if (c.cat === 'host_name' || c.cat === 'service_name') return c.op === 'equals' ? 'exact name' : '^regex';
    if (c.cat === 'host_folder') return '/OU/path';
    return 'value';
  }
  valueListId(c: Clause): string | null {
    if (c.cat === 'os') return 'bm-cond-os';
    if (c.cat === 'host_folder') return 'bm-cond-folders';
    return null;
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
  }

  // --- serialize: clauses → Checkmk conditions object ---
  private serialize(clauses: Clause[]): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    const hostTags: Record<string, unknown> = {};
    const hostLabelMembers: [string, string][] = [];
    const svcLabelMembers: [string, string][] = [];
    let hostNames: unknown[] | null = null;
    let hostNameNeg = false;
    let svcNames: unknown[] | null = null;
    let svcNameNeg = false;

    const nameEntry = (op: string, v: string) => (op === 'equals' ? v : { $regex: v });
    const list = (s: string) => s.split(',').map((x) => x.trim()).filter(Boolean);

    for (const c of clauses) {
      const v = (c.value || '').trim();
      if (!v && c.cat !== 'host_folder') continue;
      switch (c.cat) {
        case 'host_tag':
        case 'os': {
          const group = c.cat === 'os' ? 'os' : (c.key || '').trim();
          if (!group) break;
          hostTags[group] = c.op === 'is_not' ? { $ne: v }
            : c.op === 'any_of' ? { $or: list(v) }
            : c.op === 'none_of' ? { $nor: list(v) }
            : v;
          break;
        }
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
        case 'host_folder':
          if (v) out['host_folder'] = v;
          break;
      }
    }
    if (Object.keys(hostTags).length) out['host_tags'] = hostTags;
    if (hostLabelMembers.length) out['host_label_groups'] = [['and', hostLabelMembers]];
    if (svcLabelMembers.length) out['service_label_groups'] = [['and', svcLabelMembers]];
    if (hostNames) out['host_name'] = hostNameNeg ? { $nor: hostNames } : hostNames;
    if (svcNames) out['service_description'] = svcNameNeg ? { $nor: svcNames } : svcNames;
    return out;
  }

  // --- deserialize: Checkmk conditions object → clauses ---
  private deserialize(cond: Record<string, unknown>): Clause[] {
    const out: Clause[] = [];
    const tags = (cond['host_tags'] as Record<string, unknown>) || {};
    for (const [group, c] of Object.entries(tags)) {
      const isOs = group === 'os';
      if (c && typeof c === 'object') {
        const o = c as Record<string, unknown>;
        if ('$ne' in o) out.push({ cat: isOs ? 'os' : 'host_tag', key: group, op: 'is_not', value: String(o['$ne']) });
        else if ('$or' in o) out.push({ cat: 'host_tag', key: group, op: 'any_of', value: (o['$or'] as unknown[]).join(', ') });
        else if ('$nor' in o) out.push({ cat: 'host_tag', key: group, op: 'none_of', value: (o['$nor'] as unknown[]).join(', ') });
      } else {
        out.push({ cat: isOs ? 'os' : 'host_tag', key: group, op: 'is', value: String(c) });
      }
    }
    this.deserializeLabels(cond['host_label_groups'], 'host_label', out);
    this.deserializeLabels(cond['service_label_groups'], 'service_label', out);
    this.deserializeNames(cond['host_name'], 'host_name', out);
    this.deserializeNames(cond['service_description'], 'service_name', out);
    if (cond['host_folder']) out.push({ cat: 'host_folder', key: '', op: 'at_or_below', value: String(cond['host_folder']) });
    return out;
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
