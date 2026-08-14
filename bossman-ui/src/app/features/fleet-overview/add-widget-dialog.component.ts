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
import { Graph, GraphItemInput } from '../../core/models/graph.model';
import { GraphService } from '../../core/services/graph.service';
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

      @if (widgetType === 'gauge') {
        <mat-form-field appearance="outline">
          <mat-label>Host</mat-label>
          <mat-select [ngModel]="agentId" (ngModelChange)="pickAgent($event)">
            @for (a of agents(); track a.id) {
              <mat-option [value]="a.id">{{ a.name }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
        <mat-form-field appearance="outline">
          <mat-label>Metric</mat-label>
          <mat-select [(ngModel)]="metric" [disabled]="!agentId">
            @for (m of metricsFor(agentId); track m) {
              <mat-option [value]="m">{{ m }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
        @if (agentId && !metricsFor(agentId).length) {
          <p class="bm-note bm-err">This host has not reported any metric yet — a widget on it would stay empty.</p>
        }
      }

      @if (widgetType === 'timeseries') {
        <!-- A chart is authored as a saved graph, not as per-widget series: a one-item graph
             and a "single metric widget" would be the same result reached two ways. Reusing an
             existing graph is not a second way — it is the same object in another place. -->
        <div class="bm-src">
          <button type="button" class="bm-src-btn" [class.active]="chartSource === 'new'"
                  (click)="chartSource = 'new'">Build a chart</button>
          <button type="button" class="bm-src-btn" [class.active]="chartSource === 'saved'"
                  (click)="chartSource = 'saved'" [disabled]="!graphs().length">
            Reuse a saved chart @if (graphs().length) { ({{ graphs().length }}) }
          </button>
        </div>

        @if (chartSource === 'saved') {
          <mat-form-field appearance="outline">
            <mat-label>Saved chart</mat-label>
            <mat-select [(ngModel)]="graphId">
              @for (g of graphs(); track g.id) {
                <mat-option [value]="g.id">{{ g.name }} ({{ g.items.length }} line(s))</mat-option>
              }
            </mat-select>
          </mat-form-field>
          <p class="bm-note">
            The same chart can sit on several dashboards; editing it there changes it everywhere.
          </p>
        } @else {
          <mat-form-field appearance="outline">
            <mat-label>Chart name (saved for reuse)</mat-label>
            <input matInput [(ngModel)]="graphName" [placeholder]="title" />
          </mat-form-field>

          @for (it of items; track $index) {
            <div class="bm-item">
              <div class="bm-item-row">
                <mat-form-field appearance="outline" class="bm-grow">
                  <mat-label>Host</mat-label>
                  <mat-select [ngModel]="it.agent_id" (ngModelChange)="setItemAgent($index, $event)">
                    @for (a of agents(); track a.id) {
                      <mat-option [value]="a.id">{{ a.name }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-grow">
                  <mat-label>Metric</mat-label>
                  <mat-select [ngModel]="it.metric" (ngModelChange)="setItem($index, { metric: $event })"
                              [disabled]="!it.agent_id">
                    @for (m of metricsFor(it.agent_id); track m) {
                      <mat-option [value]="m">{{ m }}</mat-option>
                    }
                  </mat-select>
                </mat-form-field>
                <button mat-icon-button (click)="removeItem($index)" [disabled]="items.length === 1"
                        aria-label="Remove line"><mat-icon>close</mat-icon></button>
              </div>
              <div class="bm-item-row">
                <mat-form-field appearance="outline" class="bm-grow">
                  <mat-label>Label</mat-label>
                  <input matInput [ngModel]="it.label" (ngModelChange)="setItem($index, { label: $event })"
                         [placeholder]="it.metric || 'shown in the legend'" />
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-narrow">
                  <mat-label>Axis</mat-label>
                  <mat-select [ngModel]="it.axis_side" (ngModelChange)="setItem($index, { axis_side: $event })">
                    <mat-option value="left">left</mat-option>
                    <mat-option value="right">right</mat-option>
                  </mat-select>
                </mat-form-field>
                <mat-form-field appearance="outline" class="bm-narrow">
                  <mat-label>Value</mat-label>
                  <mat-select [ngModel]="it.function" (ngModelChange)="setItem($index, { function: $event })">
                    <mat-option value="avg">avg</mat-option>
                    <mat-option value="min">min</mat-option>
                    <mat-option value="max">max</mat-option>
                  </mat-select>
                </mat-form-field>
                <input class="bm-color" type="color" [ngModel]="it.color"
                       (ngModelChange)="setItem($index, { color: $event })" title="Line colour" />
              </div>
              @if (it.agent_id && !metricsFor(it.agent_id).length) {
                <p class="bm-note bm-err">This host has reported no metric yet.</p>
              }
            </div>
          }
          <button mat-stroked-button (click)="addItem()"><mat-icon>add</mat-icon> Add another line</button>
          @if (mixedAxisHint()) { <p class="bm-note">{{ mixedAxisHint() }}</p> }
        }
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
      @if (saveError()) { <p class="bm-note bm-err">{{ saveError() }}</p> }
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
      .bm-src { display: flex; gap: 8px; }
      .bm-src-btn { flex: 1; padding: 8px; border-radius: 8px; font: inherit; font-size: 12.5px;
                    border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; }
      .bm-src-btn.active { border-color: var(--bm-green); background: color-mix(in srgb, var(--bm-green) 12%, transparent); }
      .bm-src-btn:disabled { opacity: 0.4; cursor: default; }
      .bm-item { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 10px 10px 0; }
      .bm-item-row { display: flex; gap: 8px; align-items: center; }
      .bm-grow { flex: 1 1 auto; }
      .bm-narrow { flex: 0 0 96px; }
      .bm-color { width: 40px; height: 26px; border: none; background: transparent; }
      .bm-note { font-size: 12px; opacity: 0.7; margin: 0 0 8px; }
      .bm-err { color: var(--mat-sys-error); opacity: 1; }
    `,
  ],
})
export class AddWidgetDialogComponent implements OnInit {
  private agentService = inject(AgentService);
  private graphService = inject(GraphService);
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

  // --- chart authoring (timeseries) ---
  graphs = signal<Graph[]>([]);
  chartSource: 'new' | 'saved' = 'new';
  graphId = '';
  graphName = '';
  items: GraphItemInput[] = [this.blankItem(0)];
  /** agent id -> the metrics that host has actually reported. Offering the fleet-wide metric
   * list would let someone pick a metric this host never sends, and the chart would be
   * permanently empty with nothing saying why. */
  private hostMetrics = signal<Record<string, string[]>>({});
  saving = signal(false);
  saveError = signal('');

  private blankItem(index: number): GraphItemInput {
    const palette = ['#1e9600', '#d0021b', '#ffc800', '#2a7fff', '#a45cff', '#00b8a9'];
    return {
      agent_id: '', metric: '', label: '', color: palette[index % palette.length],
      draw_style: 'line', axis_side: 'left', function: 'avg', sort_order: index,
    };
  }

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
    this.graphService.list().subscribe((graphs) => this.graphs.set(graphs));
  }

  metricsFor(agentId: string): string[] {
    return agentId ? this.hostMetrics()[agentId] ?? [] : [];
  }


  private loadMetrics(agentId: string): void {
    if (!agentId || this.hostMetrics()[agentId] !== undefined) return;
    // metricNames is the purpose-built catalog for exactly this question ("what does THIS
    // host report?") and returns names only — cheaper than the latest-value snapshot.
    this.agentService.metricNames(agentId).subscribe({
      // No client-side filtering any more: /agents/{id}/metrics and the fleet-wide
      // /metric-catalog now share ONE exclusion rule server-side
      // (services/metrics_query.is_measurable), so what arrives here is already pickable.
      next: (res) => this.hostMetrics.update((m) => ({ ...m, [agentId]: [...res.metrics].sort() })),
      // A host that cannot be read contributes no metrics; the template then says so rather
      // than showing an empty dropdown with no explanation.
      error: () => this.hostMetrics.update((m) => ({ ...m, [agentId]: [] })),
    });
  }

  pickAgent(agentId: string): void {
    this.agentId = agentId;
    this.metric = '';
    this.loadMetrics(agentId);
  }

  setItemAgent(index: number, agentId: string): void {
    this.setItem(index, { agent_id: agentId, metric: '' });
    this.loadMetrics(agentId);
  }

  setItem(index: number, patch: Partial<GraphItemInput>): void {
    this.items = this.items.map((it, i) => (i === index ? { ...it, ...patch } : it));
  }

  addItem(): void {
    this.items = [...this.items, this.blankItem(this.items.length)];
  }

  removeItem(index: number): void {
    if (this.items.length === 1) return;
    this.items = this.items.filter((_, i) => i !== index);
  }

  /** Says why a second axis exists, once more than one line is present — two metrics with
   * different units on one axis flatten each other and the chart lies by omission. */
  mixedAxisHint(): string {
    const filled = this.items.filter((it) => it.agent_id && it.metric);
    if (filled.length < 2) return '';
    const sides = new Set(filled.map((it) => it.axis_side));
    return sides.size > 1
      ? 'Two axes: the right-hand lines are scaled separately.'
      : 'All lines share one axis — put a line on the right axis if its unit differs (percent vs bytes).';
  }

  selectType(type: WidgetType): void {
    this.widgetType = type;
    this.title = this.catalog.find((t) => t.type === type)?.label ?? this.title;
  }

  canSave(): boolean {
    if (!this.title.trim() || this.saving()) return false;
    if (this.widgetType === 'gauge') return !!this.agentId && !!this.metric.trim();
    if (this.widgetType === 'timeseries') {
      if (this.chartSource === 'saved') return !!this.graphId;
      // Every line needs a host AND a metric; a half-filled line would be saved as an item
      // that can never plot anything.
      return this.items.length > 0 && this.items.every((it) => !!it.agent_id && !!it.metric);
    }
    return true;
  }

  close(): void {
    this.dialogRef.close(undefined);
  }

  private finish(config: Record<string, unknown>): void {
    const tile = this.catalog.find((t) => t.type === this.widgetType);
    const [gsW, gsH] = tile?.defaultSize ?? [4, 3];
    this.dialogRef.close({
      widget_type: this.widgetType,
      title: this.title.trim(),
      gs_w: gsW,
      gs_h: gsH,
      config,
    });
  }

  save(): void {
    const config: Record<string, unknown> = {};
    if (this.widgetType === 'top_hosts' || this.widgetType === 'problems') {
      config['limit'] = this.limit;
    } else if (this.widgetType === 'stat') {
      config['stat_source'] = this.statSource;
    } else if (this.widgetType === 'gauge') {
      config['agent_id'] = this.agentId;
      config['metric'] = this.metric.trim();
      if (this.warn !== null) config['warn'] = this.warn;
      if (this.crit !== null) config['crit'] = this.crit;
    } else if (this.widgetType === 'timeseries') {
      if (this.chartSource === 'saved') {
        this.finish({ graph_id: this.graphId });
        return;
      }
      // A new chart is SAVED first, then referenced — the graph is the definition and the
      // widget is a place that shows it. Closing the dialog before the graph exists would
      // leave a widget pointing at nothing.
      this.saving.set(true);
      this.graphService
        .create({
          name: (this.graphName.trim() || this.title.trim()),
          graph_type: 'normal',
          show_legend: this.items.length > 1,
          items: this.items.map((it, i) => ({
            ...it,
            label: (it.label || '').trim() || it.metric,
            sort_order: i,
          })),
        })
        .subscribe({
          next: (graph) => {
            this.saving.set(false);
            this.finish({ graph_id: graph.id });
          },
          error: (err) => {
            this.saving.set(false);
            // Stay open and say why: a 409 means the chart name is taken, and silently
            // closing would look like the widget had been added.
            this.saveError.set(err?.error?.detail || 'The chart could not be saved.');
          },
        });
      return;
    }
    this.finish(config);
  }
}
