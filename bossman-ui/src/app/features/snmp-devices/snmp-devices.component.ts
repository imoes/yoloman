import { Component, OnInit, computed, inject, signal } from '@angular/core';
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
import { CheckCatalogEntry } from '../../core/models/check.model';

/**
 * Block 3 — agent-less devices (SNMP gear, SSH hosts) monitored via the
 * co-located poller, which runs their assigned checks on their behalf with the
 * device's connection params. A device appears as a monitored host; open it to
 * see its services. (Also creatable from Hosts → Add host.)
 *
 * Presentation follows the app's macOS-ish philosophy: the fleet reads as a set
 * of cards, checks are picked by their plain-language name (not a raw key like
 * "acme_agent_sessions"), and "Add a device" is one calm card.
 */
@Component({
  selector: 'app-snmp-devices',
  standalone: true,
  imports: [DatePipe, FormsModule, RouterLink, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <header class="bm-head">
        <h1>Devices</h1>
        <p class="bm-sub">
          Keep an eye on gear that can't run an agent — SNMP switches, printers, PDUs, or SSH-only hosts.
          A co-located poller runs the checks for them, and each device shows up as a normal monitored host.
        </p>
      </header>

      <!-- Add a device — one calm card -->
      <section class="bm-card bm-add">
        <div class="bm-add-head">
          <mat-icon>add_circle</mat-icon>
          <span>Add a device</span>
        </div>
        <div class="bm-add-grid">
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>Type</mat-label>
            <mat-select [(ngModel)]="kind" (ngModelChange)="onKind()">
              <mat-option value="snmp">SNMP device</mat-option>
              <mat-option value="ssh">SSH host</mat-option>
            </mat-select>
          </mat-form-field>
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>Name</mat-label>
            <input matInput [(ngModel)]="name" placeholder="sw-core-01" />
          </mat-form-field>
          <mat-form-field appearance="outline" subscriptSizing="dynamic">
            <mat-label>Address (IP or hostname)</mat-label>
            <input matInput [(ngModel)]="target" placeholder="192.0.2.5" />
          </mat-form-field>
          @if (kind === 'snmp') {
            <mat-form-field appearance="outline" subscriptSizing="dynamic">
              <mat-label>Community (SNMP v2c)</mat-label>
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
            <mat-label>What to monitor</mat-label>
            <mat-select [(ngModel)]="checkNames" multiple [placeholder]="kind === 'snmp' ? 'pick SNMP checks' : 'pick SSH checks'">
              @for (c of kindChecks(); track c.name) {
                <mat-option [value]="c.name">
                  {{ checkLabel(c) }}<span class="bm-opt-key"> · {{ c.name }}</span>
                </mat-option>
              }
            </mat-select>
          </mat-form-field>
        </div>
        <div class="bm-add-foot">
          @if (kind === 'ssh' && !sshChecks().length) {
            <span class="bm-note">No SSH checks in the library yet — you can still add the host; it just has nothing to poll until SSH checks exist.</span>
          } @else if (checkNames.length) {
            <span class="bm-note">{{ checkNames.length }} check(s) selected.</span>
          } @else {
            <span class="bm-note">Pick one or more checks the poller should run.</span>
          }
          <button mat-flat-button color="primary" [disabled]="!canCreate() || creating()" (click)="create()">
            <mat-icon>add</mat-icon> {{ creating() ? 'Adding…' : 'Add device' }}
          </button>
        </div>
        @if (err()) { <p class="bm-err">{{ err() }}</p> }
      </section>

      <!-- The fleet of agent-less devices, as cards -->
      @if (devices().length) {
        <div class="bm-grid">
          @for (d of devices(); track d.id) {
            <article class="bm-card bm-device">
              <div class="bm-device-top">
                <a class="bm-device-name" [routerLink]="['/hosts', d.id]">{{ d.name }}</a>
                <span class="bm-kind" [class.bm-kind--ssh]="d.kind === 'ssh'">{{ d.kind === 'snmp' ? 'SNMP' : 'SSH' }}</span>
              </div>
              <dl class="bm-device-meta">
                <dt>Address</dt><dd class="bm-mono">{{ d.target }}</dd>
                <dt>{{ d.kind === 'snmp' ? 'Community' : 'User' }}</dt><dd class="bm-mono">{{ d.kind === 'snmp' ? d.community : d.user }}</dd>
                <dt>Last seen</dt><dd>{{ d.last_seen_at ? (d.last_seen_at | date: 'medium') : 'never' }}</dd>
              </dl>
              <div class="bm-chips">
                @for (n of d.check_names; track n) {
                  <span class="bm-chip" [title]="n">{{ checkNameLabel(n) }}</span>
                } @empty {
                  <span class="bm-note">No checks assigned.</span>
                }
              </div>
              <div class="bm-device-foot">
                <a mat-button [routerLink]="['/hosts', d.id]">Open</a>
                <button mat-button color="warn" (click)="remove(d)">Remove</button>
              </div>
            </article>
          }
        </div>
      } @else if (loaded()) {
        <div class="bm-empty">
          <mat-icon>router</mat-icon>
          <p>No devices yet — add your first switch, printer or SSH host above.</p>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
    .bm-head h1 { margin: 0 0 4px; }
    .bm-sub { opacity: 0.65; margin: 0 0 20px; max-width: 720px; line-height: 1.55; }

    .bm-card {
      border: 1px solid var(--mat-sys-outline-variant);
      border-radius: 14px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04));
      padding: 18px 20px;
    }

    .bm-add { margin-bottom: 24px; }
    .bm-add-head { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 14px; }
    .bm-add-head mat-icon { color: var(--mat-sys-primary); }
    .bm-add-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
    .bm-checks { grid-column: 1 / -1; }
    .bm-add-foot { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 14px; flex-wrap: wrap; }
    .bm-note { opacity: 0.6; font-size: 13px; }
    .bm-opt-key { opacity: 0.5; font-size: 12px; }
    .bm-err { color: var(--bm-red, #c62828); margin: 10px 0 0; }

    .bm-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }
    .bm-device { display: flex; flex-direction: column; gap: 12px; transition: border-color .15s, transform .15s; }
    .bm-device:hover { border-color: var(--mat-sys-primary); }
    .bm-device-top { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
    .bm-device-name { font-weight: 600; font-size: 16px; text-decoration: none; color: inherit; }
    .bm-device-name:hover { color: var(--mat-sys-primary); }
    .bm-kind { font-size: 11px; font-weight: 600; letter-spacing: .04em; padding: 2px 9px; border-radius: 20px;
               background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); color: var(--mat-sys-primary); }
    .bm-kind--ssh { background: color-mix(in srgb, var(--mat-sys-tertiary, #7b6) 16%, transparent); color: var(--mat-sys-tertiary, #6a8f4f); }

    .bm-device-meta { display: grid; grid-template-columns: auto 1fr; gap: 3px 12px; margin: 0; font-size: 13px; }
    .bm-device-meta dt { opacity: 0.55; }
    .bm-device-meta dd { margin: 0; text-align: right; }
    .bm-mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }

    .bm-chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .bm-chip { font-size: 12px; padding: 2px 10px; border-radius: 20px;
               background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }

    .bm-device-foot { display: flex; justify-content: flex-end; gap: 4px; margin-top: auto; border-top: 1px solid var(--mat-sys-outline-variant); padding-top: 8px; }

    .bm-empty { text-align: center; opacity: 0.55; padding: 60px 20px; }
    .bm-empty mat-icon { font-size: 42px; width: 42px; height: 42px; }
  `],
})
export class SnmpDevicesComponent implements OnInit {
  private agentService = inject(AgentService);
  private checkService = inject(CheckService);

  devices = signal<Device[]>([]);
  loaded = signal(false);
  creating = signal(false);
  err = signal<string | null>(null);
  snmpChecks = signal<CheckCatalogEntry[]>([]);
  sshChecks = signal<CheckCatalogEntry[]>([]);
  // name → friendly label, so a device card's chips read in plain language.
  private labelByName = computed<Record<string, string>>(() => {
    const out: Record<string, string> = {};
    for (const c of [...this.snmpChecks(), ...this.sshChecks()]) out[c.name] = this.checkLabel(c);
    return out;
  });

  kind: 'snmp' | 'ssh' = 'snmp';
  name = '';
  target = '';
  community = 'public';
  user = '';
  password = '';
  checkNames: string[] = [];

  kindChecks(): CheckCatalogEntry[] {
    return this.kind === 'snmp' ? this.snmpChecks() : this.sshChecks();
  }
  /** Plain-language name for a check: its short_description (placeholders
   * stripped) or the raw key prettified — never a bare "acme_agent_sessions". */
  checkLabel(c: CheckCatalogEntry): string {
    const d = (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim();
    if (d) return d;
    return c.name.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }
  checkNameLabel(name: string): string {
    return this.labelByName()[name] ?? name;
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
        const byLabel = (a: CheckCatalogEntry, b: CheckCatalogEntry) => this.checkLabel(a).localeCompare(this.checkLabel(b));
        this.snmpChecks.set(r.checks.filter((c) => ds(c) === 'snmp').sort(byLabel));
        this.sshChecks.set(r.checks.filter((c) => ds(c) === 'ssh').sort(byLabel));
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
