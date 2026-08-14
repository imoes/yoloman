import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatSnackBar } from '@angular/material/snack-bar';
import { SeverityLabel, ValueMap, ValueMapInput } from '../../core/models/monitoring.model';
import { MonitoringService } from '../../core/services/monitoring.service';

interface Pair { key: string; label: string }

/** How a measurement is DISPLAYED — the two catalogs that change presentation only:
 *
 *  * **Value maps** (`/api/v1/value-maps`) turn a raw value into a word: 0 -> "Down".
 *    The consumer was always live — services/monitoring.py maps the value whenever the
 *    winning check rule carries a `value_map_id` — but nothing could create a map or
 *    attach one, so the label could never appear anywhere. That is the gap this closes.
 *  * **Severity labels** (`/api/v1/severity-labels`) rename and recolour one of the four
 *    states for display (WARN -> "Degraded").
 *
 * Both live in ONE place on purpose: they answer the same question ("how is a measured
 * value shown?"), and splitting them across two screens would be two places for one task.
 * Neither touches the state machine itself — the four states are seeded by the migration
 * and cannot be created or deleted here, because renaming a state must never look like
 * inventing one. */
@Component({
  selector: 'app-measurement-display',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatIconModule, MatButtonModule],
  template: `
    <mat-card>
      <mat-card-header><mat-card-title>State names and colours</mat-card-title></mat-card-header>
      <mat-card-content>
        <p class="bm-dim bm-note">
          Display only. The four states themselves never change — a check that is CRIT stays
          CRIT, it is only labelled the way you name it here.
        </p>
        <table class="bm-tbl">
          <thead><tr><th>State</th><th>Shown as</th><th>Colour</th><th>Preview</th><th></th></tr></thead>
          <tbody>
            @for (s of severities(); track s.state) {
              <tr>
                <td class="bm-mono">{{ s.state }}</td>
                <td>
                  <input class="bm-in" [ngModel]="s.label" (ngModelChange)="patchSeverity(s.state, { label: $event })" />
                </td>
                <td>
                  <input class="bm-color" type="color" [ngModel]="s.color"
                         (ngModelChange)="patchSeverity(s.state, { color: $event })" />
                  <span class="bm-mono bm-dim">{{ s.color }}</span>
                </td>
                <td><span class="bm-chip" [style.background]="s.color">{{ s.label || s.state }}</span></td>
                <td class="bm-right">
                  <button mat-stroked-button [disabled]="!severityDirty(s.state) || !s.label.trim()"
                          (click)="saveSeverity(s.state)">Save</button>
                </td>
              </tr>
            }
            @if (!severities().length) {
              <tr><td colspan="5" class="bm-dim">
                No severity rows — they are seeded by a migration; if this stays empty the
                migration has not run.
              </td></tr>
            }
          </tbody>
        </table>
      </mat-card-content>
    </mat-card>

    <mat-card>
      <mat-card-header><mat-card-title>Value maps</mat-card-title></mat-card-header>
      <mat-card-content>
        <p class="bm-dim bm-note">
          A named list of raw value → word. Attach one to a check rule and its services show
          the word next to the number (0 → “Down”). Without a map, a value like <code>0</code>
          stays a number and the reader has to know what it means.
        </p>

        @for (vm of valueMaps(); track vm.id) {
          <div class="bm-vm" [class.bm-vm-open]="editing() === vm.id">
            <div class="bm-vm-head" (click)="toggle(vm)">
              <mat-icon>{{ editing() === vm.id ? 'expand_more' : 'chevron_right' }}</mat-icon>
              <span class="bm-vm-name">{{ vm.name }}</span>
              <span class="bm-vm-sum">{{ summarize(vm) }}</span>
            </div>
            @if (editing() === vm.id) {
              <div class="bm-vm-body">
                <mat-form-field appearance="outline" class="bm-name-field">
                  <mat-label>Name</mat-label>
                  <input matInput [ngModel]="draftName()" (ngModelChange)="draftName.set($event)" />
                </mat-form-field>
                <table class="bm-tbl bm-pairs">
                  <thead><tr><th>Raw value</th><th>Shown as</th><th></th></tr></thead>
                  <tbody>
                    @for (p of draftPairs(); track $index) {
                      <tr>
                        <td><input class="bm-in bm-mono" [ngModel]="p.key"
                                   (ngModelChange)="patchPair($index, { key: $event })" /></td>
                        <td><input class="bm-in" [ngModel]="p.label"
                                   (ngModelChange)="patchPair($index, { label: $event })" /></td>
                        <td class="bm-right">
                          <button mat-icon-button (click)="removePair($index)" aria-label="Remove mapping">
                            <mat-icon>close</mat-icon>
                          </button>
                        </td>
                      </tr>
                    }
                  </tbody>
                </table>
                <button mat-stroked-button (click)="addPair()"><mat-icon>add</mat-icon> Add mapping</button>
                @if (duplicateKey(); as dup) {
                  <p class="bm-err">
                    The raw value “{{ dup }}” is mapped twice — one value cannot show two
                    different words, so only the last would survive.
                  </p>
                }
                @if (!filledPairs().length) {
                  <p class="bm-err">At least one complete mapping is required (the API refuses an empty map).</p>
                }
                <div class="bm-vm-actions">
                  <button mat-flat-button [disabled]="!canSave()" (click)="save(vm)">
                    <mat-icon>save</mat-icon> Save
                  </button>
                  <button mat-button (click)="editing.set(null)">Cancel</button>
                  <button mat-stroked-button class="bm-danger" (click)="remove(vm)">
                    <mat-icon>delete</mat-icon> Delete
                  </button>
                </div>
              </div>
            }
          </div>
        } @empty {
          <p class="bm-dim">No value maps yet.</p>
        }

        @if (creating()) {
          <div class="bm-vm bm-vm-open">
            <div class="bm-vm-body">
              <mat-form-field appearance="outline" class="bm-name-field">
                <mat-label>Name</mat-label>
                <input matInput [ngModel]="draftName()" (ngModelChange)="draftName.set($event)"
                       placeholder="Up / Down" />
              </mat-form-field>
              <table class="bm-tbl bm-pairs">
                <thead><tr><th>Raw value</th><th>Shown as</th><th></th></tr></thead>
                <tbody>
                  @for (p of draftPairs(); track $index) {
                    <tr>
                      <td><input class="bm-in bm-mono" [ngModel]="p.key"
                                 (ngModelChange)="patchPair($index, { key: $event })" placeholder="0" /></td>
                      <td><input class="bm-in" [ngModel]="p.label"
                                 (ngModelChange)="patchPair($index, { label: $event })" placeholder="Down" /></td>
                      <td class="bm-right">
                        <button mat-icon-button (click)="removePair($index)" aria-label="Remove mapping">
                          <mat-icon>close</mat-icon>
                        </button>
                      </td>
                    </tr>
                  }
                </tbody>
              </table>
              <button mat-stroked-button (click)="addPair()"><mat-icon>add</mat-icon> Add mapping</button>
              @if (duplicateKey(); as dup) {
                <p class="bm-err">The raw value “{{ dup }}” is mapped twice.</p>
              }
              <div class="bm-vm-actions">
                <button mat-flat-button [disabled]="!canSave()" (click)="create()">
                  <mat-icon>add</mat-icon> Create
                </button>
                <button mat-button (click)="creating.set(false)">Cancel</button>
              </div>
            </div>
          </div>
        } @else {
          <button mat-flat-button (click)="startCreate()"><mat-icon>add</mat-icon> New value map</button>
        }
      </mat-card-content>
    </mat-card>
  `,
  styles: [
    `
      mat-card { margin-bottom: 16px; }
      .bm-note { margin: 0 0 12px; max-width: 720px; }
      .bm-dim { opacity: 0.65; }
      .bm-mono { font-family: monospace; }
      .bm-right { text-align: right; }
      .bm-tbl { width: 100%; border-collapse: collapse; }
      .bm-tbl th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-tbl td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-in { width: 100%; max-width: 260px; background: transparent; color: inherit; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 5px 8px; font: inherit; }
      .bm-in:focus { outline: 2px solid var(--bm-green); outline-offset: -1px; }
      .bm-color { width: 42px; height: 26px; vertical-align: middle; margin-right: 8px; background: transparent; border: none; }
      .bm-chip { display: inline-block; padding: 2px 12px; border-radius: 999px; color: #000; font-size: 12px; font-weight: 600; }
      .bm-vm { border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-vm-head { display: flex; align-items: center; gap: 8px; padding: 8px 0; cursor: pointer; user-select: none; }
      .bm-vm-name { font-weight: 500; }
      .bm-vm-sum { font-size: 12px; opacity: 0.6; font-family: monospace; }
      .bm-vm-body { padding: 4px 0 16px 30px; }
      .bm-name-field { width: 100%; max-width: 320px; }
      .bm-pairs { max-width: 560px; }
      .bm-vm-actions { display: flex; gap: 8px; margin-top: 14px; }
      .bm-danger { color: var(--mat-sys-error); margin-left: auto; }
      .bm-err { color: var(--mat-sys-error); font-size: 12.5px; margin: 8px 0 0; max-width: 560px; }
    `,
  ],
})
export class MeasurementDisplayComponent implements OnInit {
  private monitoring = inject(MonitoringService);
  private snack = inject(MatSnackBar);

