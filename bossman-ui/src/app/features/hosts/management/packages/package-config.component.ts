import { Component, computed, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource, DirectiveSpec } from '../../../../core/models/agent.model';

/** One package's config-file identity in the "Package configuration" console
 * category. `mode: 'codec'` edits the real parsed values in place (safe merge
 * write); `mode: 'template'` (not used by this component — bind gets its own)
 * would regenerate from a schema. */
export interface PackageConfigDef {
  id: string;
  label: string;
  icon: string;
  path: string;
  format: string;      // codec: ini | keyvalue | …
  separator?: string;
  /** section name treated as the service's global block (rendered first,
   * labeled, not a "resource"); the rest are the per-resource entries
   * (shares/vhosts/…). */
  globalSection?: string;
  resourceNoun?: string; // e.g. "share", "export" — for the add button label
}

type Values = Record<string, unknown>;

/**
 * Generic per-package config snapin (mode A — codec round-trip). Reads the
 * package's config file from the host's observed-state (already parsed by its
 * codec into structured values), lets the operator edit it as sections +
 * key/value rows (INI) or flat key/values, and writes it back with the
 * in-place codec merge via POST /state/apply (versioned, dry-runnable,
 * write-gated on the agent). Shows the REAL current config — nothing is
 * regenerated or lost. Implements the host-management child contract
 * (loadOnce/reload + loading/busy/msg/err signals).
 */
