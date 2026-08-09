import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { DirPickerComponent } from '../../../../shared/components/dir-picker/dir-picker.component';

/** One export row: a path shared to one client, with structured options. */
interface Row {
  path: string;
  client: string;
  access: 'rw' | 'ro';
  sync: 'sync' | 'async';
  squash: 'root_squash' | 'no_root_squash' | 'all_squash';
  subtree: 'subtree_check' | 'no_subtree_check';
  secure: boolean;
  extra: string; // any options we don't model, preserved verbatim
}
interface RawExport { path: string; clients: string; }

const EXPORTS_PATH = '/etc/exports';
const KNOWN = new Set(['rw', 'ro', 'sync', 'async', 'root_squash', 'no_root_squash', 'all_squash', 'subtree_check', 'no_subtree_check', 'secure', 'insecure']);

/**
 * NFS exports snapin — one row per (path → client) with the export options
 * chosen from dropdowns/checkboxes instead of free text, and a directory
 * browser for the export path. Rows sharing a path are recombined into a
 * single /etc/exports line ("path clientA(opts) clientB(opts)") through the
 * `exports` codec, then `exportfs -ra`.
 */
@Component({
  selector: 'app-nfs-exports',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, DirPickerComponent],
  template: `
    <div class="bm-nfs">
      @if (loading()) { <p class="bm-dim">Loading {{ path }}…</p> }
      @else {
        <div class="bm-nfs-head">
          <span class="bm-dim">{{ path }} — NFS exports</span>
          <span class="bm-spacer"></span>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Save + exportfs' }}</button>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        @for (e of rows(); track $index) {
          <div class="bm-exp">
            <div class="bm-exp-grid">
              <label class="bm-fld bm-path">Path
                <app-dir-picker [agentId]="agentId()" [value]="e.path" (valueChange)="set($index,'path',$event)" placeholder="/srv/share" />
              </label>
              <label class="bm-fld">Client
                <input [value]="e.client" (input)="set($index,'client',$any($event.target).value)" placeholder="10.0.0.0/24 or *" />
              </label>
              <label class="bm-fld">Access
                <select [value]="e.access" (change)="set($index,'access',$any($event.target).value)"><option value="rw">rw</option><option value="ro">ro</option></select>
              </label>
              <label class="bm-fld">Write mode
                <select [value]="e.sync" (change)="set($index,'sync',$any($event.target).value)"><option value="sync">sync</option><option value="async">async</option></select>
              </label>
              <label class="bm-fld">Root squash
                <select [value]="e.squash" (change)="set($index,'squash',$any($event.target).value)"><option value="root_squash">root_squash</option><option value="no_root_squash">no_root_squash</option><option value="all_squash">all_squash</option></select>
              </label>
              <label class="bm-fld">Subtree
                <select [value]="e.subtree" (change)="set($index,'subtree',$any($event.target).value)"><option value="no_subtree_check">no_subtree_check</option><option value="subtree_check">subtree_check</option></select>
              </label>
              <label class="bm-chk"><input type="checkbox" [checked]="e.secure" (change)="set($index,'secure',$any($event.target).checked)" /> secure</label>
              @if (e.extra) { <label class="bm-fld bm-extra">Other options<input [value]="e.extra" (input)="set($index,'extra',$any($event.target).value)" /></label> }
              <button class="bm-x" (click)="remove($index)" title="Remove export">✕</button>
            </div>
          </div>
        }
        @if (!rows().length) { <p class="bm-dim">No exports yet — add one below.</p> }
        <button mat-button (click)="add()"><mat-icon>add</mat-icon> Add export</button>
      }
    </div>
  `,
  styles: [`
    .bm-nfs { display: flex; flex-direction: column; gap: 12px; }
    .bm-nfs-head { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-exp { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 12px 14px; }
    .bm-exp-grid { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
    .bm-fld { display: flex; flex-direction: column; gap: 4px; font-size: 12px; opacity: 0.95; }
    .bm-fld.bm-path { flex: 1; min-width: 240px; } .bm-fld.bm-extra { flex: 1; min-width: 160px; }
    .bm-fld input, .bm-fld select { padding: 6px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font-size: 13px; }
    .bm-chk { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; padding-bottom: 6px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.55; align-self: center; }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class NfsExportsComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  readonly path = EXPORTS_PATH;

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  rows = signal<Row[]>([]);

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'config', { path: EXPORTS_PATH, format: 'exports' }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const ex = ((resp.result as { data?: { config?: { exports?: RawExport[] } } })?.data?.config?.exports) || [];
        this.rows.set(ex.flatMap((e) => this.explode(e)));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.rows.set([]); },
    });
  }

  /** Split one "path clientA(opts) clientB(opts)" export into one Row per client. */
  private explode(e: RawExport): Row[] {
    const specs = (e.clients || '').match(/\S+\([^)]*\)|\S+/g) || [];
    if (!specs.length) return [{ ...this.blank(), path: e.path || '' }];
    return specs.map((spec) => {
      const m = /^([^(]+)(?:\(([^)]*)\))?$/.exec(spec);
      const client = m ? m[1] : spec;
      const opts = (m && m[2] ? m[2] : '').split(',').map((o) => o.trim()).filter(Boolean);
      const r: Row = { ...this.blank(), path: e.path || '', client };
      r.access = opts.includes('ro') ? 'ro' : 'rw';
      r.sync = opts.includes('async') ? 'async' : 'sync';
      r.squash = opts.includes('all_squash') ? 'all_squash' : opts.includes('no_root_squash') ? 'no_root_squash' : 'root_squash';
      r.subtree = opts.includes('subtree_check') ? 'subtree_check' : 'no_subtree_check';
      r.secure = !opts.includes('insecure');
      r.extra = opts.filter((o) => !KNOWN.has(o)).join(',');
      return r;
    });
  }

  private blank(): Row {
    return { path: '', client: '*', access: 'rw', sync: 'sync', squash: 'root_squash', subtree: 'no_subtree_check', secure: true, extra: '' };
  }

  /** Assemble a Row's option list into "opt,opt,..." (skipping kernel defaults). */
  private opts(r: Row): string {
    const o: string[] = [r.access, r.sync];
    if (r.squash !== 'root_squash') o.push(r.squash);
    if (r.subtree !== 'no_subtree_check') o.push(r.subtree);
    if (!r.secure) o.push('insecure');
    if (r.extra.trim()) o.push(...r.extra.split(',').map((x) => x.trim()).filter(Boolean));
    return o.join(',');
  }

  set(i: number, k: keyof Row, v: string | boolean): void { this.rows.update((rs) => { const c = [...rs]; c[i] = { ...c[i], [k]: v } as Row; return c; }); }
  add(): void { this.rows.update((rs) => [...rs, this.blank()]); }
  remove(i: number): void { this.rows.update((rs) => rs.filter((_, j) => j !== i)); }

  save(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    // Group rows by path → one export line with all client(opts) specs.
    const byPath = new Map<string, string[]>();
    for (const r of this.rows()) {
      if (!r.path.trim() || !r.client.trim()) continue;
      const spec = `${r.client.trim()}(${this.opts(r)})`;
      (byPath.get(r.path.trim()) ?? byPath.set(r.path.trim(), []).get(r.path.trim())!).push(spec);
    }
    const exports = [...byPath.entries()].map(([path, specs]) => ({ path, clients: specs.join(' ') }));
    const res: ConfigResource = { type: 'config', path: EXPORTS_PATH, format: 'exports', values: { exports } };
    this.agentService.stateApply(this.agentId(), [res], this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        this.agentService.callTool(this.agentId(), 'command', { argv: ['exportfs', '-ra'] }).subscribe({
          next: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) + reloaded exports.`); this.reload(); },
          error: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) (exportfs reload may need a running nfs server).`); this.reload(); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }
}