  severities = signal<SeverityLabel[]>([]);
  /** The last saved state, so "Save" can be disabled while nothing differs — an enabled
   * button that would write the same value is an action without an effect. */
  private savedSeverities = signal<Record<string, SeverityLabel>>({});

  valueMaps = signal<ValueMap[]>([]);
  editing = signal<string | null>(null);
  creating = signal(false);
  draftName = signal('');
  draftPairs = signal<Pair[]>([]);

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.monitoring.listSeverityLabels().subscribe((rows) => {
      // Fixed order: the states are a scale, and showing them alphabetically (CRIT, OK,
      // UNKNOWN, WARN) would hide that.
      const order = ['OK', 'WARN', 'CRIT', 'UNKNOWN'];
      const sorted = [...rows].sort((a, b) => order.indexOf(a.state) - order.indexOf(b.state));
      this.severities.set(sorted.map((r) => ({ ...r })));
      this.savedSeverities.set(Object.fromEntries(sorted.map((r) => [r.state, { ...r }])));
    });
    this.monitoring.listValueMaps().subscribe((rows) => this.valueMaps.set(rows));
  }

  patchSeverity(state: string, patch: Partial<SeverityLabel>): void {
    this.severities.update((rows) => rows.map((r) => (r.state === state ? { ...r, ...patch } : r)));
  }

  severityDirty(state: string): boolean {
    const cur = this.severities().find((r) => r.state === state);
    const saved = this.savedSeverities()[state];
    return !!cur && !!saved && (cur.label !== saved.label || cur.color !== saved.color);
  }

  saveSeverity(state: string): void {
    const row = this.severities().find((r) => r.state === state);
    if (!row) return;
    this.monitoring.updateSeverityLabel(state, { label: row.label, color: row.color }).subscribe({
      next: (saved) => {
        this.savedSeverities.update((m) => ({ ...m, [state]: { ...saved } }));
        this.snack.open(`${state} is now shown as “${saved.label}”.`, 'OK', { duration: 4000 });
      },
      error: (err) => this.snack.open(err?.error?.detail || `Could not save ${state}`, 'OK', { duration: 8000 }),
    });
  }

  summarize(vm: ValueMap): string {
    const entries = Object.entries(vm.mappings);
    const head = entries.slice(0, 3).map(([k, v]) => `${k} → ${v}`).join(', ');
    return entries.length > 3 ? `${head}, … (${entries.length})` : head;
  }

  toggle(vm: ValueMap): void {
    if (this.editing() === vm.id) { this.editing.set(null); return; }
    this.creating.set(false);
    this.editing.set(vm.id);
    this.draftName.set(vm.name);
    this.draftPairs.set(Object.entries(vm.mappings).map(([key, label]) => ({ key, label })));
  }

  startCreate(): void {
    this.editing.set(null);
    this.creating.set(true);
    this.draftName.set('');
    this.draftPairs.set([{ key: '', label: '' }]);
  }

  addPair(): void {
    this.draftPairs.update((p) => [...p, { key: '', label: '' }]);
  }

  patchPair(index: number, patch: Partial<Pair>): void {
    this.draftPairs.update((p) => p.map((x, i) => (i === index ? { ...x, ...patch } : x)));
  }

  removePair(index: number): void {
    this.draftPairs.update((p) => p.filter((_, i) => i !== index));
  }

  filledPairs = computed(() => this.draftPairs().filter((p) => p.key.trim() !== '' && p.label.trim() !== ''));

  /** A raw value mapped twice cannot be shown two ways — the object literal would keep
   * only the last one, so the save would silently discard an entry. Named, not swallowed. */
  duplicateKey = computed(() => {
    const seen = new Set<string>();
    for (const p of this.filledPairs()) {
      const k = p.key.trim();
      if (seen.has(k)) return k;
      seen.add(k);
    }
    return null;
  });

  canSave(): boolean {
    return !!this.draftName().trim() && this.filledPairs().length > 0 && this.duplicateKey() === null;
  }

  private body(): ValueMapInput {
    return {
      name: this.draftName().trim(),
      mappings: Object.fromEntries(this.filledPairs().map((p) => [p.key.trim(), p.label.trim()])),
    };
  }

  create(): void {
    if (!this.canSave()) return;
    this.monitoring.createValueMap(this.body()).subscribe({
      next: (vm) => {
        this.creating.set(false);
        this.snack.open(`Created “${vm.name}”.`, 'OK', { duration: 4000 });
        this.reload();
      },
      error: (err) => this.snack.open(err?.error?.detail || 'Could not create the value map', 'OK', { duration: 8000 }),
    });
  }

  save(vm: ValueMap): void {
    if (!this.canSave()) return;
    this.monitoring.updateValueMap(vm.id, this.body()).subscribe({
      next: (saved) => {
        this.editing.set(null);
        this.snack.open(`Saved “${saved.name}”.`, 'OK', { duration: 4000 });
        this.reload();
      },
      error: (err) => this.snack.open(err?.error?.detail || 'Could not save the value map', 'OK', { duration: 8000 }),
    });
  }

  remove(vm: ValueMap): void {
    // The consequence is named before it happens: the DB detaches rules
    // (ON DELETE SET NULL) rather than deleting them, so monitoring keeps running and
    // only the labels disappear.
    const ref = this.snack.open(
      `Delete “${vm.name}”? Rules using it keep working and show raw values again.`,
      'Delete',
      { duration: 10000 },
    );
    ref.onAction().subscribe(() => {
      this.monitoring.deleteValueMap(vm.id).subscribe({
        next: () => { this.editing.set(null); this.snack.open(`Deleted “${vm.name}”.`, 'OK', { duration: 4000 }); this.reload(); },
        error: (err) => this.snack.open(err?.error?.detail || 'Could not delete', 'OK', { duration: 8000 }),
      });
    });
  }
}
