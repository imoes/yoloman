import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AgentService } from '../../core/services/agent.service';
import { CheckService } from '../../core/services/check.service';
import { Device } from '../../core/models/agent.model';

/**
 * Block 3 — agent-less devices (SNMP gear, SSH hosts) monitored via the
 * co-located poller, which runs their assigned checks on their behalf with the
 * device's connection params. A device appears as a monitored host; open it to
 * see its services. (Also creatable from Hosts → Add host.)
 */
@Component({
  selector: 'app-snmp-devices',
  standalone: true,
  imports: [DatePipe, FormsModule, RouterLink, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <h1>Devices</h1>
      <p class="bm-dim">
        Monitor agent-less devices (SNMP switches/printers/PDUs, or SSH hosts) — the co-located poller
        runs the assigned checks on their behalf. A device shows up as a monitored host.
      </p>

      <div class="bm-new">
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Kind</mat-label>
          <mat-select [(ngModel)]="kind" (ngModelChange)="onKind()">
            <mat-option value="snmp">SNMP</mat-option>
            <mat-option value="ssh">SSH</mat-option>
          </mat-select>
        </mat-form-field>
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Name</mat-label>
          <input matInput [(ngModel)]="name" placeholder="sw-core-01" />
        </mat-form-field>
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Target (IP / host)</mat-label>
          <input matInput [(ngModel)]="target" placeholder="192.0.2.5" />
        </mat-form-field>
        @if (kind === 'snmp') {
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>Community (v2c)</mat-label>
            <input matInput [(ngModel)]="community" placeholder="public" />
          </mat-form-field>
        } @else {
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>SSH user</mat-label>
            <input matInput [(ngModel)]="user" placeholder="root" />
          </mat-form-field>
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>SSH password</mat-label>
            <input matInput type="password" [(ngModel)]="password" />
          </mat-form-field>
        }
        <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-checks">
          <mat-label>{{ kind === 'snmp' ? 'SNMP' : 'SSH' }} checks</mat-label>
          <mat-select [(ngModel)]="checkNames" multiple>
            @for (c of kindChecks(); track c) { <mat-option [value]="c">{{ c }}</mat-option> }
          </mat-select>
        </mat-form-field>
        <button mat-flat-button color="primary" [disabled]="!canCreate() || creating()" (click)="create()">
          <mat-icon>add</mat-icon> {{ creating() ? 'Creating…' : 'Add device' }}
        </button>
      </div>
      @if (kind === 'ssh' && !sshChecks().length) {
        <p class="bm-dim">Note: no SSH-datasource checks in the library yet — an SSH host can be created, but has nothing to poll until SSH checks exist.</p>
      }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }

      @if (devices().length) {
        <table class="bm-table">
          <thead><tr><th>Device</th><th>Kind</th><th>Target</th><th>Auth</th><th>Checks</th><th>Last seen</th><th></th></tr></thead>
          <tbody>
            @for (d of devices(); track d.id) {
              <tr>
                <td><a [routerLink]="['/hosts', d.id]">{{ d.name }}</a></td>
                <td>{{ d.kind }}</td>
                <td class="bm-mono">{{ d.target }}</td>
                <td class="bm-mono">{{ d.kind === 'snmp' ? d.community : d.user }}</td>
                <td>{{ d.check_names.length }}</td>
                <td class="bm-dim">{{ d.last_seen_at ? (d.last_seen_at | date: 'medium') : 'never' }}</td>
                <td class="bm-right"><button mat-button color="warn" (click)="remove(d)">Remove</button></td>
              </tr>
            }
          </tbody>
        </table>
      } @else if (loaded()) {
        <p class="bm-dim">No devices yet — add one above.</p>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
    .bm-dim { opacity: 0.65; }
    .bm-new { display: flex; gap: 12px; align-items: flex-start; flex-wrap: wrap; margin: 14px 0; }
    .bm-checks { min-width: 240px; }
    .bm-err { color: #c62828; }
    .bm-table { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .bm-table th { text-align: left; font-size: 12px; opacity: 0.7; padding: 8px 10px; }
    .bm-table td { padding: 8px 10px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-mono { font-family: monospace; }
    .bm-right { text-align: right; }
  `],
})
export class SnmpDevicesComponent implements OnInit {
  private agentService = inject(AgentService);
  private checkService = inject(CheckService);

  devices = signal<Device[]>([]);
  loaded = signal(false);
  creating = signal(false);
  err = signal<string | null>(null);
  snmpChecks = signal<string[]>([]);
  sshChecks = signal<string[]>([]);

  kind: 'snmp' | 'ssh' = 'snmp';
  name = '';
  target = '';
  community = 'public';
  user = '';
  password = '';
  checkNames: string[] = [];

  kindChecks(): string[] {
    return this.kind === 'snmp' ? this.snmpChecks() : this.sshChecks();
  }
  onKind(): void {
    this.checkNames = [];
  }
  canCreate(): boolean {
    return this.name.trim().length > 0 && this.target.trim().length > 0;
  }

  ngOnInit(): void {
    this.reload();
    this.checkService.listChecks().subscribe({
      next: (r) => {
        const ds = (c: { name: string }) => (c as { datasource?: string }).datasource;
        this.snmpChecks.set(r.checks.filter((c) => ds(c) === 'snmp').map((c) => c.name).sort());
        this.sshChecks.set(r.checks.filter((c) => ds(c) === 'ssh').map((c) => c.name).sort());
      },
    });
  }

  private reload(): void {
    this.agentService.devices().subscribe({
      next: (d) => { this.devices.set(d); this.loaded.set(true); },
      error: () => this.loaded.set(true),
    });
  }

  create(): void {
    if (!this.canCreate() || this.creating()) return;
    this.creating.set(true);
    this.err.set(null);
    this.agentService.createDevice({
      name: this.name.trim(), kind: this.kind, target: this.target.trim(),
      community: this.community.trim() || 'public', user: this.user.trim(), password: this.password,
      check_names: this.checkNames,
    }).subscribe({
      next: () => {
        this.creating.set(false);
        this.name = ''; this.target = ''; this.community = 'public'; this.user = ''; this.password = ''; this.checkNames = [];
        this.reload();
      },
      error: (e) => { this.creating.set(false); this.err.set(e?.error?.detail ?? 'create failed'); },
    });
  }

  remove(d: Device): void {
    if (!confirm(`Remove device "${d.name}"? Its services are deleted too.`)) return;
    this.agentService.deleteDevice(d.id).subscribe({ next: () => this.reload() });
  }
}
