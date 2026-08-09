import { Component, computed, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { AccountGroup, AccountUser } from '../../../core/models/agent.model';
import { ConfigDialogService } from '../../../shared/config-dialog/config-dialog.service';

/** Block J4c, Cockpit-adaptation — the Accounts section restructured like
 * Cockpit's account-details (../cockpit/pkg/users): a users table where
 * selecting a user reveals a description-list detail card with per-facet
 * inline "Edit" (Full name, Shell, Groups) driven by the write-gated `user`
 * module, plus account actions (Lock/Unlock, Force password change, Terminate
 * session, Account expiration via the `command` module, and SSH authorized
 * keys via posix.authorized_key). Password *setting* is intentionally omitted —
 * the agent's user module refuses plaintext secrets to keep them out of the
 * tool-call audit log; "force change on next login" is the safe equivalent. */
@Component({
  selector: 'app-host-accounts',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatCheckboxModule, MatMenuModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
        <label class="bm-chk"><input type="checkbox" [checked]="showSystem()" (change)="showSystem.set($any($event.target).checked)" /> show system accounts</label>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else {
        <div class="bm-acct-grid">
          <div>
            <h4>Users ({{ visibleUsers().length }})</h4>
            <div class="bm-acct-new">
              <input type="text" placeholder="new username" [value]="newUser()" (input)="newUser.set($any($event.target).value)" />
              <button mat-button (click)="createUser()" [disabled]="busy() || !newUser().trim()">Create</button>
            </div>
            <table class="bm-mgmt-table">
              <thead><tr><th>Name</th><th>UID</th><th>Shell</th></tr></thead>
              <tbody>
                @for (u of visibleUsers(); track u.name) {
                  <tr class="bm-urow" [class.bm-sel]="selected() === u.name" (click)="select(u.name)">
                    <td class="bm-mgmt-unit">{{ u.name }}</td><td>{{ u.uid }}</td><td>{{ u.shell }}</td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
          <div>
            <h4>Groups ({{ visibleGroups().length }})</h4>
            <div class="bm-acct-new">
              <input type="text" placeholder="new group name" [value]="newGroup()" (input)="newGroup.set($any($event.target).value)" />
              <button mat-button (click)="createGroup()" [disabled]="busy() || !newGroup().trim()">Create</button>
            </div>
            <table class="bm-mgmt-table">
              <thead><tr><th>Name</th><th>GID</th><th>Members</th><th></th></tr></thead>
              <tbody>
                @for (g of visibleGroups(); track g.name) {
                  <tr>
                    <td class="bm-mgmt-unit">{{ g.name }}</td><td>{{ g.gid }}</td><td>{{ g.members.join(', ') }}</td>
                    <td><button mat-button color="warn" (click)="deleteGroup(g)" [disabled]="busy()">Delete</button></td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        </div>

        <!-- Account detail (Cockpit-style) -->
        @if (sel(); as u) {
          <section class="bm-card">
            <header class="bm-card-head">
              <mat-icon class="bm-uic">person</mat-icon>
              <h3>{{ u.name }}</h3>
              @if (u.system) { <span class="bm-tag">system</span> }
              <span class="bm-spacer"></span>
              @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
              @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
              <button mat-icon-button [matMenuTriggerFor]="acctMenu" [disabled]="busy()"><mat-icon>more_vert</mat-icon></button>
              <mat-menu #acctMenu="matMenu">
                <button mat-menu-item (click)="lock(u, true)"><mat-icon>lock</mat-icon> Lock account</button>
                <button mat-menu-item (click)="lock(u, false)"><mat-icon>lock_open</mat-icon> Unlock account</button>
                <button mat-menu-item (click)="forcePasswordChange(u)"><mat-icon>password</mat-icon> Force password change</button>
                <button mat-menu-item (click)="editExpiration(u)"><mat-icon>event_busy</mat-icon> Account expiration…</button>
                <button mat-menu-item (click)="terminate(u)"><mat-icon>logout</mat-icon> Terminate sessions</button>
                <button mat-menu-item class="bm-danger" (click)="deleteUser(u)"><mat-icon>delete</mat-icon> Delete account</button>
              </mat-menu>
            </header>
            <dl class="bm-dl">
              <div class="bm-dlrow">
                <dt>Full name</dt>
                <dd><span class="bm-dlval">{{ u.gecos || '—' }}</span><button mat-button class="bm-edit" (click)="editFullName(u)"><mat-icon>edit</mat-icon> Edit</button></dd>
              </div>
              <div class="bm-dlrow"><dt>User ID</dt><dd><span class="bm-dlval bm-mono">{{ u.uid }}</span></dd></div>
              <div class="bm-dlrow"><dt>Home</dt><dd><span class="bm-dlval bm-mono">{{ u.home }}</span></dd></div>
              <div class="bm-dlrow">
                <dt>Shell</dt>
                <dd><span class="bm-dlval bm-mono">{{ u.shell }}</span><button mat-button class="bm-edit" (click)="editShell(u)"><mat-icon>edit</mat-icon> Edit</button></dd>
              </div>
              <div class="bm-dlrow">
                <dt>Groups</dt>
                <dd><span class="bm-dlval">{{ userGroups(u).join(', ') || '—' }}</span><button mat-button class="bm-edit" (click)="editGroups(u)"><mat-icon>edit</mat-icon> Edit</button></dd>
              </div>
              <div class="bm-dlrow">
                <dt>SSH keys</dt>
                <dd><span class="bm-dlval bm-muted">managed via authorized_keys</span><button mat-button class="bm-edit" (click)="addSshKey(u)"><mat-icon>vpn_key</mat-icon> Add key</button></dd>
              </div>
            </dl>
          </section>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; display: flex; flex-direction: column; gap: 16px; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
      .bm-chk { font-size: 12px; color: var(--bm-muted, #888); display: flex; align-items: center; gap: 4px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-acct-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
      @media (max-width: 900px) { .bm-acct-grid { grid-template-columns: 1fr; } }
      .bm-acct-new { display: flex; gap: 8px; margin-bottom: 8px; }
      .bm-acct-new input { flex: 1; padding: 6px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 4px; background: var(--mat-sys-surface); color: inherit; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-urow { cursor: pointer; }
      .bm-urow:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
      .bm-card-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
      .bm-uic { opacity: 0.6; }
      .bm-spacer { flex: 1; }
      .bm-tag { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); opacity: 0.75; }
      .bm-dl { margin: 0; }
      .bm-dlrow { display: grid; grid-template-columns: 120px 1fr; align-items: center; padding: 9px 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-dlrow:first-child { border-top: none; }
      .bm-dlrow dt { font-size: 12.5px; opacity: 0.6; }
      .bm-dlrow dd { margin: 0; display: flex; align-items: center; gap: 10px; font-size: 13px; }
      .bm-dlval { flex: 1; }
      .bm-mono { font-family: monospace; }
      .bm-muted { opacity: 0.5; }
      .bm-edit { font-size: 12px; min-width: auto; }
      .bm-danger { color: #c62828; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostAccountsComponent {
  private agentService = inject(AgentService);
  private dialogs = inject(ConfigDialogService);

  agentId = input.required<string>();

  users = signal<AccountUser[]>([]);
  groups = signal<AccountGroup[]>([]);
  showSystem = signal(false);
  newUser = signal('');
  newGroup = signal('');
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);
  selected = signal<string | null>(null);

  visibleUsers = computed(() => (this.showSystem() ? this.users() : this.users().filter((u) => !u.system)));
  visibleGroups = computed(() => (this.showSystem() ? this.groups() : this.groups().filter((g) => !g.system)));

  sel = computed<AccountUser | null>(() => {
    const s = this.selected();
    return s ? (this.users().find((u) => u.name === s) ?? null) : null;
  });

  /** Secondary groups a user belongs to (derived from the group→members map). */
  userGroups(u: AccountUser): string[] {
    return this.groups().filter((g) => g.members.includes(u.name)).map((g) => g.name);
  }

  select(name: string): void {
    this.selected.set(this.selected() === name ? null : name);
    this.msg.set(null);
    this.err.set(null);
  }

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.accounts(this.agentId()).subscribe({
      next: (res) => {
        this.users.set(res.users ?? []);
        this.groups.set(res.groups ?? []);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load accounts');
      },
    });
  }

  private run(obs: any, ok: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    obs.subscribe({
      next: () => { this.busy.set(false); this.msg.set(ok); this.reload(); },
      error: (e: any) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'action failed'); },
    });
  }

  createUser(): void {
    const name = this.newUser().trim();
    if (!name) return;
    this.run(this.agentService.manageUser(this.agentId(), { name, state: 'present' }), `created user ${name}`);
    this.newUser.set('');
  }

  deleteUser(u: AccountUser): void {
    this.run(this.agentService.manageUser(this.agentId(), { name: u.name, state: 'absent', remove: true }), `removed user ${u.name}`);
    this.selected.set(null);
  }

  createGroup(): void {
    const name = this.newGroup().trim();
    if (!name) return;
    this.run(this.agentService.manageGroup(this.agentId(), { name, state: 'present' }), `created group ${name}`);
    this.newGroup.set('');
  }

  deleteGroup(g: AccountGroup): void {
    this.run(this.agentService.manageGroup(this.agentId(), { name: g.name, state: 'absent' }), `removed group ${g.name}`);
  }

  // ---- account-detail facet dialogs (via the shared config-dialog framework) ----

  editFullName(u: AccountUser): void {
    this.dialogs
      .open({
        title: `Full name — ${u.name}`,
        fields: [{ tag: 'comment', title: 'Full name', type: 'text', initial: u.gecos, placeholder: 'Jane Doe' }],
        action: (v) => this.agentService.manageUser(this.agentId(), { name: u.name, state: 'present', comment: String(v['comment'] ?? '') }),
      })
      .subscribe((r) => this.applied(r));
  }

  editShell(u: AccountUser): void {
    const common = ['/bin/bash', '/bin/sh', '/bin/zsh', '/usr/sbin/nologin', '/bin/false'];
    if (!common.includes(u.shell)) common.unshift(u.shell);
    this.dialogs
      .open({
        title: `Shell — ${u.name}`,
        fields: [{ tag: 'shell', title: 'Login shell', type: 'select', initial: u.shell, choices: common.map((s) => ({ value: s, title: s })) }],
        action: (v) => this.agentService.manageUser(this.agentId(), { name: u.name, state: 'present', shell: String(v['shell']) }),
      })
      .subscribe((r) => this.applied(r));
  }

  editGroups(u: AccountUser): void {
    this.dialogs
      .open({
        title: `Groups — ${u.name}`,
        body: 'Secondary groups (comma-separated). This replaces the full secondary-group set.',
        fields: [{ tag: 'groups', title: 'Groups', type: 'text', initial: this.userGroups(u).join(', '), placeholder: 'sudo, docker' }],
        action: (v) => this.agentService.manageUser(this.agentId(), {
          name: u.name, state: 'present',
          groups: String(v['groups'] ?? '').split(',').map((s) => s.trim()).filter(Boolean).join(','),
        }),
      })
      .subscribe((r) => this.applied(r));
  }

  editExpiration(u: AccountUser): void {
    this.dialogs
      .open({
        title: `Account expiration — ${u.name}`,
        fields: [
          { tag: 'mode', title: 'Expiration', type: 'radio', initial: 'never',
            choices: [{ value: 'never', title: 'Never expires' }, { value: 'date', title: 'Expire on date' }] },
          { tag: 'date', title: 'Date (YYYY-MM-DD)', type: 'text', placeholder: '2027-01-01', visible: (v) => v['mode'] === 'date',
            validate: (val, v) => (v['mode'] === 'date' && !/^\d{4}-\d{2}-\d{2}$/.test(String(val || '')) ? 'Use YYYY-MM-DD' : null) },
        ],
        action: (v) => this.command(['chage', '-E', v['mode'] === 'date' ? String(v['date']) : '-1', u.name]),
      })
      .subscribe((r) => this.applied(r));
  }

  addSshKey(u: AccountUser): void {
    this.dialogs
      .open({
        title: `Add SSH key — ${u.name}`,
        body: `Appends a public key to ${u.home}/.ssh/authorized_keys.`,
        fields: [{ tag: 'key', title: 'Public key', type: 'text', placeholder: 'ssh-ed25519 AAAA… comment',
          validate: (val) => (String(val || '').trim().startsWith('ssh-') ? null : 'Must be an OpenSSH public key (ssh-…)') }],
        action: (v) => this.agentService.callTool(this.agentId(), 'posix.authorized_key', { user: u.name, key: String(v['key']).trim(), state: 'present' }),
      })
      .subscribe((r) => this.applied(r));
  }

  lock(u: AccountUser, locked: boolean): void {
    this.run(this.command(['usermod', locked ? '-L' : '-U', u.name]), `${locked ? 'locked' : 'unlocked'} ${u.name}`);
  }

  forcePasswordChange(u: AccountUser): void {
    this.run(this.command(['chage', '-d', '0', u.name]), `${u.name} must change password at next login`);
  }

  terminate(u: AccountUser): void {
    this.run(this.command(['loginctl', 'terminate-user', u.name]), `terminated sessions for ${u.name}`);
  }

  /** Run a shell command via the generic `command` module. */
  private command(argv: string[]) {
    return this.agentService.callTool(this.agentId(), 'command', { argv });
  }

  private applied(r: unknown): void {
    if (r) { this.msg.set('applied'); this.reload(); }
  }
}
