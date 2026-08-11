import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

export interface ProvisionDbData { consumerAgentId: string; consumerName: string; }
interface AgentRow { id: string; name: string; address?: string | null; }
interface SecretRef { source: string; scope_type: string; scope: string; key: string; }

/**
 * Provision a database credential for THIS host (the consumer): create a DB + user
 * on a provider host and store the credential in this host's variables as a vault
 * handle. The password can be generated, entered, or taken from an existing vault
 * secret — the admin credentials are used only for the call and never stored.
 */
@Component({
  selector: 'app-provision-db-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Provision database credential — {{ data.consumerName }}</h2>
    <mat-dialog-content>
      <p class="pd-dim">Creates a database + user on the provider and stores the credential in
        <strong>{{ data.consumerName }}</strong>’s variables (password as an encrypted vault handle).
        The admin login is used only for this action and never saved.</p>

      <div class="pd-grid">
        <label class="pd-f"><span>Provider host (where the DB runs)</span>
          <select [ngModel]="providerId()" (ngModelChange)="providerId.set($event)">
            <option value="" disabled>— pick a host —</option>
            @for (a of agents(); track a.id) { <option [value]="a.id">{{ a.name }}</option> }
          </select>
        </label>
        <label class="pd-f"><span>Backend</span>
          <select [ngModel]="backend()" (ngModelChange)="backend.set($event)">
            <option value="mysql">mysql</option><option value="mariadb">mariadb</option>
          </select>
        </label>
        <label class="pd-f"><span>Run via</span>
          <select [ngModel]="execMode()" (ngModelChange)="execMode.set($event)">
            <option value="local">host (mysql on the host)</option>
            <option value="docker">docker exec (container)</option>
          </select>
        </label>
        @if (execMode() === 'docker') {
          <label class="pd-f"><span>Container name</span>
            <input [ngModel]="container()" (ngModelChange)="container.set($event)" placeholder="db" />
          </label>
        }
        <label class="pd-f"><span>DB admin user</span>
          <input [ngModel]="adminUser()" (ngModelChange)="adminUser.set($event)" placeholder="root" />
        </label>
        <label class="pd-f"><span>DB admin password</span>
          <input type="password" [ngModel]="adminPassword()" (ngModelChange)="adminPassword.set($event)" />
        </label>
        <label class="pd-f"><span>Database name</span>
          <input [ngModel]="dbName()" (ngModelChange)="dbName.set($event)" placeholder="appdb" />
        </label>
        <label class="pd-f"><span>App user</span>
          <input [ngModel]="dbUser()" (ngModelChange)="dbUser.set($event)" placeholder="app" />
        </label>
      </div>

      <div class="pd-sec">Password for the app user</div>
      <div class="pd-modes">
        <label><input type="radio" name="pwmode" value="generate" [ngModel]="mode()" (ngModelChange)="mode.set($event)" /> Generate a secure password</label>
        <label><input type="radio" name="pwmode" value="custom" [ngModel]="mode()" (ngModelChange)="mode.set($event)" /> Enter my own</label>
        <label><input type="radio" name="pwmode" value="existing" [ngModel]="mode()" (ngModelChange)="mode.set($event)" /> Use an existing vault secret</label>
      </div>
      @if (mode() === 'custom') {
        <label class="pd-f"><span>Password</span>
          <input type="password" [ngModel]="customPw()" (ngModelChange)="customPw.set($event)" /></label>
      }
      @if (mode() === 'existing') {
        <label class="pd-f"><span>Existing secret</span>
          <select [ngModel]="existingIdx()" (ngModelChange)="existingIdx.set(+$event)">
            <option [value]="-1" disabled>— pick a stored secret —</option>
            @for (s of secrets(); track $index) {
              <option [value]="$index">{{ s.scope }} · {{ s.key }} ({{ s.scope_type }})</option>
            }
          </select>
        </label>
        @if (!secrets().length) { <p class="pd-dim">No stored secrets yet — generate or enter one instead.</p> }
      }

      <div class="pd-sec">Store into these variables of {{ data.consumerName }}</div>
      <div class="pd-grid">
        <label class="pd-f"><span>host key</span><input [ngModel]="tName()" (ngModelChange)="tName.set($event)" /></label>
        <label class="pd-f"><span>user key</span><input [ngModel]="tUser()" (ngModelChange)="tUser.set($event)" /></label>
        <label class="pd-f"><span>password key</span><input [ngModel]="tPass()" (ngModelChange)="tPass.set($event)" /></label>
      </div>

      @if (error()) { <p class="pd-err">{{ error() }}</p> }
      @if (result(); as r) { <p class="pd-ok">Provisioned DB “{{ r.database }}”, user “{{ r.user }}” ({{ r.password_mode }}); stored {{ r.stored_keys?.length }} variable(s).</p> }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="ref.close(false)">Close</button>
      <button mat-raised-button color="primary" (click)="run()" [disabled]="busy() || !canRun()">
        <mat-icon>key</mat-icon> {{ busy() ? 'Provisioning…' : 'Provision' }}
      </button>
    </mat-dialog-actions>
  `,
  styles: [`
    .pd-dim { opacity:.7; font-size:13px; max-width:560px; line-height:1.5; }
    .pd-err { color: var(--mat-sys-error,#c62828); } .pd-ok { color:#66bb6a; }
    .pd-grid { display:grid; grid-template-columns:1fr 1fr; gap:8px 12px; margin:8px 0; }
    .pd-f { display:flex; flex-direction:column; gap:3px; font-size:12px; }
    .pd-f span { opacity:.7; } .pd-f input, .pd-f select { padding:6px 8px; border:1px solid var(--mat-sys-outline-variant); border-radius:6px; background:var(--mat-sys-surface); color:inherit; }
    .pd-sec { font-size:12px; font-weight:600; opacity:.7; margin:12px 0 4px; }
    .pd-modes { display:flex; flex-direction:column; gap:4px; font-size:13px; }
  `],
})
export class ProvisionDbDialogComponent implements OnInit {
  ref = inject(MatDialogRef<ProvisionDbDialogComponent, boolean>);
  private http = inject(HttpClient);
  private base = environment.apiUrl;

  agents = signal<AgentRow[]>([]);
  secrets = signal<SecretRef[]>([]);
  providerId = signal(''); backend = signal('mysql'); execMode = signal('local'); container = signal('');
  adminUser = signal('root'); adminPassword = signal(''); dbName = signal('appdb'); dbUser = signal('app');
  mode = signal('generate'); customPw = signal(''); existingIdx = signal(-1);
  tName = signal('DB_HOST'); tUser = signal('DB_USER'); tPass = signal('DB_PASSWORD');
  busy = signal(false); error = signal(''); result = signal<any>(null);

  constructor(@Inject(MAT_DIALOG_DATA) public data: ProvisionDbData) {}

  ngOnInit(): void {
    this.http.get<AgentRow[]>(`${this.base}/agents`).subscribe((a) => this.agents.set((a || []).filter((x) => x.address)));
    this.http.get<{ secrets: SecretRef[] }>(`${this.base}/vault/secrets`).subscribe((v) => this.secrets.set(v?.secrets || []));
  }

  canRun(): boolean {
    if (!this.providerId() || !this.adminPassword() || !this.dbName() || !this.dbUser()) return false;
    if (this.mode() === 'custom' && !this.customPw()) return false;
    if (this.mode() === 'existing' && this.existingIdx() < 0) return false;
    if (this.execMode() === 'docker' && !this.container()) return false;
    return true;
  }

  run(): void {
    this.busy.set(true); this.error.set(''); this.result.set(null);
    const body: any = {
      provider_agent_id: this.providerId(), exec: this.execMode(), container: this.container() || null,
      backend: this.backend(), admin_user: this.adminUser(), admin_password: this.adminPassword(),
      db_name: this.dbName(), db_user: this.dbUser(), consumer_agent_id: this.data.consumerAgentId,
      targets: { name: this.tName(), user: this.tUser(), password: this.tPass() },
      password_mode: this.mode(),
    };
    if (this.mode() === 'custom') body.password = this.customPw();
    if (this.mode() === 'existing') {
      const s = this.secrets()[this.existingIdx()];
      body.existing_scope_type = s.scope_type; body.existing_key = s.key;
      // The vault inventory currently lists host-scope secrets by host name; the
      // backend resolves by id, so only host secrets carry an id today.
      if (s.scope_type === 'host') {
        const host = this.agents().find((a) => a.name === s.scope);
        body.existing_agent_id = host?.id ?? null;
      }
    }
    this.http.post(`${this.base}/blueprints/provision`, body).subscribe({
      next: (r) => { this.result.set(r); this.busy.set(false); setTimeout(() => this.ref.close(true), 900); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'provisioning failed'); this.busy.set(false); },
    });
  }
}
