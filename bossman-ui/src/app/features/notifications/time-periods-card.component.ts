import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatSnackBar } from '@angular/material/snack-bar';
import { TimePeriod, TimePeriodInput, TimePeriodUsage } from '../../core/models/notification.model';
import { NotificationService } from '../../core/services/notification.service';

const WEEKDAYS = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'] as const;
type Weekday = (typeof WEEKDAYS)[number];

interface Span { start: string; end: string }
interface ExceptionRow { date: string; closed: boolean; spans: Span[] }

function emptyDraft(): TimePeriodInput {
  return { name: '', alias: '', ranges: {}, exceptions: {}, excludes: [] };
}

/** Time periods (api/time_periods.py, evaluator services/time_periods.py — a port of
 * Checkmk's is_timeperiod_active): reusable "when" objects for notification rules.
 *
 * The consumer was live all along — `time_period_blocks` in services/notification.py decides
 * whether a rule fires, and the rule dialog already offered the choice — but only the
 * built-in `24x7` existed, because nothing could create a period. "Page only during business
 * hours" was therefore unreachable. This is the missing half.
 *
 * What the screen has to make visible:
 *  1. WHICH clock a window is read in, and whether it is open RIGHT NOW (`timezone`,
 *     `active_now`). A window read in the wrong zone is off by the local offset and that is
 *     invisible from the definition alone.
 *  2. What a change would affect, BEFORE the change: /usage lists the notification rules
 *     using this window and the periods excluding it.
 *  3. Why an overnight span is refused. The validator rejects an end at or before the start
 *     (22:00-02:00 would be a window that never matches), so the form says so instead of
 *     letting the operator collect a 422.
 *  4. That built-ins cannot be renamed or deleted — the controls are disabled with the
 *     reason, not the refusal replayed afterwards. */
