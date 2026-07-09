import { Component, computed, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { AccountGroup, AccountUser } from '../../../core/models/agent.model';

/** Block J4c — the Accounts section: users + groups from the read-only
 * `getent` module, with create/delete via the write-gated user/group modules.
 * System accounts (uid/gid < 1000) are hidden by default. */
@Component({
  selector: 'app-host-accounts',
  standalone: true,
  imports: [MatButtonModule, MatCheckboxModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <button mat-stroked-button (click)="reload()" [disabled]="loading()">Reload</button>
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
              <thead><tr><th>Name</th><th>UID</th><th>Home</th><th>Shell</th><th></th></tr></thead>
              <tbody>
                @for (u of visibleUsers(); track u.name) {
                  <tr>
                    <td class="bm-mgmt-unit">{{ u.name }}</td><td>{{ u.uid }}</td><td>{{ u.home }}</td><td>{{ u.shell }}</td>
                    <td><button mat-button color="warn" (click)="deleteUser(u)" [disabled]="busy()">Delete</button></td>
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
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-chk { font-size: 12px; color: var(--bm-muted, #888); display: flex; align-items: center; gap: 4px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-acct-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
      @media (max-width: 900px) { .bm-acct-grid { grid-template-columns: 1fr; } }
      .bm-acct-new { display: flex; gap: 8px; margin-bottom: 8px; }
      .bm-acct-new input { flex: 1; padding: 6px 8px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--bm-border, #eee); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostAccountsComponent {
  private agentService = inject(AgentService);

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

  visibleUsers = computed(() => (this.showSystem() ? this.users() : this.users().filter((u) => !u.system)));
  visibleGroups = computed(() => (this.showSystem() ? this.groups() : this.groups().filter((g) => !g.system)));

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
      next: () => {
        this.busy.set(false);
        this.msg.set(ok);
        this.reload();
      },
      error: (e: any) => {
        this.busy.set(false);
        this.err.set(e?.error?.detail ?? 'action failed');
      },
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
}
