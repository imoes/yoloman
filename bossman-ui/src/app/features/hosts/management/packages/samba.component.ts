import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { DirPickerComponent } from '../../../../shared/components/dir-picker/dir-picker.component';

interface Share {
  name: string;
  path: string;
  comment: string;
  browseable: string;   // yes|no
  writable: string;     // yes|no  (stored as "read only" inverted)
  guest: string;        // yes|no
  validUsers: string;
  extra: Record<string, unknown>; // other keys, preserved
}

const SMB_PATH = '/etc/samba/smb.conf';
const MANAGED = new Set(['path', 'comment', 'browseable', 'browsable', 'read only', 'writable', 'writeable', 'guest ok', 'valid users']);

/**
 * Samba shares snapin — one card per share (every smb.conf section except
 * [global]), with a directory browser for the share path (including the
 * [homes] share, whose path field was previously missing) and the common
 * options as dropdowns. Reads/writes smb.conf through the `ini` codec; the
 * [global] section is left untouched (merge keeps unlisted sections).
 */
@Component({
  selector: 'app-samba',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, DirPickerComponent],
  template: `
    <div class="bm-smb">
      @if (loading()) { <p class="bm-dim">Loading {{ path }}…</p> }
      @else {
        <div class="bm-head">
          <span class="bm-dim">{{ path }} — shares</span>
          <span class="bm-spacer"></span>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Save + reload' }}</button>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        @for (s of shares(); track $index) {
          <section class="bm-share">
            <header>
              <mat-icon>{{ s.name==='homes' ? 'home' : 'folder_shared' }}</mat-icon>
              <input class="bm-name" [value]="s.name" (input)="set($index,'name',$any($event.target).value)" placeholder="share-name" [readonly]="s.name==='homes'" />
              <span class="bm-spacer"></span>
              <button class="bm-x" (click)="remove($index)" title="Remove share">✕</button>
            </header>
            <div class="bm-grid">
              <label class="bm-fld bm-path">Path
                <app-dir-picker [agentId]="agentId()" [value]="s.path" (valueChange)="set($index,'path',$event)" placeholder="/srv/samba/share" />
              </label>
              <label class="bm-fld">Comment<input [value]="s.comment" (input)="set($index,'comment',$any($event.target).value)" /></label>
              <label class="bm-fld">Browseable<select [value]="s.browseable" (change)="set($index,'browseable',$any($event.target).value)"><option value="yes">yes</option><option value="no">no</option></select></label>
              <label class="bm-fld">Writable<select [value]="s.writable" (change)="set($index,'writable',$any($event.target).value)"><option value="yes">yes</option><option value="no">no</option></select></label>
              <label class="bm-fld">Guest OK<select [value]="s.guest" (change)="set($index,'guest',$any($event.target).value)"><option value="no">no</option><option value="yes">yes</option></select></label>
              <label class="bm-fld">Valid users<input [value]="s.validUsers" (input)="set($index,'validUsers',$any($event.target).value)" placeholder="alice, @staff or %S" /></label>
            </div>
          </section>
        }
        @if (!shares().length) { <p class="bm-dim">No shares defined.</p> }
        <button mat-button (click)="add()"><mat-icon>add</mat-icon> Add share</button>
      }
    </div>
  `,
  styles: [`
    .bm-smb { display: flex; flex-direction: column; gap: 12px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-share { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-share > header { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-share > header mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-name { font-weight: 600; font-size: 14px; border: 0; background: transparent; color: inherit; padding: 2px 4px; }
    .bm-name:not([readonly]):focus { outline: 1px solid var(--mat-sys-outline-variant); border-radius: 4px; }
    .bm-grid { display: flex; flex-wrap: wrap; gap: 12px; padding: 12px 14px; align-items: flex-end; }
    .bm-fld { display: flex; flex-direction: column; gap: 4px; font-size: 12px; }
    .bm-fld.bm-path { flex: 1; min-width: 260px; }
    .bm-fld input, .bm-fld select { padding: 6px 8px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font-size: 13px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.55; }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class SambaComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  readonly path = SMB_PATH;

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal(''); err = signal('');
  dryRun = signal(false);
  shares = signal<Share[]>([]);
  private originalNames: string[] = [];

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'config', { path: SMB_PATH, format: 'ini' }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const cfg = ((resp.result as { data?: { config?: Record<string, Record<string, unknown>> } })?.data?.config) || {};
        const list: Share[] = [];
        for (const [name, sec] of Object.entries(cfg)) {
          if (name === 'global') continue;
          const g = (k: string) => (sec[k] != null ? String(sec[k]) : '');
          const readOnly = g('read only') || (g('writable') ? (g('writable') === 'yes' ? 'no' : 'yes') : '');
          const extra: Record<string, unknown> = {};
          for (const [k, v] of Object.entries(sec)) if (!MANAGED.has(k)) extra[k] = v;
          list.push({
            name, path: g('path'), comment: g('comment'),
            browseable: (g('browseable') || g('browsable') || 'yes'),
            writable: readOnly ? (readOnly === 'yes' ? 'no' : 'yes') : 'yes',
            guest: g('guest ok') || 'no',
            validUsers: g('valid users'), extra,
          });
        }
        this.shares.set(list);
        this.originalNames = list.map((s) => s.name);
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.shares.set([]); },
    });
  }

  set(i: number, k: keyof Share, v: string): void { this.shares.update((r) => { const c = [...r]; c[i] = { ...c[i], [k]: v } as Share; return c; }); }
  add(): void { this.shares.update((r) => [...r, { name: '', path: '', comment: '', browseable: 'yes', writable: 'yes', guest: 'no', validUsers: '', extra: {} }]); }
  remove(i: number): void { this.shares.update((r) => r.filter((_, j) => j !== i)); }

  save(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const values: Record<string, unknown> = {};
    const kept = new Set<string>();
    for (const s of this.shares()) {
      const name = s.name.trim();
      if (!name) continue;
      kept.add(name);
      const sec: Record<string, unknown> = { ...s.extra };
      if (s.path.trim()) sec['path'] = s.path.trim();
      if (s.comment.trim()) sec['comment'] = s.comment.trim();
      sec['browseable'] = s.browseable;
      sec['read only'] = s.writable === 'yes' ? 'no' : 'yes';
      sec['guest ok'] = s.guest;
      if (s.validUsers.trim()) sec['valid users'] = s.validUsers.trim();
      values[name] = sec;
    }
    // Sections removed in the UI → managed-absent (null) so the codec drops them.
    for (const orig of this.originalNames) if (!kept.has(orig)) values[orig] = null;

    const res: ConfigResource = { type: 'config', path: SMB_PATH, format: 'ini', values };
    this.agentService.stateApply(this.agentId(), [res], this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        // Reload smbd so new shares take effect (best-effort).
        this.agentService.callTool(this.agentId(), 'systemd', { name: 'smbd', state: 'reloaded' }).subscribe({
          next: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) + reloaded smbd.`); this.reload(); },
          error: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s).`); this.reload(); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }
}
