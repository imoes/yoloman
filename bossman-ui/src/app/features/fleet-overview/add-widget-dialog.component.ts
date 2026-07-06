import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { CreateDashboardWidget, WIDGET_CATALOG, WidgetType } from '../../core/models/dashboard.model';

/** Add-widget catalog dialog for the GridStack dashboard (see docs/plan.md's
 * monitoring-cockpit ergänzung Block F5) — mirrors CentralStation's own
 * add-widget-dialog.component.ts's type-tile picker, trimmed to the six
 * types Bossman's backend actually supports (dashboard.model.ts's
 * WIDGET_CATALOG). Returns a CreateDashboardWidget on save, or undefined
 * on cancel. */
@Component({
  selector: 'app-add-widget-dialog',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatDialogModule, MatFormFieldModule, MatIconModule, MatInputModule, MatSelectModule],
  template: `
    <h2 mat-dialog-title>Add widget</h2>
    <mat-dialog-content class="bm-dialog-body">
      <div class="bm-type-grid">
        @for (t of catalog; track t.type) {
          <button type="button" class="bm-type-tile" [class.active]="widgetType === t.type" (click)="selectType(t.type)">
            <mat-icon>{{ t.icon }}</mat-icon>
            <span>{{ t.label }}</span>
          </button>
        }
      </div>

      <mat-form-field appearance="outline">
        <mat-label>Title</mat-label>
        <input matInput [(ngModel)]="title" />
      </mat-form-field>

      @if (widgetType === 'top_hosts' || widgetType === 'problems') {
        <mat-form-field appearance="outline">
          <mat-label>Limit</mat-label>
          <input matInput type="number" min="1" max="50" [(ngModel)]="limit" />
        </mat-form-field>
      }

      @if (widgetType === 'stat') {
        <mat-form-field appearance="outline">
          <mat-label>Value</mat-label>
          <mat-select [(ngModel)]="statSource">
            <mat-option value="open_problems">Open problems</mat-option>
            <mat-option value="hosts_total">Hosts total</mat-option>
          </mat-select>
        </mat-form-field>
      }

      @if (widgetType === 'gauge' || widgetType === 'timeseries') {
        <mat-form-field appearance="outline">
          <mat-label>Host</mat-label>
          <mat-select [(ngModel)]="agentId">
            @for (a of agents(); track a.id) {
              <mat-option [value]="a.id">{{ a.name }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
        <mat-form-field appearance="outline">
          <mat-label>Metric name</mat-label>
          <input matInput [(ngModel)]="metric" placeholder="e.g. cpu_load1, mem_used_pct" />
        </mat-form-field>
      }

      @if (widgetType === 'gauge') {
        <mat-form-field appearance="outline">
          <mat-label>Warn threshold</mat-label>
          <input matInput type="number" [(ngModel)]="warn" />
        </mat-form-field>
        <mat-form-field appearance="outline">
          <mat-label>Critical threshold</mat-label>
          <input matInput type="number" [(ngModel)]="crit" />
        </mat-form-field>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="close()">Cancel</button>
      <button mat-flat-button color="primary" [disabled]="!canSave()" (click)="save()">Add</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-dialog-body {
        display: flex;
        flex-direction: column;
        gap: 12px;
        min-width: 420px;
      }
      .bm-type-grid {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 8px;
        margin-bottom: 4px;
      }
      .bm-type-tile {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 4px;
        padding: 10px 4px;
        border-radius: 8px;
        border: 1px solid var(--mat-sys-outline-variant);
        background: transparent;
        cursor: pointer;
        font-size: 12px;
        color: inherit;
      }
      .bm-type-tile.active {
        border-color: var(--bm-green);
        background: color-mix(in srgb, var(--bm-green) 12%, transparent);
      }
      mat-form-field {
        width: 100%;
      }
    `,
  ],
})
export class AddWidgetDialogComponent implements OnInit {
  private agentService = inject(AgentService);
  private dialogRef = inject(MatDialogRef<AddWidgetDialogComponent, CreateDashboardWidget | undefined>);
  private data = inject<{ defaultType?: WidgetType } | null>(MAT_DIALOG_DATA, { optional: true });

  readonly catalog = WIDGET_CATALOG;
  agents = signal<Agent[]>([]);

  widgetType: WidgetType = this.data?.defaultType ?? 'top_hosts';
  title = 'Top hosts';
  limit = 10;
  statSource: 'open_problems' | 'hosts_total' = 'open_problems';
  agentId = '';
  metric = '';
  warn: number | null = null;
  crit: number | null = null;

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
  }

  selectType(type: WidgetType): void {
    this.widgetType = type;
    this.title = this.catalog.find((t) => t.type === type)?.label ?? this.title;
  }

  canSave(): boolean {
    if (!this.title.trim()) return false;
    if ((this.widgetType === 'gauge' || this.widgetType === 'timeseries') && (!this.agentId || !this.metric.trim())) return false;
    return true;
  }

  close(): void {
    this.dialogRef.close(undefined);
  }

  save(): void {
    const tile = this.catalog.find((t) => t.type === this.widgetType);
    const [gsW, gsH] = tile?.defaultSize ?? [4, 3];
    const config: Record<string, unknown> = {};
    if (this.widgetType === 'top_hosts' || this.widgetType === 'problems') {
      config['limit'] = this.limit;
    } else if (this.widgetType === 'stat') {
      config['stat_source'] = this.statSource;
    } else if (this.widgetType === 'gauge' || this.widgetType === 'timeseries') {
      config['agent_id'] = this.agentId;
      config['metric'] = this.metric.trim();
      if (this.widgetType === 'gauge') {
        if (this.warn !== null) config['warn'] = this.warn;
        if (this.crit !== null) config['crit'] = this.crit;
      }
    }
    this.dialogRef.close({
      widget_type: this.widgetType,
      title: this.title.trim(),
      gs_w: gsW,
      gs_h: gsH,
      config,
    });
  }
}
