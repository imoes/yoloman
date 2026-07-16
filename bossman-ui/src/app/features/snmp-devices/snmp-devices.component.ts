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
import { SnmpDevice } from '../../core/models/agent.model';

/**
 * Block 3 — SNMP devices: agent-less network gear (switches, printers, PDUs)
 * monitored via SNMP checks the co-located poller runs on their behalf. Create
 * one (name, target, v2c community, checks) and it appears as a monitored host;
 * the poller runs the assigned SNMP checks each cycle with the device's
 * target/community and attributes the resulting services to it.
 */
@Component({
  selector: 'app-snmp-devices',
  standalone: true,
  imports: [DatePipe, FormsModule, RouterLink, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <h1>SNMP devices</h1>
      <p class="bm-dim">
        Monitor agent-less devices (switches, printers, PDUs) over SNMP — the co-located poller runs the
        assigned checks on their behalf. A device shows up as a monitored host; open it to see its services.
      </p>

      <div class="bm-new">
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Name</mat-label>
          <input matInput [(ngModel)]="name" placeholder="sw-core-01" />
        </mat-form-field>
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Target (IP / host)</mat-label>
          <input matInput [(ngModel)]="target" placeholder="192.0.2.5" />
        </mat-form-field>
        <mat-form-field appearance="outline" subscriptSizing="dynamic">
          <mat-label>Community (v2c)</mat-label>
          <input matInput [(ngModel)]="community" placeholder="public" />
        </mat-form-field>
        <mat-form-field appearance="outline" subscriptSizing="dynamic" class="bm-checks">
          <mat-label>SNMP checks</mat-label>
          <mat-select [(ngModel)]="checkNames" multiple>
            @for (c of snmpChecks(); track c) { <mat-option [value]="c">{{ c }}</mat-option> }
          </mat-select>
        </mat-form-field>
        <button mat-flat-button color="primary" [disabled]="!canCreate() || creating()" (click)="create()">
          <mat-icon>add</mat-icon> {{ creating() ? 'Creating…' : 'Add device' }}
        </button>
      </div>
      @if (err()) { <p class="bm-err">{{ err() }}</p> }

      @if (devices().length) {
        <table class="bm-table">
          <thead><tr><th>Device</th><th>Target</th><th>Community</th><th>Checks</th><th>Last seen</th><th></th></tr></thead>
          <tbody>
            @for (d of devices(); track d.id) {
              <tr>
                <td><a [routerLink]="['/hosts', d.id]">{{ d.name }}</a></td>
                <td class="bm-mono">{{ d.target }}</td>
                <td class="bm-mono">{{ d.community }}</td>
                <td>{{ d.check_names.length }}</td>
                <td class="bm-dim">{{ d.last_seen_at ? (d.last_seen_at | date: 'medium') : 'never' }}</td>
                <td class="bm-right"><button mat-button color="warn" (click)="remove(d)">Remove</button></td>
              </tr>
            }
          </tbody>
        </table>
      } @else if (loaded()) {
        <p class="bm-dim">No SNMP devices yet — add one above.</p>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
    .bm-dim { opacity: 0.65; }
    .bm-new { display: flex; gap: 12px; align-items: flex-start; flex-wrap: wrap; margin: 14px 0; }
    .bm-checks { min-width: 260px; }
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

  devices = signal<SnmpDevice[]>([]);
  loaded = signal(false);
  creating = signal(false);
  err = signal<string | null>(null);
  snmpChecks = signal<string[]>([]);

  name = '';
  target = '';
  community = 'public';
  checkNames: string[] = [];

  canCreate(): boolean {
    return this.name.trim().length > 0 && this.target.trim().length > 0;
  }

  ngOnInit(): void {
    this.reload();
    // Offer the SNMP-datasource checks (datasource on each catalog entry).
    this.checkService.listChecks().subscribe({
      next: (r) => this.snmpChecks.set(
        r.checks.filter((c) => (c as { datasource?: string }).datasource === 'snmp').map((c) => c.name).sort(),
      ),
    });
  }

  private reload(): void {
    this.agentService.snmpDevices().subscribe({
      next: (d) => { this.devices.set(d); this.loaded.set(true); },
      error: () => this.loaded.set(true),
    });
  }

  create(): void {
    if (!this.canCreate() || this.creating()) return;
    this.creating.set(true);
    this.err.set(null);
    this.agentService.createSnmpDevice({
      name: this.name.trim(), target: this.target.trim(),
      community: this.community.trim() || 'public', check_names: this.checkNames,
    }).subscribe({
      next: () => {
        this.creating.set(false);
        this.name = ''; this.target = ''; this.community = 'public'; this.checkNames = [];
        this.reload();
      },
      error: (e) => { this.creating.set(false); this.err.set(e?.error?.detail ?? 'create failed'); },
    });
  }

  remove(d: SnmpDevice): void {
    if (!confirm(`Remove SNMP device "${d.name}"? Its services are deleted too.`)) return;
    this.agentService.deleteSnmpDevice(d.id).subscribe({ next: () => this.reload() });
  }
}
