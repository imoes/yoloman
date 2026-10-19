import { Component, computed, effect, input, output, signal } from '@angular/core';
import { DecimalPipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { ImageVolume } from '../../core/services/images.service';

/** The roles whose size a grow policy may change; esp/boot/swap/bios_boot keep their size (api/images.py). */
export const GROWABLE_ROLES = new Set(['root', 'var', 'home', 'data']);

export interface GrowSizing { mode: 'percent' | 'absolute'; policy: Record<string, number>; error: string; }

/** How the growable volumes of a golden image divide the target disk — ONE editor for the image's default
 *  (Disk images page) and a deployment's own sizing (the deploy wizard), with the backend's rules
 *  (services/imaging.plan_restore):
 *   - one value per VOLUME, keyed by its mountpoint (imaging.policy_key). A saved role key ("data") still
 *     fills every volume of that role, so an image with /opt, /tmp and /usr as "data" can be sized apart now;
 *   - percent: each volume but the LAST takes its share of the leftover space and the last one takes the rest,
 *     so the shares need not sum to 100 — only the others together must stay at or below 100;
 *   - GiB: exact sizes, and at most one volume set to 0, which fills the rest. */
@Component({
  selector: 'bm-grow-sizing',
  standalone: true,
  imports: [DecimalPipe, FormsModule, MatIconModule],
  template: `
    @if (rows().length) {
      <div class="gs-mode" role="radiogroup" aria-label="Sizing unit">
        <button type="button" role="radio" [attr.aria-checked]="mode() === 'percent'" [class.on]="mode() === 'percent'" (click)="setMode('percent')">Percent</button>
        <button type="button" role="radio" [attr.aria-checked]="mode() === 'absolute'" [class.on]="mode() === 'absolute'" (click)="setMode('absolute')">GiB</button>
      </div>
    }
    @for (v of volumes(); track $index) {
      <div class="gs-vol">
        <span class="gs-name">
          <mat-icon>{{ v.vg ? 'view_stream' : 'storage' }}</mat-icon>
          {{ v.mountpoint || v.role }}
          @if (v.vg) { <span class="gs-dim">LVM {{ v.vg }}/{{ v.lv }}</span> }
          <span class="gs-dim">{{ v.fs_type }}</span>
        </span>
        @if (keyOf(v); as k) {
          <span class="gs-val">
            @if (mode() === 'percent' && k === lastKey()) {
              <span class="gs-rest" [title]="'The last growable volume takes whatever the others leave'">rest · {{ rest() }} %</span>
            } @else {
              <input type="number" [min]="0" [max]="mode() === 'percent' ? 100 : null" [ngModel]="values()[k]"
                     (ngModelChange)="set(k, $event)" [attr.aria-label]="(mode() === 'percent' ? 'Share of ' : 'Size of ') + (v.mountpoint || v.role)" />
              {{ mode() === 'percent' ? '%' : 'GiB' }}
            }
          </span>
        } @else {
          <span class="gs-dim">fixed · {{ (v.size_bytes / 1073741824) | number: '1.0-1' }} GiB</span>
        }
      </div>
    }
    @if (rows().length) {
      @if (error()) { <div class="gs-note gs-bad" role="alert">{{ error() }}</div> }
      @else if (mode() === 'percent') { <div class="gs-note">The last volume ({{ lastKey() }}) takes the rest: {{ rest() }} % of the space left after the fixed volumes.</div> }
      @else { <div class="gs-note">Exact sizes in GiB; a volume set to 0 fills the rest of the disk.</div> }
      @if (legacyNote()) { <div class="gs-note">{{ legacyNote() }}</div> }
    } @else {
      <div class="gs-note">No growable volumes (root/var/home/data) — the last volume fills the disk.</div>
    }
  `,
  styles: [`
    :host { display: block; }
    .gs-mode { display: inline-flex; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; overflow: hidden; margin-bottom: 8px; }
    .gs-mode button { font: inherit; font-size: 12px; padding: 4px 12px; border: 0; background: none; color: inherit; cursor: pointer; }
    .gs-mode button.on { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); font-weight: 600; }
    .gs-vol { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 5px 0; font-size: 13px;
      border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); }
    .gs-name { display: inline-flex; align-items: center; gap: 6px; }
    .gs-name mat-icon { font-size: 16px; width: 16px; height: 16px; opacity: .6; }
    .gs-dim { opacity: .55; font-size: 12px; }
    .gs-val input { width: 64px; font: inherit; padding: 3px 6px; border-radius: 5px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; }
    .gs-rest { font-size: 12px; opacity: .8; }
    .gs-note { font-size: 12px; margin-top: 8px; opacity: .8; }
    .gs-bad { color: var(--bm-red, #d0021b); opacity: 1; }
  `],
})
export class GrowSizingComponent {
  volumes = input<ImageVolume[]>([]);
  policy = input<Record<string, number>>({});
  initialMode = input<'percent' | 'absolute'>('percent', { alias: 'mode' });
  changed = output<GrowSizing>();

  mode = signal<'percent' | 'absolute'>('percent');
  values = signal<Record<string, number>>({});

  /** Growable volumes with their key: the mountpoint, or the role for a volume without one. */
  rows = computed(() => this.volumes().filter((v) => GROWABLE_ROLES.has(v.role)).map((v) => ({ v, key: v.mountpoint || v.role })));
  lastKey = computed(() => this.rows().at(-1)?.key ?? '');
  others = computed(() => this.rows().filter((r) => r.key !== this.lastKey()).reduce((a, r) => a + (Number(this.values()[r.key]) || 0), 0));
  rest = computed(() => Math.max(0, 100 - this.others()));
  legacyNote = computed(() => {
    const keys = Object.keys(this.policy());
    const roleKeys = keys.filter((k) => GROWABLE_ROLES.has(k) && this.rows().filter((r) => r.v.role === k).length > 1);
    return roleKeys.length ? `The saved split names the role ${roleKeys.join(', ')}, which several volumes share; each `
      + 'of them got the same share. Saving stores one value per volume.' : '';
  });
  error = computed(() => {
    const vals = this.rows().map((r) => Number(this.values()[r.key]) || 0);
    if (vals.some((x) => x < 0)) { return 'Values must be 0 or more'; }
    if (this.mode() === 'percent') {
      return this.others() > 100 ? `The volumes before ${this.lastKey()} take ${this.others()} % — at most 100 %` : '';
    }
    return vals.filter((x) => x === 0).length > 1 ? 'Only one volume can be 0 (it fills the rest)' : '';
  });

  constructor() {
    // (Re)load whenever the image or its saved policy changes: mountpoint key first, else the role key.
    effect(() => {
      const rows = this.rows();
      const saved = this.policy();
      const mode = this.initialMode();
      const even = rows.length ? Math.floor(100 / rows.length) : 0;
      const has = Object.keys(saved).length > 0;
      const vals: Record<string, number> = {};
      for (const r of rows) {
        const s = saved[r.key] ?? saved[r.v.role];
        vals[r.key] = has && s != null ? Number(s) : (mode === 'percent' ? even : 0);
      }
      this.mode.set(mode);
      this.values.set(vals);
      queueMicrotask(() => this.emit());
    });
  }

  keyOf(v: ImageVolume): string | null { return GROWABLE_ROLES.has(v.role) ? (v.mountpoint || v.role) : null; }

  setMode(m: 'percent' | 'absolute'): void {
    if (m === this.mode()) { return; }
    this.mode.set(m);
    const even = this.rows().length ? Math.floor(100 / this.rows().length) : 0;
    this.values.set(Object.fromEntries(this.rows().map((r) => [r.key, m === 'percent' ? even : 0])));
    this.emit();
  }

  set(key: string, value: unknown): void {
    this.values.set({ ...this.values(), [key]: Number(value) || 0 });
    this.emit();
  }

  /** The policy as the backend reads it: one entry per growable volume; in percent mode the last one's value is
   *  informational (it takes the rest), sent as its computed share. */
  private emit(): void {
    const policy: Record<string, number> = {};
    for (const r of this.rows()) {
      policy[r.key] = this.mode() === 'percent' && r.key === this.lastKey() ? this.rest() : Number(this.values()[r.key]) || 0;
    }
    this.changed.emit({ mode: this.mode(), policy, error: this.error() });
  }
}
