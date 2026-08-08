import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';

interface LrEntry { name: string; content: string; }

/**
 * logrotate snapin — manage /etc/logrotate.d/<name> drop-ins as structured
 * rules (log glob, frequency, rotate count, compress, size, …). A rule is
 * rendered to a logrotate stanza and written with the `copy` module; writes
 * honour dry-run. The same files are also policy-addressable (config policy on
 * /etc/logrotate.d/<name>) for fleet-wide rules — this is the per-host console.
 */
@Component({
  selector: 'app-logrotate',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-lr">
      @if (loading()) { <p class="bm-dim">Loading…</p> }
      @else {
        <div class="bm-head">
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>logrotate rules (/etc/logrotate.d)</h3></header>
          <table class="bm-t">
            <thead><tr><th>Name</th><th>Stanza</th><th></th></tr></thead>
            <tbody>
              @for (e of entries(); track e.name) {
                <tr>
                  <td class="bm-mono">{{ e.name }}</td>
                  <td class="bm-mono bm-stanza">{{ e.content }}</td>
                  <td>
                    <button class="bm-x" (click)="edit(e)" title="Load into the form">✎</button>
                    <button class="bm-x" (click)="remove(e)" [disabled]="busy()" title="Remove">✕</button>
                  </td>
                </tr>
              }
              @if (!entries().length) { <tr><td colspan="3" class="bm-dim">No logrotate drop-ins.</td></tr> }
            </tbody>
          </table>

          <div class="bm-form">
            <label class="bm-f">name<input placeholder="myapp" [value]="nName()" (input)="nName.set($any($event.target).value)" /></label>
            <label class="bm-f bm-grow">log path / glob<input placeholder="/var/log/myapp/*.log" [value]="nPath()" (input)="nPath.set($any($event.target).value)" /></label>
            <label class="bm-f">frequency
              <select [value]="nFreq()" (change)="nFreq.set($any($event.target).value)">
                <option value="daily">daily</option><option value="weekly">weekly</option>
                <option value="monthly">monthly</option><option value="yearly">yearly</option>
              </select>
            </label>
            <label class="bm-f">keep (rotate)<input type="number" [value]="nRotate()" (input)="nRotate.set(+$any($event.target).value)" /></label>
            <label class="bm-f">size<input placeholder="100M (optional)" [value]="nSize()" (input)="nSize.set($any($event.target).value)" /></label>
            <label class="bm-chk"><input type="checkbox" [checked]="nCompress()" (change)="nCompress.set($any($event.target).checked)" /> compress</label>
            <label class="bm-chk"><input type="checkbox" [checked]="nMissingok()" (change)="nMissingok.set($any($event.target).checked)" /> missingok</label>
            <label class="bm-chk"><input type="checkbox" [checked]="nNotifempty()" (change)="nNotifempty.set($any($event.target).checked)" /> notifempty</label>
            <label class="bm-f bm-grow">postrotate (optional)<input placeholder="systemctl reload myapp" [value]="nPostrotate()" (input)="nPostrotate.set($any($event.target).value)" /></label>
            <button mat-stroked-button (click)="save()" [disabled]="busy() || !nName().trim() || !nPath().trim()"><mat-icon>save</mat-icon> {{ dryRun() ? 'Preview' : 'Save rule' }}</button>
          </div>
          <pre class="bm-preview">{{ render() }}</pre>
          <p class="bm-hint">
            A rule becomes <code>/etc/logrotate.d/&lt;name&gt;</code>. <code>rotate</code> = how many old logs to keep;
            <code>size</code> rotates when the file exceeds it (in addition to the time interval). Common flags:
            <code>compress</code> (gzip old logs), <code>missingok</code> (don't error if absent),
            <code>notifempty</code> (skip empty logs), <code>postrotate</code> (a command run after rotation,
            e.g. reload the service). For fleet-wide rules, set the same file as a config policy on an OU/group.
          </p>
        </section>
      }
    </div>
  `,
  styles: [`
    .bm-lr { display: flex; flex-direction: column; gap: 16px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 4px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; vertical-align: top; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-stanza { white-space: pre-wrap; max-width: 460px; opacity: 0.8; }
    .bm-form { display: flex; gap: 10px; padding: 10px 14px; flex-wrap: wrap; align-items: flex-end; }
    .bm-f { font-size: 12px; display: flex; flex-direction: column; gap: 4px; }
    .bm-grow { flex: 1; min-width: 200px; }
    .bm-f input, .bm-f select { padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-chk { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-preview { margin: 0 14px 10px; padding: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 6px; font-size: 12px; font-family: ui-monospace, monospace; white-space: pre-wrap; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; font-size: 14px; }
    .bm-dim { opacity: 0.6; font-size: 13px; padding: 6px 8px; }
    .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
    .bm-hint { font-size: 12px; opacity: 0.72; padding: 0 14px 12px; line-height: 1.55; }
    .bm-hint code { font-family: ui-monospace, monospace; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 1px 5px; border-radius: 4px; }
  `],
})
export class LogrotateComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false); loaded = signal(false); busy = signal(false); dryRun = signal(false);
  msg = signal(''); err = signal('');
  entries = signal<LrEntry[]>([]);

  nName = signal(''); nPath = signal(''); nFreq = signal('daily'); nRotate = signal(7);
  nSize = signal(''); nCompress = signal(true); nMissingok = signal(true); nNotifempty = signal(true); nPostrotate = signal('');

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    const script = 'for f in /etc/logrotate.d/*; do [ -f "$f" ] && { echo "===FILE:$(basename "$f")"; cat "$f"; }; done';
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        this.entries.set(this.parse(out));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.entries.set([]); },
    });
  }

  private parse(text: string): LrEntry[] {
    const out: LrEntry[] = [];
    let cur: LrEntry | null = null;
    for (const line of text.split('\n')) {
      const m = /^===FILE:(.+)$/.exec(line);
      if (m) { if (cur) out.push(cur); cur = { name: m[1].trim(), content: '' }; continue; }
      if (cur) cur.content += (cur.content ? '\n' : '') + line;
    }
    if (cur) out.push(cur);
    return out.map((e) => ({ ...e, content: e.content.trim() }));
  }

  render(): string {
    const body: string[] = [`\t${this.nFreq()}`, `\trotate ${this.nRotate()}`];
    if (this.nSize().trim()) body.push(`\tsize ${this.nSize().trim()}`);
    if (this.nCompress()) { body.push('\tcompress'); body.push('\tdelaycompress'); }
    if (this.nMissingok()) body.push('\tmissingok');
    if (this.nNotifempty()) body.push('\tnotifempty');
    if (this.nPostrotate().trim()) body.push(`\tpostrotate\n\t\t${this.nPostrotate().trim()}\n\tendscript`);
    return `${this.nPath().trim() || '/var/log/…'} {\n${body.join('\n')}\n}`;
  }

  edit(e: LrEntry): void {
    this.nName.set(e.name);
    const path = /^(\S.*?)\s*\{/.exec(e.content);
    if (path) this.nPath.set(path[1].trim());
    for (const f of ['daily', 'weekly', 'monthly', 'yearly']) if (new RegExp(`(^|\\n)\\s*${f}\\b`).test(e.content)) this.nFreq.set(f);
    const rot = /rotate\s+(\d+)/.exec(e.content); if (rot) this.nRotate.set(+rot[1]);
    const sz = /(^|\n)\s*size\s+(\S+)/.exec(e.content); this.nSize.set(sz ? sz[2] : '');
    this.nCompress.set(/(^|\n)\s*compress\b/.test(e.content));
    this.nMissingok.set(/(^|\n)\s*missingok\b/.test(e.content));
    this.nNotifempty.set(/(^|\n)\s*notifempty\b/.test(e.content));
  }

  save(): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'copy', {
      dest: `/etc/logrotate.d/${this.nName().trim()}`, content: this.render() + '\n', mode: '0644', dry_run: this.dryRun(),
    }).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set((r.result as { msg?: string })?.msg || 'saved'); if (!this.dryRun()) this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'save failed'); },
    });
  }

  remove(e: LrEntry): void {
    if (this.dryRun()) { this.msg.set(`Would remove /etc/logrotate.d/${e.name}`); return; }
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['rm', '-f', `/etc/logrotate.d/${e.name}`] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`Removed ${e.name}.`); this.reload(); },
      error: (er) => { this.busy.set(false); this.err.set(er?.error?.detail || 'remove failed'); },
    });
  }
}
