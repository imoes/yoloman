import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';

interface CronJob { name: string; schedule: string; job: string; managed: boolean; }
interface Timer { unit: string; next: string; left: string; activates: string; }

const MARKER = '#Ansible: ';

/**
 * Scheduled-jobs snapin — manage the classic crontab (CRUD via the `cron`
 * agent module, entries tracked by a "#Ansible: <name>" marker) and view/
 * create/delete systemd timers (unit pair written via the `copy` module +
 * daemon-reload + enable). Cron writes default to dry-run.
 */
@Component({
  selector: 'app-cron',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-cron">
      @if (loading()) { <p class="bm-dim">Loading…</p> }
      @else {
        <div class="bm-head">
          <label class="bm-f">crontab user
            <input [value]="user()" (input)="user.set($any($event.target).value)" (keyup.enter)="reload()" />
          </label>
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
          <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>Cron jobs ({{ user() }})</h3></header>
          <table class="bm-t">
            <thead><tr><th>Name</th><th>Schedule (m h dom mon dow)</th><th>Command</th><th></th></tr></thead>
            <tbody>
              @for (j of jobs(); track $index) {
                <tr>
                  <td>{{ j.name }}@if (!j.managed) { <span class="bm-tag">unmanaged</span> }</td>
                  <td class="bm-mono">{{ j.schedule }}</td>
                  <td class="bm-mono">{{ j.job }}</td>
                  <td>@if (j.managed) { <button class="bm-x" (click)="removeJob(j)" [disabled]="busy()" title="Remove">✕</button> }</td>
                </tr>
              }
              @if (!jobs().length) { <tr><td colspan="4" class="bm-dim">No cron entries.</td></tr> }
            </tbody>
          </table>
          <div class="bm-add">
            <input class="bm-in-name" placeholder="name" [value]="nName()" (input)="nName.set($any($event.target).value)" />
            <input class="bm-in-sched" placeholder="*/5 * * * *" [value]="nSched()" (input)="nSched.set($any($event.target).value)" />
            <input class="bm-in-job" placeholder="/usr/local/bin/backup.sh" [value]="nJob()" (input)="nJob.set($any($event.target).value)" />
            <button mat-stroked-button (click)="addJob()" [disabled]="busy() || !nName().trim() || !nJob().trim()"><mat-icon>add</mat-icon> {{ dryRun() ? 'Preview' : 'Add' }}</button>
          </div>
          <p class="bm-hint">
            Schedule = five space-separated fields <code>minute&nbsp;hour&nbsp;day-of-month&nbsp;month&nbsp;day-of-week</code>.
            Each field is <code>*</code> (every), a number, a list <code>1,15</code>, a range <code>9-17</code>,
            or a step <code>*/5</code> (every 5). Examples: <code>*/5 * * * *</code> = every 5&nbsp;min ·
            <code>0 2 * * *</code> = daily 02:00 · <code>30 8 * * 1-5</code> = 08:30 on weekdays ·
            <code>0 0 1 * *</code> = 1st of each month. Or a named schedule: <code>&#64;hourly</code>,
            <code>&#64;daily</code>, <code>&#64;weekly</code>, <code>&#64;monthly</code>, <code>&#64;reboot</code>.
          </p>
        </section>

        <section class="bm-card">
          <header class="bm-cardhead"><h3>systemd timers</h3><button mat-button (click)="loadTimers()" [disabled]="busy()"><mat-icon>refresh</mat-icon> Refresh</button></header>
          <table class="bm-t">
            <thead><tr><th>Unit</th><th>Next run</th><th>Left</th><th>Activates</th><th></th></tr></thead>
            <tbody>
              @for (t of timers(); track t.unit) {
                <tr>
                  <td class="bm-mono">{{ t.unit }}</td><td>{{ t.next }}</td><td>{{ t.left }}</td><td class="bm-mono">{{ t.activates }}</td>
                  <td><button class="bm-x" (click)="deleteTimer(t)" [disabled]="busy()" title="Delete timer">🗑</button></td>
                </tr>
              }
              @if (!timers().length) { <tr><td colspan="5" class="bm-dim">No timers.</td></tr> }
            </tbody>
          </table>
          <div class="bm-add">
            <input class="bm-in-name" placeholder="name" [value]="tName()" (input)="tName.set($any($event.target).value)" />
            <input class="bm-in-sched" placeholder="OnCalendar e.g. daily / *-*-* 02:00" [value]="tCal()" (input)="tCal.set($any($event.target).value)" />
            <input class="bm-in-job" placeholder="ExecStart e.g. /usr/local/bin/job.sh" [value]="tExec()" (input)="tExec.set($any($event.target).value)" />
            <button mat-stroked-button (click)="createTimer()" [disabled]="busy() || !tName().trim() || !tCal().trim() || !tExec().trim()"><mat-icon>add</mat-icon> Create timer</button>
          </div>
          <p class="bm-hint">
            <code>OnCalendar</code> uses systemd's calendar syntax <code>DOW YYYY-MM-DD HH:MM:SS</code> (unset parts = every).
            Examples: <code>daily</code> / <code>weekly</code> / <code>hourly</code> (shortcuts) ·
            <code>*-*-* 02:00</code> = every day 02:00 · <code>Mon *-*-* 09:00</code> = Mondays 09:00 ·
            <code>*-*-01 00:00</code> = 1st of month · <code>*:0/15</code> = every 15&nbsp;min.
          </p>
        </section>
      }
    </div>
  `,
  styles: [`
    .bm-cron { display: flex; flex-direction: column; gap: 16px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; } .bm-f { font-size: 13px; display: flex; align-items: center; gap: 6px; }
    .bm-f input { width: 100px; padding: 5px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header, .bm-cardhead { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); display: flex; align-items: center; justify-content: space-between; }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 4px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-tag { font-size: 10px; opacity: 0.6; margin-left: 6px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 1px 6px; }
    .bm-add { display: flex; gap: 8px; padding: 10px 14px; flex-wrap: wrap; align-items: center; }
    .bm-add input { padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
    .bm-in-name { width: 130px; } .bm-in-sched { width: 190px; } .bm-in-job { flex: 1; min-width: 180px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; }
    .bm-dim { opacity: 0.6; font-size: 13px; padding: 6px 8px; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
    .bm-hint { font-size: 12px; opacity: 0.72; padding: 0 14px 12px; line-height: 1.55; }
    .bm-hint code { font-family: ui-monospace, monospace; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 1px 5px; border-radius: 4px; white-space: nowrap; }
  `],
})
export class CronComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  dryRun = signal(false);
  msg = signal(''); err = signal('');
  user = signal('root');
  jobs = signal<CronJob[]>([]);
  timers = signal<Timer[]>([]);

  nName = signal(''); nSched = signal(''); nJob = signal('');
  tName = signal(''); tCal = signal(''); tExec = signal('');

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['crontab', '-l', '-u', this.user().trim() || 'root'] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        this.jobs.set(this.parseCrontab(out));
        this.loadTimers();
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.jobs.set([]); this.loadTimers(); },
    });
  }

  private parseCrontab(text: string): CronJob[] {
    const lines = text.split('\n');
    const out: CronJob[] = [];
    let pendingName = '';
    for (const raw of lines) {
      const line = raw.trimEnd();
      if (line.startsWith(MARKER)) { pendingName = line.slice(MARKER.length).trim(); continue; }
      if (!line.trim() || line.trimStart().startsWith('#')) { pendingName = ''; continue; }
      // schedule = first 5 fields (or @special), rest = command
      const m = /^(@\w+|(?:\S+\s+){5})(.*)$/.exec(line.trim());
      const schedule = m ? m[1].trim() : line.trim();
      const job = m ? m[2].trim() : '';
      out.push({ name: pendingName || '(inline)', schedule, job, managed: !!pendingName });
      pendingName = '';
    }
    return out;
  }

  addJob(): void {
    const parts = this.nSched().trim().split(/\s+/);
    const p: Record<string, unknown> = { name: this.nName().trim(), job: this.nJob().trim(), user: this.user().trim() || 'root', state: 'present', dry_run: this.dryRun() };
    if (this.nSched().trim().startsWith('@')) {
      p['special_time'] = this.nSched().trim().slice(1);
    } else if (parts.length === 5) {
      p['minute'] = parts[0]; p['hour'] = parts[1]; p['day'] = parts[2]; p['month'] = parts[3]; p['weekday'] = parts[4];
    }
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'cron', p).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set((r.result as { msg?: string })?.msg || 'ok'); this.nName.set(''); this.nSched.set(''); this.nJob.set(''); if (!this.dryRun()) this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'add failed'); },
    });
  }

  removeJob(j: CronJob): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'cron', { name: j.name, user: this.user().trim() || 'root', state: 'absent', dry_run: this.dryRun() }).subscribe({
      next: (r) => { this.busy.set(false); this.msg.set((r.result as { msg?: string })?.msg || 'removed'); if (!this.dryRun()) this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'remove failed'); },
    });
  }

  loadTimers(): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['systemctl', 'list-timers', '--all', '--no-pager', '--no-legend'] }).subscribe({
      next: (resp) => {
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        const ts: Timer[] = [];
        for (const line of out.split('\n')) {
          const c = line.trim().split(/\s{2,}/);
          if (c.length >= 6 && c[c.length - 1].includes('.service') || (c.length >= 5 && c.some((x) => x.includes('.timer')))) {
            const unit = c.find((x) => x.includes('.timer')) || '';
            const activates = c.find((x) => x.includes('.service')) || '';
            if (unit) ts.push({ unit, next: c[0] || '', left: c[3] || '', activates });
          }
        }
        this.timers.set(ts);
      },
      error: () => this.timers.set([]),
    });
  }

  createTimer(): void {
    const name = this.tName().trim().replace(/\.(timer|service)$/, '');
    const svc = `[Unit]\nDescription=${name} (managed by agentic-mcp)\n\n[Service]\nType=oneshot\nExecStart=${this.tExec().trim()}\n`;
    const timer = `[Unit]\nDescription=${name} timer (managed by agentic-mcp)\n\n[Timer]\nOnCalendar=${this.tCal().trim()}\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n`;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    // write both units, daemon-reload, enable --now the timer
    this.agentService.callTool(this.agentId(), 'copy', { dest: `/etc/systemd/system/${name}.service`, content: svc, mode: '0644' }).subscribe({
      next: () => this.agentService.callTool(this.agentId(), 'copy', { dest: `/etc/systemd/system/${name}.timer`, content: timer, mode: '0644' }).subscribe({
        next: () => this.agentService.callTool(this.agentId(), 'command', { argv: ['systemctl', 'daemon-reload'] }).subscribe({
          next: () => this.agentService.callTool(this.agentId(), 'systemd', { name: `${name}.timer`, state: 'started', enabled: true }).subscribe({
            next: () => { this.busy.set(false); this.msg.set(`Timer ${name}.timer created + enabled.`); this.tName.set(''); this.tCal.set(''); this.tExec.set(''); this.loadTimers(); },
            error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'enable failed'); },
          }),
          error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'daemon-reload failed'); },
        }),
        error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'write .timer failed'); },
      }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'write .service failed'); },
    });
  }

  deleteTimer(t: Timer): void {
    const name = t.unit.replace(/\.timer$/, '');
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const script = `systemctl disable --now ${name}.timer 2>/dev/null; rm -f /etc/systemd/system/${name}.timer /etc/systemd/system/${name}.service; systemctl daemon-reload`;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`Timer ${name}.timer deleted.`); this.loadTimers(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'delete failed'); },
    });
  }
}
