import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { DirPickerComponent } from '../../../../shared/components/dir-picker/dir-picker.component';

interface VUser { name: string; home: string; }

const PASSWD = '/etc/proftpd/ftpd.passwd';
const CONF = '/etc/proftpd/proftpd.conf';

/**
 * ProFTPD snapin — manage virtual FTP users via an AuthUserFile (ftpd.passwd),
 * with each user's home directory (the share) chosen through the directory
 * browser. Adding the first user bootstraps proftpd.conf (AuthUserFile +
 * AuthOrder mod_auth_file + RequireValidShell off) so proftpd consults the
 * file. Passwords are hashed with `openssl passwd -6` (SHA-512 crypt), the
 * format mod_auth_file expects. Replaces the old key/value editor, which
 * mangled proftpd.conf's Apache-style <Block> markers into broken rows.
 */
@Component({
  selector: 'app-proftpd',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, DirPickerComponent],
  template: `
    <div class="bm-ftp">
      @if (loading()) { <p class="bm-dim">Loading virtual users…</p> }
      @else {
        <div class="bm-head">
          <span class="bm-dim">ProFTPD virtual users (AuthUserFile)</span>
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>Users</h3></header>
          <table class="bm-t">
            <thead><tr><th>Name</th><th>Home directory</th><th></th></tr></thead>
            <tbody>
              @for (u of users(); track u.name) {
                <tr><td class="bm-mono">{{ u.name }}</td><td class="bm-mono">{{ u.home }}</td>
                  <td><button class="bm-x" (click)="del(u)" [disabled]="busy()" title="Delete user">🗑</button></td></tr>
              }
              @if (!users().length) { <tr><td colspan="3" class="bm-dim">No virtual users yet.</td></tr> }
            </tbody>
          </table>
        </section>

        <section class="bm-card">
          <header><h3>Add virtual user</h3></header>
          <div class="bm-form">
            <label class="bm-fld">Name<input [value]="nName()" (input)="nName.set($any($event.target).value)" placeholder="alice" /></label>
            <label class="bm-fld bm-path">Home directory
              <app-dir-picker [agentId]="agentId()" [value]="nHome()" (valueChange)="nHome.set($event)" placeholder="/srv/ftp/alice" />
            </label>
            <label class="bm-fld">Password<input type="password" [value]="nPass()" (input)="nPass.set($any($event.target).value)" placeholder="••••••" /></label>
            <button mat-raised-button color="primary" (click)="add()" [disabled]="busy() || !nName().trim() || !nHome().trim() || !nPass()">Create user</button>
          </div>
        </section>
      }
    </div>
  `,
  styles: [`
    .bm-ftp { display: flex; flex-direction: column; gap: 14px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 5px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-form { padding: 12px 14px; display: flex; gap: 12px; flex-wrap: wrap; align-items: flex-end; }
    .bm-fld { display: flex; flex-direction: column; gap: 4px; font-size: 12px; }
    .bm-fld.bm-path { flex: 1; min-width: 260px; }
    .bm-fld input { padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font-size: 13px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; }
    .bm-dim { opacity: 0.6; font-size: 13px; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class ProftpdComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal(''); err = signal('');
  users = signal<VUser[]>([]);
  nName = signal(''); nHome = signal(''); nPass = signal('');

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', `cut -d: -f1,6 ${PASSWD} 2>/dev/null || true`] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        const us: VUser[] = [];
        for (const line of out.split('\n')) {
          const t = line.trim();
          if (!t || t.startsWith('#')) continue;
          const [name, home] = t.split(':');
          if (name) us.push({ name, home: home || '' });
        }
        this.users.set(us);
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.users.set([]); },
    });
  }

  add(): void {
    const name = this.nName().trim(), home = this.nHome().trim(), pass = this.nPass();
    const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
    const script =
      `set -e; mkdir -p ${q(home)}; touch ${PASSWD}; chmod 600 ${PASSWD}; ` +
      `HASH=$(openssl passwd -6 ${q(pass)}); ` +
      `grep -v ${q('^' + name + ':')} ${PASSWD} > ${PASSWD}.tmp 2>/dev/null || true; mv ${PASSWD}.tmp ${PASSWD}; ` +
      `printf '%s:%s:112:65534::%s:/usr/sbin/nologin\\n' ${q(name)} "$HASH" ${q(home)} >> ${PASSWD}; ` +
      `grep -q '^AuthUserFile' ${CONF} || printf '\\nAuthUserFile %s\\nAuthOrder mod_auth_file.c mod_auth_unix.c\\nRequireValidShell off\\n' ${PASSWD} >> ${CONF}; ` +
      `chown -R ftp:nogroup ${q(home)} 2>/dev/null || true; ` +
      `(systemctl restart proftpd 2>/dev/null || true)`;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: (resp) => {
        this.busy.set(false);
        const d = (resp.result as { data?: { rc?: number; stderr?: string } })?.data;
        if ((d?.rc ?? 0) !== 0) { this.err.set(d?.stderr || 'create failed'); return; }
        this.msg.set(`Created ${name}.`); this.nName.set(''); this.nHome.set(''); this.nPass.set(''); this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'create failed'); },
    });
  }

  del(u: VUser): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
    // `|| true` guards the grep exit-1 case (no lines remain when deleting the
    // last user), so the mv always runs and the file ends up correctly empty.
    const script = `{ grep -v ${q('^' + u.name + ':')} ${PASSWD} || true; } > ${PASSWD}.tmp; mv ${PASSWD}.tmp ${PASSWD}; systemctl restart proftpd 2>/dev/null || true`;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', script] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`Deleted ${u.name}.`); this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'delete failed'); },
    });
  }
}