@Component({
  selector: 'app-time-periods-card',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatFormFieldModule, MatInputModule, MatIconModule, MatButtonModule, MatCheckboxModule],
  template: `
    <mat-card>
      <mat-card-header>
        <mat-card-title>Notification windows</mat-card-title>
      </mat-card-header>
      <mat-card-content>
        <p class="bm-note">
          A reusable “when” for notification rules. A rule with a window only fires while that
          window is open; a rule without one fires around the clock. Windows are read in
          <strong>{{ zone() || 'the server clock' }}</strong>.
        </p>

        <table class="bm-tbl">
          <thead><tr><th>Window</th><th>Open now</th><th>Days</th><th>Used by</th><th></th></tr></thead>
          <tbody>
            @for (p of periods(); track p.id) {
              <tr class="bm-row" [class.bm-sel]="editingId() === p.id" (click)="edit(p)">
                <td>
                  {{ p.name }}
                  @if (p.alias) { <span class="bm-dim"> — {{ p.alias }}</span> }
                  @if (p.is_builtin) { <span class="bm-chip">built-in</span> }
                </td>
                <td>
                  <span class="bm-state" [class.bm-on]="p.active_now">{{ p.active_now ? 'open' : 'closed' }}</span>
                </td>
                <td class="bm-dim">{{ daySummary(p) }}</td>
                <td class="bm-dim">{{ usageSummary(p.id) }}</td>
                <td class="bm-right">
                  <button mat-icon-button [disabled]="p.is_builtin"
                          [title]="p.is_builtin ? 'A built-in window cannot be deleted' : 'Delete'"
                          (click)="remove(p); $event.stopPropagation()">
                    <mat-icon>delete</mat-icon>
                  </button>
                </td>
              </tr>
            }
          </tbody>
        </table>

        @if (draft(); as d) {
          <div class="bm-editor">
            <h4>{{ editingId() ? 'Edit window' : 'New window' }}</h4>
            <div class="bm-row2">
              <mat-form-field appearance="outline">
                <mat-label>Name</mat-label>
                <input matInput [ngModel]="d.name" (ngModelChange)="patch({ name: $event })"
                       [disabled]="!!renameBlocked()" placeholder="business-hours" />
              </mat-form-field>
              <mat-form-field appearance="outline">
                <mat-label>Description</mat-label>
                <input matInput [ngModel]="d.alias" (ngModelChange)="patch({ alias: $event })"
                       placeholder="Mon–Fri 08:00–17:00" />
              </mat-form-field>
            </div>
            @if (renameBlocked(); as why) { <p class="bm-note bm-warn">{{ why }}</p> }

            <h5>Weekly hours</h5>
            @for (day of weekdays; track day) {
              <div class="bm-day">
                <span class="bm-day-name">{{ day }}</span>
                <div class="bm-spans">
                  @for (s of spansOf(day); track $index; let si = $index) {
                    <span class="bm-span">
                      <input type="time" [ngModel]="s.start" (ngModelChange)="setSpan(day, si, { start: $event })" />
                      –
                      <!-- An input[type=time] cannot hold 24:00 (the browser clears it), but the
                           API needs exactly that for "to end of day" - so end-of-day is its own
                           control instead of a value the field cannot express. Found by testing:
                           typing 24:00 produced "not a HH:MM time: ''". -->
                      @if (s.end === '24:00') {
                        <span class="bm-eod">midnight</span>
                      } @else {
                        <input type="time" [ngModel]="s.end" (ngModelChange)="setSpan(day, si, { end: $event })" />
                      }
                      <mat-checkbox class="bm-eod-box" [checked]="s.end === '24:00'"
                                    (change)="toggleEndOfDay(day, si)">to midnight</mat-checkbox>
                      <button mat-icon-button (click)="removeSpan(day, si)" aria-label="Remove span">
                        <mat-icon>close</mat-icon>
                      </button>
                    </span>
                  }
                  <button mat-stroked-button class="bm-mini" (click)="addSpan(day)">
                    <mat-icon>add</mat-icon> hours
                  </button>
                  @if (!spansOf(day).length) { <span class="bm-dim">closed</span> }
                </div>
              </div>
            }
            @if (badSpans().length) {
              <p class="bm-note bm-warn">
                {{ badSpans().join('; ') }} — a window must end after it starts. There are no
                overnight spans: split 22:00–02:00 into 22:00–24:00 and 00:00–02:00 on the next day.
              </p>
            }

            <h5>Date exceptions <span class="bm-dim">override the weekly hours for one date</span></h5>
            <!-- The outer index is ALIASED as ri: inside the nested @for, $index refers to
                 the INNER loop, so passing it twice would edit another row's span. (No
                 backticks in here - they would end the component's template literal.) -->
            @for (ex of exceptions(); track $index; let ri = $index) {
              <div class="bm-day">
                <input class="bm-date" type="date" [ngModel]="ex.date"
                       (ngModelChange)="setException(ri, { date: $event })" />
                <mat-checkbox [checked]="ex.closed" (change)="toggleExceptionClosed(ri)">closed all day</mat-checkbox>
                @if (!ex.closed) {
                  <div class="bm-spans">
                    @for (s of ex.spans; track $index; let si = $index) {
                      <span class="bm-span">
                        <input type="time" [ngModel]="s.start" (ngModelChange)="setExceptionSpan(ri, si, { start: $event })" />
                        –
                        <input type="time" [ngModel]="s.end" (ngModelChange)="setExceptionSpan(ri, si, { end: $event })" />
                        <button mat-icon-button (click)="removeExceptionSpan(ri, si)" aria-label="Remove span">
                          <mat-icon>close</mat-icon>
                        </button>
                      </span>
                    }
                    <button mat-stroked-button class="bm-mini" (click)="addExceptionSpan(ri)">
                      <mat-icon>add</mat-icon> hours
                    </button>
                  </div>
                }
                <button mat-icon-button (click)="removeException(ri)" aria-label="Remove exception">
                  <mat-icon>close</mat-icon>
                </button>
              </div>
            }
            <button mat-stroked-button (click)="addException()"><mat-icon>add</mat-icon> Add a date</button>

            @if (excludeCandidates().length) {
              <h5>Excluded by these windows <span class="bm-dim">while one of them is open, this window is closed</span></h5>
              <div class="bm-excl">
                @for (other of excludeCandidates(); track other.id) {
                  <mat-checkbox [checked]="d.excludes.includes(other.name)" (change)="toggleExclude(other.name)">
                    {{ other.name }}
                    <span class="bm-dim">{{ other.active_now ? '(open now)' : '' }}</span>
                  </mat-checkbox>
                }
              </div>
            }

            @if (usage(); as u) {
              <p class="bm-note">
                @if (u.notification_rules.length) {
                  Changing this window changes when
                  <strong>{{ u.notification_rules.length }} notification rule(s)</strong> fire:
                  {{ ruleNames(u) }}.
                } @else {
                  No notification rule uses this window yet, so a change affects nothing today.
                }
                @if (u.excluded_by.length) {
                  It is excluded by: {{ u.excluded_by.join(', ') }} — it therefore cannot be renamed or deleted.
                }
              </p>
            }

            <div class="bm-actions">
              <button mat-flat-button [disabled]="!canSave()" (click)="save()">
                <mat-icon>save</mat-icon> {{ editingId() ? 'Save' : 'Create' }}
              </button>
              <button mat-button (click)="cancel()">Cancel</button>
              @if (blocker(); as b) { <span class="bm-dim">{{ b }}</span> }
            </div>
          </div>
        } @else {
          <button mat-flat-button (click)="startNew()"><mat-icon>add</mat-icon> New window</button>
        }
      </mat-card-content>
    </mat-card>
  `,
  styles: [
    `
      .bm-note { font-size: 12.5px; opacity: 0.75; margin: 0 0 12px; max-width: 820px; }
      .bm-warn { color: var(--mat-sys-error); opacity: 1; }
      .bm-dim { opacity: 0.6; }
      .bm-right { text-align: right; }
      .bm-tbl { width: 100%; border-collapse: collapse; }
      .bm-tbl th { text-align: left; font-size: 12px; font-weight: 500; opacity: 0.6; padding: 3px 12px 3px 0; }
      .bm-tbl td { padding: 5px 12px 5px 0; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13.5px; }
      .bm-row { cursor: pointer; }
      .bm-row:hover td { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
      .bm-sel td { background: color-mix(in srgb, var(--bm-green) 12%, transparent); }
      .bm-chip { margin-left: 8px; font-size: 11px; padding: 1px 8px; border-radius: 999px;
                 background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-state { font-size: 11px; font-weight: 700; padding: 1px 9px; border-radius: 999px;
                  background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-state.bm-on { background: color-mix(in srgb, var(--bm-green) 28%, transparent); }
      .bm-editor { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-editor h4 { margin: 0 0 10px; font-size: 15px; }
      .bm-editor h5 { margin: 16px 0 6px; font-size: 13px; display: flex; gap: 10px; align-items: baseline; font-weight: 600; }
      .bm-row2 { display: flex; gap: 10px; flex-wrap: wrap; }
      .bm-row2 mat-form-field { flex: 1 1 240px; }
      .bm-day { display: flex; align-items: center; gap: 10px; padding: 3px 0; flex-wrap: wrap; }
      .bm-day-name { width: 92px; font-size: 12.5px; text-transform: capitalize; opacity: 0.8; }
      .bm-spans { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
      .bm-span { display: inline-flex; align-items: center; gap: 4px; font-size: 12.5px; }
      input[type='time'], .bm-date { background: transparent; color: inherit; font: inherit; font-size: 12.5px;
                                     border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 3px 6px; }
      .bm-eod { font-size: 12.5px; padding: 3px 8px; border-radius: 6px;
                background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-eod-box { font-size: 11.5px; }
      .bm-mini { font-size: 11px !important; min-height: 28px !important; line-height: 26px !important; }
      .bm-excl { display: flex; flex-direction: column; gap: 2px; }
      .bm-actions { display: flex; align-items: center; gap: 10px; margin-top: 18px; }
    `,
  ],
})
export class TimePeriodsCardComponent implements OnInit {
  private notifications = inject(NotificationService);
  private snack = inject(MatSnackBar);

