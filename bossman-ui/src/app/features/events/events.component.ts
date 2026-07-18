import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { EventService, EventItem, EventStats } from '../../core/services/event.service';

/** Event Console (gap #2): the stream of passively-received syslog messages +
 * SNMP traps from devices that push instead of being polled. */
@Component({
  selector: 'app-events',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <div>
          <h1>Event Console</h1>
          <p class="bm-dim">Passively received syslog messages &amp; SNMP traps (devices push these; we don't poll them). Point devices' syslog/trap sinks at this host (udp/514, udp/162).</p>
        </div>
        <div class="bm-stats">
          <span class="bm-stat">{{ stats()?.total ?? 0 }} total</span>
          <span class="bm-stat bm-stat--warn">{{ stats()?.unacked ?? 0 }} unacked</span>
          <span class="bm-stat bm-stat--crit">{{ stats()?.urgent ?? 0 }} urgent</span>
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Refresh</button>
        </div>
      </div>

      <div class="bm-filters">
        <label>Kind
          <select [(ngModel)]="fKind" (ngModelChange)="reload()">
            <option value="">all</option><option value="syslog">syslog</option><option value="snmptrap">SNMP trap</option>
          </select>
        </label>
        <label>Severity ≤
          <select [(ngModel)]="fSev" (ngModelChange)="reload()">
            <option value="">any</option><option value="2">crit</option><option value="3">error</option>
            <option value="4">warning</option><option value="6">info</option>
          </select>
        </label>
        <label class="bm-check"><input type="checkbox" [(ngModel)]="fUnacked" (ngModelChange)="reload()" /> unacknowledged only</label>
      </div>

      <div class="bm-card">
        <table class="bm-table">
          <thead><tr><th>Time</th><th>Sev</th><th>Kind</th><th>Source</th><th>App</th><th>Message</th><th></th></tr></thead>
          <tbody>
            @for (e of events(); track e.id) {
              <tr [class.bm-ack]="e.acknowledged">
                <td class="bm-mono">{{ e.received_at | date: 'short' }}</td>
                <td><span class="bm-sev bm-sev--{{ e.severity_name }}">{{ e.severity_name }}</span></td>
                <td>{{ e.kind }}</td>
                <td>{{ e.host_name || e.source_ip }}</td>
                <td class="bm-mono">{{ e.app || '—' }}</td>
                <td class="bm-msg">{{ e.message }}</td>
                <td>@if (!e.acknowledged) { <button mat-button (click)="ack(e)">Ack</button> }</td>
              </tr>
            } @empty {
              <tr><td colspan="7" class="bm-dim">No events yet. Configure a device to send syslog to udp/514 or traps to udp/162 on this host.</td></tr>
            }
          </tbody>
        </table>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1200px; margin: 0 auto; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 12px; }
    .bm-head h1 { margin: 0; }
    .bm-dim { opacity: 0.62; font-size: 13px; margin: 4px 0 0; max-width: 640px; }
    .bm-stats { display: flex; align-items: center; gap: 10px; }
    .bm-stat { font-size: 13px; padding: 3px 10px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    .bm-stat--warn { background: color-mix(in srgb, var(--bm-gold, #e0a030) 22%, transparent); }
    .bm-stat--crit { background: color-mix(in srgb, var(--bm-red, #c62828) 22%, transparent); }
    .bm-filters { display: flex; gap: 16px; margin-bottom: 12px; align-items: center; }
    .bm-filters label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; }
    .bm-filters .bm-check { flex-direction: row; align-items: center; gap: 6px; }
    .bm-filters select { padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 8px 12px;
      background: var(--mat-sys-surface-container-low, rgba(127,127,127,0.04)); }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { text-align: left; font-size: 12px; opacity: 0.6; padding: 6px 10px; }
    .bm-table td { padding: 7px 10px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; white-space: nowrap; }
    .bm-msg { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-ack { opacity: 0.45; }
    .bm-sev { font-size: 11px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-sev--emerg, .bm-sev--alert, .bm-sev--crit, .bm-sev--error { background: color-mix(in srgb, var(--bm-red, #c62828) 25%, transparent); }
    .bm-sev--warning { background: color-mix(in srgb, var(--bm-gold, #e0a030) 25%, transparent); }
  `],
})
export class EventsComponent implements OnInit {
  private svc = inject(EventService);
  events = signal<EventItem[]>([]);
  stats = signal<EventStats | null>(null);
  fKind = '';
  fSev = '';
  fUnacked = false;

  ngOnInit(): void { this.reload(); }

  reload(): void {
    this.svc.list({ kind: this.fKind, max_severity: this.fSev ? Number(this.fSev) : undefined, unacked: this.fUnacked, limit: 300 })
      .subscribe((e) => this.events.set(e));
    this.svc.stats().subscribe((s) => this.stats.set(s));
  }

  ack(e: EventItem): void { this.svc.ack(e.id).subscribe(() => this.reload()); }
}
