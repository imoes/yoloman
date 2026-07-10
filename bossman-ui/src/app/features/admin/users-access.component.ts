import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AccessService } from '../../core/services/access.service';
import { AgentService } from '../../core/services/agent.service';
import { HostGroupService } from '../../core/services/host-group.service';
import { AuthService } from '../../core/auth/auth.service';
import {
  AccessGrant,
  ApiTokenRow,
  BossmanUser,
  GrantScope,
  SubjectKind,
  UserRole,
} from '../../core/models/access.model';
import { Agent } from '../../core/models/agent.model';
import { HostGroup } from '../../core/models/host-group.model';

/** Block M — Users & Access (admin-only). Manage human users and their
 * role, machine API tokens, and the per-host/group access grants that
 * back require_manage_agent: admin manages everything, operator and
 * api_token manage only what a grant covers (a wildcard "all" grant keeps
 * automation working). Nav entry + route are gated on the caller's admin
 * role; the backend re-enforces require_admin regardless. */
@Component({
  selector: 'app-users-access',
  standalone: true,
  imports: [
    DatePipe,
    FormsModule,
    MatCardModule,
    MatButtonModule,
    MatIconModule,
    MatFormFieldModule,
    MatInputModule,
    MatSelectModule,
  ],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Users &amp; Access</h1>
      </div>
      <p class="bm-subtitle">
        Manage human users, machine API tokens, and who may manage which hosts. Admins manage
        everything; operators and API tokens manage only what a grant covers.
      </p>

      @if (error()) {
        <div class="bm-error">{{ error() }}</div>
      }

      <!-- ── Users ─────────────────────────────────────────────── -->
      <mat-card class="bm-panel">
        <mat-card-header><mat-card-title>Users</mat-card-title></mat-card-header>
        <mat-card-content>
          <div class="bm-inline-form">
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>Username</mat-label>
              <input matInput [(ngModel)]="nuName" autocomplete="off" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>Password</mat-label>
              <input matInput type="password" [(ngModel)]="nuPass" autocomplete="new-password" />
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-ff bm-ff-sm">
              <mat-label>Role</mat-label>
              <mat-select [(ngModel)]="nuRole">
                <mat-option value="operator">operator</mat-option>
                <mat-option value="admin">admin</mat-option>
              </mat-select>
            </mat-form-field>
            <button mat-raised-button color="primary" (click)="addUser()" [disabled]="!nuName().trim() || !nuPass()">
              <mat-icon>person_add</mat-icon> Add user
            </button>
          </div>

          @if (users().length) {
            <table class="bm-table">
              <thead><tr><th>Username</th><th>Role</th><th>Created</th><th></th></tr></thead>
              <tbody>
                @for (u of users(); track u.id) {
                  <tr>
                    <td class="bm-mono">{{ u.username }}</td>
                    <td>
                      <mat-select class="bm-role-select" [ngModel]="u.role" (ngModelChange)="setRole(u, $event)">
                        <mat-option value="operator">operator</mat-option>
                        <mat-option value="admin">admin</mat-option>
                      </mat-select>
                    </td>
                    <td class="bm-dim">{{ u.created_at ? (u.created_at | date: 'short') : '—' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="removeUser(u)" [disabled]="u.username === me()">Delete</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-dim">No users yet.</p>
          }
        </mat-card-content>
      </mat-card>

      <!-- ── API tokens ────────────────────────────────────────── -->
      <mat-card class="bm-panel">
        <mat-card-header><mat-card-title>API tokens</mat-card-title></mat-card-header>
        <mat-card-content>
          <div class="bm-inline-form">
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>Token name</mat-label>
              <input matInput [(ngModel)]="ntName" autocomplete="off" />
            </mat-form-field>
            <button mat-raised-button color="primary" (click)="addToken()" [disabled]="!ntName().trim()">
              <mat-icon>vpn_key</mat-icon> Create token
            </button>
          </div>

          @if (newTokenSecret()) {
            <div class="bm-secret">
              <mat-icon>content_copy</mat-icon>
              <span
                >New token — copy it now, it is shown only once:
                <code class="bm-mono">{{ newTokenSecret() }}</code></span
              >
              <button mat-button (click)="newTokenSecret.set(null)">Dismiss</button>
            </div>
          }

          @if (tokens().length) {
            <table class="bm-table">
              <thead><tr><th>Name</th><th>Created</th><th>Status</th><th></th></tr></thead>
              <tbody>
                @for (t of tokens(); track t.id) {
                  <tr [class.bm-revoked]="t.revoked">
                    <td class="bm-mono">{{ t.name }}</td>
                    <td class="bm-dim">{{ t.created_at ? (t.created_at | date: 'short') : '—' }}</td>
                    <td>{{ t.revoked ? 'revoked' : 'active' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="revoke(t)" [disabled]="t.revoked">Revoke</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-dim">No API tokens yet.</p>
          }
        </mat-card-content>
      </mat-card>

      <!-- ── Access grants ─────────────────────────────────────── -->
      <mat-card class="bm-panel">
        <mat-card-header><mat-card-title>Access grants</mat-card-title></mat-card-header>
        <mat-card-content>
          <p class="bm-subtitle">
            A grant lets a subject (user or API token) manage hosts: <b>all</b> hosts, one specific
            <b>host</b>, or every host in a <b>host group</b>.
          </p>
          <div class="bm-inline-form">
            <mat-form-field appearance="outline" class="bm-ff bm-ff-sm">
              <mat-label>Subject kind</mat-label>
              <mat-select [(ngModel)]="ngKind">
                <mat-option value="user">user</mat-option>
                <mat-option value="api_token">api_token</mat-option>
              </mat-select>
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-ff">
              <mat-label>Subject</mat-label>
              <mat-select [(ngModel)]="ngRef">
                @if (ngKind() === 'user') {
                  @for (u of users(); track u.id) {
                    <mat-option [value]="u.username">{{ u.username }}</mat-option>
                  }
                } @else {
                  @for (t of tokens(); track t.id) {
                    <mat-option [value]="t.name">{{ t.name }}</mat-option>
                  }
                }
              </mat-select>
            </mat-form-field>
            <mat-form-field appearance="outline" class="bm-ff bm-ff-sm">
              <mat-label>Scope</mat-label>
              <mat-select [(ngModel)]="ngScope">
                <mat-option value="all">all hosts</mat-option>
                <mat-option value="host">one host</mat-option>
                <mat-option value="host_group">host group</mat-option>
              </mat-select>
            </mat-form-field>
            @if (ngScope() === 'host') {
              <mat-form-field appearance="outline" class="bm-ff">
                <mat-label>Host</mat-label>
                <mat-select [(ngModel)]="ngAgentId">
                  @for (a of agents(); track a.id) {
                    <mat-option [value]="a.id">{{ a.name }}</mat-option>
                  }
                </mat-select>
              </mat-form-field>
            }
            @if (ngScope() === 'host_group') {
              <mat-form-field appearance="outline" class="bm-ff">
                <mat-label>Host group</mat-label>
                <mat-select [(ngModel)]="ngGroupId">
                  @for (g of groups(); track g.id) {
                    <mat-option [value]="g.id">{{ g.name }}</mat-option>
                  }
                </mat-select>
              </mat-form-field>
            }
            <button mat-raised-button color="primary" (click)="addGrant()" [disabled]="!grantValid()">
              <mat-icon>add_moderator</mat-icon> Grant
            </button>
          </div>

          @if (grants().length) {
            <table class="bm-table">
              <thead><tr><th>Subject</th><th>Kind</th><th>Scope</th><th>Target</th><th></th></tr></thead>
              <tbody>
                @for (g of grants(); track g.id) {
                  <tr>
                    <td class="bm-mono">{{ g.subject_ref }}</td>
                    <td>{{ g.subject_kind }}</td>
                    <td>{{ g.scope }}</td>
                    <td class="bm-dim">{{ targetLabel(g) }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="removeGrant(g)">Revoke</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-dim">No grants yet — only admins can manage hosts until a grant is added.</p>
          }
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-inline-form {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 0.75rem;
        margin-bottom: 1rem;
      }
      .bm-ff {
        width: 220px;
      }
      .bm-ff-sm {
        width: 150px;
      }
      .bm-role-select {
        min-width: 110px;
      }
      .bm-secret {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.5rem 0.75rem;
        margin-bottom: 1rem;
        border-radius: 6px;
        background: rgba(255, 193, 7, 0.12);
        border: 1px solid rgba(255, 193, 7, 0.4);
      }
      .bm-secret code {
        user-select: all;
      }
      .bm-revoked {
        opacity: 0.5;
      }
      .bm-error {
        color: #d32f2f;
        margin-bottom: 1rem;
      }
    `,
  ],
})
export class UsersAccessComponent implements OnInit {
  private access = inject(AccessService);
  private agentSvc = inject(AgentService);
  private groupSvc = inject(HostGroupService);
  private auth = inject(AuthService);

  users = signal<BossmanUser[]>([]);
  tokens = signal<ApiTokenRow[]>([]);
  grants = signal<AccessGrant[]>([]);
  agents = signal<Agent[]>([]);
  groups = signal<HostGroup[]>([]);
  error = signal<string | null>(null);
  newTokenSecret = signal<string | null>(null);
  me = computed(() => this.auth.username());

  // create-user form
  nuName = signal('');
  nuPass = signal('');
  nuRole = signal<UserRole>('operator');

  // create-token form
  ntName = signal('');

  // create-grant form
  ngKind = signal<SubjectKind>('user');
  ngRef = signal<string>('');
  ngScope = signal<GrantScope>('all');
  ngAgentId = signal<string>('');
  ngGroupId = signal<string>('');

  grantValid = computed(() => {
    if (!this.ngRef()) return false;
    if (this.ngScope() === 'host') return !!this.ngAgentId();
    if (this.ngScope() === 'host_group') return !!this.ngGroupId();
    return true;
  });

  ngOnInit(): void {
    this.reloadAll();
    this.agentSvc.list().subscribe({ next: (a) => this.agents.set(a) });
    this.groupSvc.list().subscribe({ next: (g) => this.groups.set(g) });
  }

  private reloadAll(): void {
    this.access.listUsers().subscribe({ next: (r) => this.users.set(r.users), error: (e) => this.fail(e) });
    this.access.listTokens().subscribe({ next: (r) => this.tokens.set(r.tokens), error: (e) => this.fail(e) });
    this.access.listGrants().subscribe({ next: (r) => this.grants.set(r.grants), error: (e) => this.fail(e) });
  }

  private fail(e: unknown): void {
    const detail = (e as { error?: { detail?: string }; message?: string })?.error?.detail;
    this.error.set(detail ?? (e as { message?: string })?.message ?? 'Request failed');
  }

  addUser(): void {
    this.error.set(null);
    this.access.createUser({ username: this.nuName().trim(), password: this.nuPass(), role: this.nuRole() }).subscribe({
      next: () => {
        this.nuName.set('');
        this.nuPass.set('');
        this.reloadAll();
      },
      error: (e) => this.fail(e),
    });
  }

  setRole(u: BossmanUser, role: UserRole): void {
    if (role === u.role) return;
    this.access.updateUser(u.username, { role }).subscribe({ next: () => this.reloadAll(), error: (e) => this.fail(e) });
  }

  removeUser(u: BossmanUser): void {
    if (!confirm(`Delete user ${u.username}?`)) return;
    this.access.deleteUser(u.username).subscribe({ next: () => this.reloadAll(), error: (e) => this.fail(e) });
  }

  addToken(): void {
    this.error.set(null);
    this.access.createToken(this.ntName().trim()).subscribe({
      next: (t) => {
        this.newTokenSecret.set(t.token);
        this.ntName.set('');
        this.reloadAll();
      },
      error: (e) => this.fail(e),
    });
  }

  revoke(t: ApiTokenRow): void {
    if (!confirm(`Revoke token ${t.name}?`)) return;
    this.access.revokeToken(t.id).subscribe({ next: () => this.reloadAll(), error: (e) => this.fail(e) });
  }

  addGrant(): void {
    this.error.set(null);
    this.access
      .createGrant({
        subject_kind: this.ngKind(),
        subject_ref: this.ngRef(),
        scope: this.ngScope(),
        agent_id: this.ngScope() === 'host' ? this.ngAgentId() : null,
        host_group_id: this.ngScope() === 'host_group' ? this.ngGroupId() : null,
      })
      .subscribe({
        next: () => {
          this.ngAgentId.set('');
          this.ngGroupId.set('');
          this.reloadAll();
        },
        error: (e) => this.fail(e),
      });
  }

  removeGrant(g: AccessGrant): void {
    this.access.deleteGrant(g.id).subscribe({ next: () => this.reloadAll(), error: (e) => this.fail(e) });
  }

  targetLabel(g: AccessGrant): string {
    if (g.scope === 'all') return 'all hosts';
    if (g.scope === 'host') return this.agents().find((a) => a.id === g.agent_id)?.name ?? g.agent_id ?? '?';
    if (g.scope === 'host_group') return this.groups().find((x) => x.id === g.host_group_id)?.name ?? g.host_group_id ?? '?';
    return '';
  }
}
