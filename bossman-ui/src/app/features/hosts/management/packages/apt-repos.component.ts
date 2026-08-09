import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';

interface Repo { file: string; entry: string; removable: boolean; }

/**
 * APT sources snapin — list every configured repository (one-line entries in
 * /etc/apt/sources.list and sources.list.d/*.list, plus deb822 *.sources
 * files), add a one-line or deb822 repo (via the `apt_repository` /
 * `deb822_repository` agent modules, each written as its own file under
 * sources.list.d), and remove a sources.list.d file. Add runs apt-get update.
 */
@Component({
  selector: 'app-apt-repos',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-apt">
      @if (loading()) { <p class="bm-dim">Loading APT sources…</p> }
      @else {
        <div class="bm-head">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>Configured repositories</h3></header>
          <table class="bm-t">
            <thead><tr><th>File</th><th>Entry</th><th></th></tr></thead>
            <tbody>
              @for (r of repos(); track $index) {
                <tr>
                  <td class="bm-mono">{{ r.file }}</td>
                  <td class="bm-mono">{{ r.entry }}</td>
                  <td>@if (r.removable) { <button class="bm-x" (click)="removeFile(r)" [disabled]="busy()" title="Remove this sources.list.d file">✕</button> }</td>
                </tr>
              }
              @if (!repos().length) { <tr><td colspan="3" class="bm-dim">No repositories found.</td></tr> }
            </tbody>
          </table>
        </section>

        <div class="bm-grid2">
          <section class="bm-card">
            <header><h3>Add one-line repo</h3></header>
            <div class="bm-form">
              <input placeholder="filename (e.g. docker)" [value]="olName()" (input)="olName.set($any($event.target).value)" />
              <input placeholder="deb https://… stable main" [value]="olRepo()" (input)="olRepo.set($any($event.target).value)" />
              <button mat-stroked-button (click)="addOneLine()" [disabled]="busy() || !olName().trim() || !olRepo().trim()"><mat-icon>add</mat-icon> {{ dryRun() ? 'Preview' : 'Add' }}</button>
            </div>
          </section>

          <section class="bm-card">
            <header><h3>Add deb822 repo (.sources)</h3></header>
            <div class="bm-form">
              <input placeholder="name (e.g. myrepo)" [value]="d822Name()" (input)="d822Name.set($any($event.target).value)" />
              <input placeholder="URIs (space-separated)" [value]="d822Uris()" (input)="d822Uris.set($any($event.target).value)" />
              <input placeholder="suites (e.g. bookworm)" [value]="d822Suites()" (input)="d822Suites.set($any($event.target).value)" />
              <input placeholder="components (e.g. main contrib)" [value]="d822Comp()" (input)="d822Comp.set($any($event.target).value)" />
              <input placeholder="signed_by key path (optional)" [value]="d822Key()" (input)="d822Key.set($any($event.target).value)" />
              <button mat-stroked-button (click)="addDeb822()" [disabled]="busy() || !d822Name().trim() || !d822Uris().trim() || !d822Suites().trim()"><mat-icon>add</mat-icon> {{ dryRun() ? 'Preview' : 'Add' }}</button>
            </div>
          </section>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-apt { display: flex; flex-direction: column; gap: 16px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    @media (max-width: 900px) { .bm-grid2 { grid-template-columns: 1fr; } }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 4px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
    .bm-form { padding: 12px 14px; display: flex; flex-direction: column; gap: 9px; }
    .bm-form input { padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; }
    .bm-dim { opacity: 0.6; font-size: 13px; padding: 6px 8px; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class AptReposComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  dryRun = signal(false);
  msg = signal(''); err = signal('');
  repos = signal<Repo[]>([]);

  olName = signal(''); olRepo = signal('');
  d822Name = signal(''); d822Uris = signal(''); d822Suites = signal(''); d822Comp = signal(''); d822Key = signal('');

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    // Active (uncommented) deb/deb-src lines from .list files + a marker per .sources file.
    const script = `grep -rHE '^[[:space:]]*deb' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; ` +
      `for f in /etc/apt/sources.list.d/*.sources; do [ -e "$f" ] && echo "$f:[deb822] $(grep -h '^URIs:' "$f" 2>/dev/null | head -1)"; done`;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        this.repos.set(this.parse(out));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.repos.set([]); },
    });
  }

  private parse(text: string): Repo[] {
    const out: Repo[] = [];
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      // grep -H output is "file:content"
      const idx = line.indexOf(':');
      if (idx < 0) continue;
      const file = line.slice(0, idx);
      const entry = line.slice(idx + 1).trim();
      out.push({ file, entry, removable: file.startsWith('/etc/apt/sources.list.d/') });
    }
    return out;
  }

  addOneLine(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'apt_repository', {
      filename: this.olName().trim(), repo: this.olRepo().trim(), state: 'present', update_cache: !this.dryRun(), dry_run: this.dryRun(),
    }).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set((r.result as { msg?: string })?.msg || 'added'); this.olName.set(''); this.olRepo.set(''); if (!this.dryRun()) this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'add failed'); },
    });
  }

  addDeb822(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const p: Record<string, unknown> = {
      name: this.d822Name().trim(),
      uris: this.d822Uris().trim().split(/\s+/),
      suites: this.d822Suites().trim().split(/\s+/),
      state: 'present', dry_run: this.dryRun(),
    };
    if (this.d822Comp().trim()) p['components'] = this.d822Comp().trim().split(/\s+/);
    if (this.d822Key().trim()) p['signed_by'] = this.d822Key().trim();
    this.agentService.callTool(this.agentId(), 'deb822_repository', p).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set((r.result as { msg?: string })?.msg || 'added'); this.d822Name.set(''); this.d822Uris.set(''); this.d822Suites.set(''); this.d822Comp.set(''); this.d822Key.set(''); if (!this.dryRun()) this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'add failed'); },
    });
  }

  removeFile(r: Repo): void {
    const base = r.file.replace('/etc/apt/sources.list.d/', '');
    this.busy.set(true); this.msg.set(''); this.err.set('');
    if (base.endsWith('.sources')) {
      this.agentService.callTool(this.agentId(), 'deb822_repository', { name: base.replace(/\.sources$/, ''), state: 'absent', dry_run: this.dryRun() }).subscribe({
        next: () => this.afterRemove(),
        error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'remove failed'); },
      });
    } else {
      this.agentService.callTool(this.agentId(), 'apt_repository', { filename: base.replace(/\.list$/, ''), state: 'absent', dry_run: this.dryRun() }).subscribe({
        next: () => this.afterRemove(),
        error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'remove failed'); },
      });
    }
  }

  private afterRemove(): void { this.busy.set(false); this.msg.set('removed'); if (!this.dryRun()) this.reload(); }
}
