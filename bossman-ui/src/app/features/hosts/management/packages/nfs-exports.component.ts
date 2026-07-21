import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';

interface Exp { path: string; clients: string; }
const EXPORTS_PATH = '/etc/exports';

/**
 * NFS exports snapin — edits /etc/exports as a table of {path, clients} through
 * the `exports` codec (round-tripped in place, comment header preserved), then
 * `exportfs -ra` to apply. `clients` is the raw "host(options) …" spec text.
 */
@Component({
  selector: 'app-nfs-exports',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
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
        <table class="bm-kv">
          <thead><tr><th>Path</th><th>Clients (host(options) …)</th><th></th></tr></thead>
          <tbody>
            @for (e of rows(); track $index) {
              <tr>
                <td><input class="bm-in bm-path" [value]="e.path" (input)="set($index,'path',$any($event.target).value)" placeholder="/srv/share" /></td>
                <td><input class="bm-in" [value]="e.clients" (input)="set($index,'clients',$any($event.target).value)" placeholder="192.168.1.0/24(rw,sync,no_subtree_check)" /></td>
                <td><button class="bm-x" (click)="remove($index)" title="Remove export">✕</button></td>
              </tr>
            }
            @if (!rows().length) { <tr><td colspan="3" class="bm-dim">No exports yet — add one below.</td></tr> }
          </tbody>
        </table>
        <button mat-button (click)="add()"><mat-icon>add</mat-icon> Add export</button>
      }
    </div>
  `,
  styles: [`
    .bm-nfs-head { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-kv { width: 100%; border-collapse: collapse; }
    .bm-kv th { text-align: left; font-size: 12px; opacity: 0.7; padding: 4px 8px; }
    .bm-kv td { padding: 3px 8px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-in { width: 100%; box-sizing: border-box; padding: 4px 8px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-path { min-width: 180px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.55; }
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
  rows = signal<Exp[]>([]);

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'config', { path: EXPORTS_PATH, format: 'exports' }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const ex = ((resp.result as { data?: { config?: { exports?: Exp[] } } })?.data?.config?.exports) || [];
        this.rows.set(ex.map((e) => ({ path: e.path || '', clients: e.clients || '' })));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.rows.set([]); },
    });
  }

  set(i: number, k: keyof Exp, v: string): void { this.rows.update((rs) => { const c = [...rs]; c[i] = { ...c[i], [k]: v }; return c; }); }
  add(): void { this.rows.update((rs) => [...rs, { path: '', clients: '' }]); }
  remove(i: number): void { this.rows.update((rs) => rs.filter((_, j) => j !== i)); }

  save(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const res: ConfigResource = {
      type: 'config', path: EXPORTS_PATH, format: 'exports',
      values: { exports: this.rows().filter((e) => e.path.trim()) },
    };
    this.agentService.stateApply(this.agentId(), [res], this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        // Apply the export table to the running server.
        this.agentService.callTool(this.agentId(), 'command', { argv: ['exportfs', '-ra'] }).subscribe({
          next: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) + reloaded exports.`); this.reload(); },
          error: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) (exportfs reload may need a running nfs server).`); this.reload(); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }
}
