import { Component, OnInit, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatDialog } from '@angular/material/dialog';
import { NotificationService } from '../../core/services/notification.service';
import { NotificationLogEntry, NotificationRule, NotificationRuleInput } from '../../core/models/notification.model';
import {
  NotificationRuleDialogComponent,
  NotificationRuleDialogData,
} from '../../shared/components/notification-rule-dialog/notification-rule-dialog.component';

/** Monitor → Notifications (Block H8): manage who gets alerted on which
 * channel, and see the recent send log (sent/failed). The notifier fires
 * on confirmed (hard) problems/recoveries, skipping acknowledged /
 * in-downtime / flapping services. */
@Component({
  selector: 'app-notifications',
  standalone: true,
  imports: [DatePipe, MatCardModule, MatButtonModule, MatIconModule, MatSlideToggleModule],
  template: `
    <div class="bm-page">
      <div class="bm-header-row">
        <h1>Notifications</h1>
        <button mat-raised-button color="primary" (click)="openDialog()">
          <mat-icon>add</mat-icon> New rule
        </button>
      </div>
      <p class="bm-subtitle">
        Alert on confirmed (hard) problems and recoveries, by email or webhook. Acknowledged,
        in-downtime and flapping services are skipped.
      </p>

      <mat-card class="bm-panel">
        <mat-card-header><mat-card-title>Rules</mat-card-title></mat-card-header>
        <mat-card-content>
          @if (rules().length) {
            <table class="bm-table">
              <thead>
                <tr><th>Name</th><th>Channel</th><th>Target</th><th>Fires on</th><th>Filter</th><th>Enabled</th><th></th></tr>
              </thead>
              <tbody>
                @for (r of rules(); track r.id) {
                  <tr>
                    <td>{{ r.name }}</td>
                    <td>{{ r.channel }}</td>
                    <td class="bm-mono">{{ r.target }}</td>
                    <td>
                      {{ r.on_problem ? '≥' + r.min_state : '' }}{{ r.on_problem && r.on_recovery ? ', ' : '' }}{{ r.on_recovery ? 'recovery' : '' }}
                    </td>
                    <td class="bm-dim">
                      {{ r.host_filter ? 'host~' + r.host_filter : '' }}
                      {{ r.service_filter ? 'svc~' + r.service_filter : '' }}
                    </td>
                    <td>{{ r.enabled ? 'yes' : 'no' }}</td>
                    <td class="bm-actions">
                      <button mat-button (click)="openDialog(r)">Edit</button>
                      <button mat-button (click)="remove(r)">Delete</button>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No notification rules yet — nobody is alerted. Add one to start.</p>
          }
        </mat-card-content>
      </mat-card>

      <mat-card class="bm-panel">
        <mat-card-header><mat-card-title>Recent notifications</mat-card-title></mat-card-header>
        <mat-card-content>
          @if (logEntries().length) {
            <table class="bm-table">
              <thead>
                <tr><th>When</th><th>Host</th><th>Service</th><th>Event</th><th>Channel</th><th>Status</th></tr>
              </thead>
              <tbody>
                @for (n of logEntries(); track n.id) {
                  <tr>
                    <td>{{ n.created_at | date: 'short' }}</td>
                    <td>{{ n.agent_name }}</td>
                    <td>{{ n.service_name }}</td>
                    <td>{{ n.event }} ({{ n.state }})</td>
                    <td class="bm-mono">{{ n.channel }} → {{ n.target }}</td>
                    <td>
                      <span [class.bm-sent]="n.status === 'sent'" [class.bm-failed]="n.status === 'failed'">{{ n.status }}</span>
                      @if (n.error) {
                        <span class="bm-err" [title]="n.error">⚠</span>
                      }
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No notifications sent yet.</p>
          }
        </mat-card-content>
      </mat-card>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-header-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
      }
      .bm-subtitle {
        opacity: 0.7;
        margin-top: -8px;
      }
      .bm-panel {
        margin-bottom: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 6px 8px;
      }
      .bm-table td {
        padding: 8px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-mono {
        font-family: monospace;
        font-size: 12.5px;
      }
      .bm-dim {
        opacity: 0.65;
        font-size: 12px;
      }
      .bm-actions {
        text-align: right;
        white-space: nowrap;
      }
      .bm-sent {
        color: var(--bm-green);
      }
      .bm-failed {
        color: var(--bm-red);
        font-weight: 600;
      }
      .bm-err {
        margin-left: 4px;
        cursor: help;
      }
      .bm-empty {
        opacity: 0.6;
      }
    `,
  ],
})
export class NotificationsComponent implements OnInit {
  private service = inject(NotificationService);
  private dialog = inject(MatDialog);

  rules = signal<NotificationRule[]>([]);
  logEntries = signal<NotificationLogEntry[]>([]);

  ngOnInit(): void {
    this.reload();
  }

  reload(): void {
    this.service.listRules().subscribe((r) => this.rules.set(r));
    this.service.log().subscribe((l) => this.logEntries.set(l));
  }

  openDialog(rule?: NotificationRule): void {
    const ref = this.dialog.open<NotificationRuleDialogComponent, NotificationRuleDialogData, NotificationRuleInput>(
      NotificationRuleDialogComponent,
      { width: '520px', data: { rule } },
    );
    ref.afterClosed().subscribe((result) => {
      if (!result) return;
      const obs = rule ? this.service.updateRule(rule.id, result) : this.service.createRule(result);
      obs.subscribe(() => this.reload());
    });
  }

  remove(rule: NotificationRule): void {
    this.service.deleteRule(rule.id).subscribe(() => this.reload());
  }
}