@Component({
  selector: 'app-package-config',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-pkg">
      @if (loading()) { <p class="bm-dim">Loading {{ def().path }}…</p> }
      @else if (loadErr()) { <p class="bm-err">{{ loadErr() }}</p> }
      @else if (!found()) {
        <p class="bm-dim">No <code>{{ def().path }}</code> found on this host — is {{ def().label }} installed?</p>
      } @else {
        <div class="bm-pkg-head">
          <span class="bm-dim">{{ def().path }} · {{ def().format }}</span>
          <span class="bm-spacer"></span>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Apply' }}</button>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        @if (sectioned()) {
          @for (sec of sectionNames(); track sec) {
            <div class="bm-sec">
              <div class="bm-sec-head">
                <mat-icon>{{ sec === def().globalSection ? 'settings' : 'folder_shared' }}</mat-icon>
                <strong>{{ sec === def().globalSection ? sec + ' (global)' : sec }}</strong>
                @if (sec !== def().globalSection) {
                  <button class="bm-x" (click)="removeSection(sec)" title="Remove {{ def().resourceNoun || 'section' }}">✕</button>
                }
              </div>
              <table class="bm-kv">
                @for (k of keysOf(sec); track k) {
                  <tr>
                    <td class="bm-k">{{ k }}</td>
                    <td>
                      @if (enumOf(k); as opts) {
                        <select class="bm-in" [value]="strVal(sec, k)" (change)="setVal(sec, k, $any($event.target).value)">
                          @for (o of opts; track o) { <option [value]="o" [selected]="o === strVal(sec, k)">{{ o }}</option> }
                        </select>
                      } @else {
                        <input class="bm-in" [value]="strVal(sec, k)" (input)="setVal(sec, k, $any($event.target).value)" />
                      }
                    </td>
                    <td><button class="bm-x" (click)="removeKey(sec, k)" title="Remove setting">✕</button></td>
                  </tr>
                }
                <tr>
                  <td><input class="bm-in bm-newk" #nk placeholder="new setting" /></td>
                  <td><input class="bm-in" #nv placeholder="value" /></td>
                  <td><button class="bm-add" (click)="addKey(sec, nk.value, nv.value); nk.value=''; nv.value=''">+ add</button></td>
                </tr>
              </table>
            </div>
          }
          <div class="bm-addsec">
            <input class="bm-in" #ns placeholder="new {{ def().resourceNoun || 'section' }} name" />
            <button mat-stroked-button (click)="addSection(ns.value); ns.value=''"><mat-icon>add</mat-icon> Add {{ def().resourceNoun || 'section' }}</button>
          </div>
        } @else {
          <!-- flat key/value (keyvalue codec) -->
          <div class="bm-sec">
            <table class="bm-kv">
              @for (k of keysOf(null); track k) {
                <tr>
                  <td class="bm-k">{{ k }}</td>
                  <td>
                    @if (enumOf(k); as opts) {
                      <select class="bm-in" [value]="strVal(null, k)" (change)="setVal(null, k, $any($event.target).value)">
                        @for (o of opts; track o) { <option [value]="o" [selected]="o === strVal(null, k)">{{ o }}</option> }
                      </select>
                    } @else {
                      <input class="bm-in" [value]="strVal(null, k)" (input)="setVal(null, k, $any($event.target).value)" />
                    }
                  </td>
                  <td><button class="bm-x" (click)="removeKey(null, k)" title="Remove setting">✕</button></td>
                </tr>
              }
              <tr>
                <td><input class="bm-in bm-newk" #fk placeholder="new setting" /></td>
                <td><input class="bm-in" #fv placeholder="value" /></td>
                <td><button class="bm-add" (click)="addKey(null, fk.value, fv.value); fk.value=''; fv.value=''">+ add</button></td>
              </tr>
            </table>
          </div>
        }
      }
    </div>
  `,
  styles: [`
    .bm-pkg-head { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-sec { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; margin-bottom: 12px; overflow: hidden; }
    .bm-sec-head { display: flex; align-items: center; gap: 8px; padding: 8px 12px; background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
    .bm-sec-head mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.75; }
    .bm-kv { width: 100%; border-collapse: collapse; }
    .bm-kv td { padding: 4px 12px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
    .bm-k { width: 220px; font-family: monospace; font-size: 13px; opacity: 0.85; }
    .bm-in { width: 100%; box-sizing: border-box; padding: 4px 8px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-newk { width: 200px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.55; }
    .bm-add { border: 0; background: transparent; cursor: pointer; color: var(--mat-sys-primary); font-size: 13px; }
    .bm-addsec { display: flex; gap: 8px; align-items: center; margin-top: 4px; }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green, #2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error, #c62828); font-size: 13px; }
  `],
})
export class PackageConfigComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  def = input.required<PackageConfigDef>();

  loading = signal(false);
  loaded = signal(false);
  loadErr = signal('');
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);

  private model = signal<Values | null>(null);
  // Per-directive enum metadata (config_directives) for this file → a value
  // dropdown instead of a free-text input where an enum is known.
  private directives = signal<Record<string, DirectiveSpec>>({});

  found = computed(() => this.model() !== null);

  /** Enum values for a directive name, or null (→ free-text input). */
  enumOf(key: string): string[] | null {
    const spec = this.directives()[key];
    return spec?.values?.length ? spec.values : null;
  }
  sectioned = computed(() => {
    const v = this.model();
    if (!v) return false;
    const vals = Object.values(v);
    return vals.length > 0 && vals.every((x) => x !== null && typeof x === 'object' && !Array.isArray(x));
  });
  sectionNames = computed(() => {
    const v = this.model();
    if (!v) return [];
    const g = this.def().globalSection;
    const names = Object.keys(v);
    // global block first, then the rest alphabetically.
    return names.sort((a, b) => (a === g ? -1 : b === g ? 1 : a.localeCompare(b)));
  });

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set('');
    this.msg.set('');
    this.err.set('');
    const d = this.def();
    // Read the file directly through the `config` module (codec parse) rather
    // than the host's observed-state: observe only surfaces configs that
    // config_discover finds via enabled units, which misses packages whose
    // unit doesn't name its config (proftpd/pure-ftpd/nfs/cups). Reading by
    // path is robust for any installed package.
    const base = d.path.split('/').pop() || d.path;
    forkJoin({
      cfg: this.agentService.callTool(this.agentId(), 'config', { path: d.path, format: d.format, separator: d.separator }),
      dir: this.agentService.configDirectives(),
    }).subscribe({
      next: ({ cfg, dir }) => {
        this.loading.set(false);
        this.loaded.set(true);
        const data = (cfg.result as { data?: { config?: unknown } })?.data?.config;
        this.model.set(data && typeof data === 'object' ? structuredClone(data as Values) : null);
        // Enum metadata keyed by the file's basename (config_directives convention).
        const cat = dir.directives || {};
        this.directives.set({ ...(cat[base] || {}), ...(cat[d.path] || {}) } as Record<string, DirectiveSpec>);
      },
      // A missing file (package not installed) comes back as an error — show
      // the graceful "not installed" empty-state, not a hard error.
      error: () => { this.loading.set(false); this.loaded.set(true); this.model.set(null); },
    });
  }

  // ── editing (immutable updates on the model signal) ──
  private section(v: Values, sec: string | null): Record<string, unknown> {
    return (sec === null ? v : (v[sec] as Record<string, unknown>)) || {};
  }
  keysOf(sec: string | null): string[] {
    const v = this.model(); if (!v) return [];
    return Object.keys(this.section(v, sec));
  }
  strVal(sec: string | null, k: string): string {
    const v = this.model(); if (!v) return '';
    const raw = this.section(v, sec)[k];
    return raw === null || raw === undefined ? '' : String(raw);
  }
  private mutate(fn: (v: Values) => void): void {
    const v = structuredClone(this.model() || {});
    fn(v);
    this.model.set(v);
  }
  setVal(sec: string | null, k: string, val: string): void {
    this.mutate((v) => { if (sec === null) v[k] = val; else (v[sec] as Record<string, unknown>)[k] = val; });
  }
  addKey(sec: string | null, k: string, val: string): void {
    k = (k || '').trim(); if (!k) return;
    this.mutate((v) => { if (sec === null) v[k] = val; else (v[sec] as Record<string, unknown>)[k] = val; });
  }
  removeKey(sec: string | null, k: string): void {
    // A null value = managed-absent, so the codec merge deletes the key on write.
    this.mutate((v) => { if (sec === null) v[k] = null as unknown as string; else (v[sec] as Record<string, unknown>)[k] = null; });
  }
  addSection(name: string): void {
    name = (name || '').trim(); if (!name) return;
    this.mutate((v) => { if (!(name in v)) v[name] = {}; });
  }
  removeSection(name: string): void {
    this.mutate((v) => { v[name] = null; }); // null section → codec removes it
  }

  save(): void {
    const v = this.model(); if (!v) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const resource: ConfigResource = {
      type: 'config',
      path: this.def().path,
      format: this.def().format,
      separator: this.def().separator,
      values: v,
    };
    this.agentService.stateApply(this.agentId(), [resource], this.dryRun()).subscribe({
      next: (resp) => {
        this.busy.set(false);
        const n = resp.plan?.changed_count ?? (resp.plan?.changes?.length ?? 0);
        this.msg.set(this.dryRun() ? `Preview: ${n} change(s) — nothing written.` : `Applied — ${n} change(s).`);
        if (!this.dryRun()) this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Apply failed.'); },
    });
  }
}