  readonly weekdays = WEEKDAYS;

  periods = signal<TimePeriod[]>([]);
  usageById = signal<Record<string, TimePeriodUsage>>({});
  editingId = signal<string | null>(null);
  draft = signal<TimePeriodInput | null>(null);
  exceptions = signal<ExceptionRow[]>([]);
  saving = signal(false);

  zone = computed(() => this.periods()[0]?.timezone ?? '');
  usage = computed(() => {
    const id = this.editingId();
    return id ? this.usageById()[id] ?? null : null;
  });
  /** Other periods that may be listed under `excludes`. Self-exclusion is refused by the
   * API (422), so it is not offered. */
  excludeCandidates = computed(() => this.periods().filter((p) => p.id !== this.editingId()));

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.notifications.timePeriods().subscribe((rows) => {
      this.periods.set(rows);
      for (const p of rows) {
        this.notifications
          .timePeriodUsage(p.id)
          .subscribe((u) => this.usageById.update((m) => ({ ...m, [p.id]: u })));
      }
      const id = this.editingId();
      const again = rows.find((p) => p.id === id);
      if (id && again) this.load(again);
      else if (id && !again) { this.editingId.set(null); this.draft.set(null); }
    });
  }

  daySummary(p: TimePeriod): string {
    const open = WEEKDAYS.filter((d) => (p.ranges[d] ?? []).length > 0);
    if (open.length === 7) return 'every day';
    if (!open.length) return 'no weekly hours';
    return open.map((d) => d.slice(0, 3)).join(', ');
  }

  /** Angular templates have no arrow functions, so the join lives here. */
  ruleNames(u: TimePeriodUsage): string {
    return u.notification_rules.map((r) => r.name).join(', ');
  }

  usageSummary(id: string): string {
    const u = this.usageById()[id];
    if (!u) return '';
    const n = u.notification_rules.length;
    return n ? `${n} rule(s)` : '—';
  }

  edit(p: TimePeriod): void {
    this.editingId.set(p.id);
    this.load(p);
  }

  private load(p: TimePeriod): void {
    this.draft.set({
      name: p.name,
      alias: p.alias,
      ranges: JSON.parse(JSON.stringify(p.ranges ?? {})),
      exceptions: JSON.parse(JSON.stringify(p.exceptions ?? {})),
      excludes: [...(p.excludes ?? [])],
    });
    this.exceptions.set(
      Object.entries(p.exceptions ?? {}).map(([date, spans]) => ({
        date,
        // An EMPTY span list is the API's way of saying "closed all day" — surfaced as a
        // checkbox, because an empty row would otherwise read as "not filled in yet".
        closed: (spans ?? []).length === 0,
        spans: (spans ?? []).map(([start, end]) => ({ start, end })),
      })),
    );
  }

  startNew(): void {
    this.editingId.set(null);
    this.draft.set(emptyDraft());
    this.exceptions.set([]);
  }

  cancel(): void {
    const id = this.editingId();
    const p = id ? this.periods().find((x) => x.id === id) : null;
    if (p) this.load(p);
    else { this.draft.set(null); this.editingId.set(null); }
  }

  patch(p: Partial<TimePeriodInput>): void {
    this.draft.update((d) => (d ? { ...d, ...p } : d));
  }

  /** Renaming is refused for a built-in, and for any period another one excludes (excludes
   * reference by NAME, so a rename would dangle them). Disabled with the reason rather than
   * letting the save come back 409. */
  renameBlocked(): string | null {
    const id = this.editingId();
    if (!id) return null;
    const p = this.periods().find((x) => x.id === id);
    if (p?.is_builtin) return 'A built-in window cannot be renamed.';
    const by = this.usageById()[id]?.excluded_by ?? [];
    return by.length ? `Cannot be renamed while excluded by: ${by.join(', ')}.` : null;
  }

  spansOf(day: Weekday): Span[] {
    const raw = this.draft()?.ranges[day] ?? [];
    return raw.map(([start, end]) => ({ start, end }));
  }

  private writeSpans(day: Weekday, spans: Span[]): void {
    this.draft.update((d) => {
      if (!d) return d;
      const ranges = { ...d.ranges };
      if (spans.length) ranges[day] = spans.map((s) => [s.start, s.end]);
      else delete ranges[day];
      return { ...d, ranges };
    });
  }

  addSpan(day: Weekday): void {
    this.writeSpans(day, [...this.spansOf(day), { start: '08:00', end: '17:00' }]);
  }

  setSpan(day: Weekday, index: number, patch: Partial<Span>): void {
    this.writeSpans(
      day,
      this.spansOf(day).map((s, i) => (i === index ? { ...s, ...patch } : s)),
    );
  }

  /** 24:00 is the API's end-of-day and input[type=time] cannot represent it, so it is set
   * through this toggle rather than typed. Unchecking falls back to 23:00 — a concrete
   * editable value, not an empty field that would fail validation as "not a HH:MM time". */
  toggleEndOfDay(day: Weekday, index: number): void {
    const current = this.spansOf(day)[index];
    this.setSpan(day, index, { end: current?.end === '24:00' ? '23:00' : '24:00' });
  }

  removeSpan(day: Weekday, index: number): void {
    this.writeSpans(day, this.spansOf(day).filter((_, i) => i !== index));
  }

  /** Every span whose end is at or before its start. The validator refuses these; naming them
   * here (with the split hint in the template) keeps the operator out of a 422. */
  badSpans(): string[] {
    const out: string[] = [];
    const d = this.draft();
    if (!d) return out;
    for (const day of WEEKDAYS) {
      for (const [start, end] of d.ranges[day] ?? []) {
        if (start && end && end <= start) out.push(`${day} ${start}–${end}`);
      }
    }
    for (const ex of this.exceptions()) {
      if (ex.closed) continue;
      for (const s of ex.spans) {
        if (s.start && s.end && s.end <= s.start) out.push(`${ex.date} ${s.start}–${s.end}`);
      }
    }
    return out;
  }

  addException(): void {
    this.exceptions.update((rows) => [...rows, { date: '', closed: true, spans: [] }]);
  }

  setException(index: number, patch: Partial<ExceptionRow>): void {
    this.exceptions.update((rows) => rows.map((r, i) => (i === index ? { ...r, ...patch } : r)));
  }

  toggleExceptionClosed(index: number): void {
    this.exceptions.update((rows) =>
      rows.map((r, i) =>
        i === index
          ? { ...r, closed: !r.closed, spans: r.closed ? [{ start: '08:00', end: '17:00' }] : [] }
          : r,
      ),
    );
  }

  addExceptionSpan(index: number): void {
    this.exceptions.update((rows) =>
      rows.map((r, i) => (i === index ? { ...r, spans: [...r.spans, { start: '08:00', end: '17:00' }] } : r)),
    );
  }

  setExceptionSpan(rowIndex: number, spanIndex: number, patch: Partial<Span>): void {
    this.exceptions.update((rows) =>
      rows.map((r, i) =>
        i === rowIndex ? { ...r, spans: r.spans.map((s, j) => (j === spanIndex ? { ...s, ...patch } : s)) } : r,
      ),
    );
  }

  removeExceptionSpan(rowIndex: number, spanIndex: number): void {
    this.exceptions.update((rows) =>
      rows.map((r, i) => (i === rowIndex ? { ...r, spans: r.spans.filter((_, j) => j !== spanIndex) } : r)),
    );
  }

  removeException(index: number): void {
    this.exceptions.update((rows) => rows.filter((_, i) => i !== index));
  }

  toggleExclude(name: string): void {
    this.draft.update((d) => {
      if (!d) return d;
      const has = d.excludes.includes(name);
      return { ...d, excludes: has ? d.excludes.filter((x) => x !== name) : [...d.excludes, name] };
    });
  }

  blocker(): string | null {
    const d = this.draft();
    if (!d) return null;
    if (!d.name.trim()) return 'A name is required.';
    if (this.badSpans().length) return 'Fix the highlighted hours first.';
    if (this.exceptions().some((e) => !e.date)) return 'Every date exception needs a date.';
    const hasWeekly = WEEKDAYS.some((day) => (d.ranges[day] ?? []).length > 0);
    if (!hasWeekly && !this.exceptions().length) {
      return 'Without any hours this window is never open, and a rule using it would never fire.';
    }
    return null;
  }

  canSave(): boolean {
    return this.blocker() === null && !this.saving();
  }

  private body(): TimePeriodInput {
    const d = this.draft()!;
    const exceptions: Record<string, string[][]> = {};
    for (const ex of this.exceptions()) {
      if (!ex.date) continue;
      // Closed all day is the empty list — that is the API's encoding, not a missing value.
      exceptions[ex.date] = ex.closed ? [] : ex.spans.map((s) => [s.start, s.end]);
    }
    return { name: d.name.trim(), alias: d.alias, ranges: d.ranges, exceptions, excludes: d.excludes };
  }

  save(): void {
    if (!this.canSave()) return;
    this.saving.set(true);
    const fail = (err: { status?: number; error?: { detail?: string } }) => {
      this.saving.set(false);
      const msg =
        err?.status === 412
          ? 'Someone else changed this window while you were editing. Reload to see their version — your edit was not applied.'
          : err?.error?.detail || `Save failed (HTTP ${err?.status ?? '?'})`;
      this.snack.open(msg, 'OK', { duration: 9000 });
    };
    const id = this.editingId();
    if (!id) {
      this.notifications.createTimePeriod(this.body()).subscribe({
        next: (p) => {
          this.saving.set(false);
          this.editingId.set(p.id);
          this.snack.open(`Created “${p.name}” — it is ${p.active_now ? 'open' : 'closed'} right now.`, 'OK', { duration: 6000 });
          this.reload();
        },
        error: fail,
      });
      return;
    }
    const current = this.periods().find((p) => p.id === id);
    this.notifications.updateTimePeriod(id, this.body(), current?.version ?? '').subscribe({
      next: (p) => {
        this.saving.set(false);
        const n = this.usageById()[id]?.notification_rules.length ?? 0;
        this.snack.open(
          n ? `Saved “${p.name}” — this changes when ${n} rule(s) fire.` : `Saved “${p.name}”.`,
          'OK',
          { duration: 6000 },
        );
        this.reload();
      },
      error: fail,
    });
  }

  remove(p: TimePeriod): void {
    if (p.is_builtin) return;
    const u = this.usageById()[p.id];
    const n = u?.notification_rules.length ?? 0;
    // The consequence is named: the FK is ON DELETE SET NULL, so rules do not disappear —
    // they widen back to firing around the clock, which is the part worth knowing.
    const msg = n
      ? `Delete “${p.name}”? ${n} rule(s) using it will fire around the clock instead.`
      : `Delete “${p.name}”?`;
    const ref = this.snack.open(msg, 'Delete', { duration: 10000 });
    ref.onAction().subscribe(() => {
      this.notifications.deleteTimePeriod(p.id).subscribe({
        next: () => {
          if (this.editingId() === p.id) { this.editingId.set(null); this.draft.set(null); }
          this.snack.open(`Deleted “${p.name}”.`, 'OK', { duration: 4000 });
          this.reload();
        },
        error: (err) => this.snack.open(err?.error?.detail || 'Delete failed', 'OK', { duration: 9000 }),
      });
    });
  }
}
