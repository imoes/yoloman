import { AfterViewInit, Component, ElementRef, Injector, OnDestroy, ViewChild, afterNextRender, computed, inject, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatDialog } from '@angular/material/dialog';
import { MatIconModule } from '@angular/material/icon';
import { ActivatedRoute } from '@angular/router';
import { GridItemHTMLElement, GridStack } from 'gridstack';
import { Dashboard, DashboardService } from '../../core/services/dashboard.service';
import { DashboardWidget, WidgetData } from '../../core/models/dashboard.model';
import { DashboardWidgetComponent } from '../../shared/components/dashboard-widget/dashboard-widget.component';
import { FilterBarComponent, FilterDef, FilterValues } from '../../shared/components/filter-bar/filter-bar.component';
import { AddWidgetDialogComponent } from './add-widget-dialog.component';

/** The GridStack-backed, server-persisted widget dashboard on Fleet
 * Overview (see docs/plan.md's monitoring-cockpit ergänzung Block F5) —
 * modeled directly on CentralStation's own dashboard.component.ts: grid
 * init via afterNextRender (guarantees the @for-rendered grid-stack-item
 * elements exist before GridStack measures them), drag/resize gated by an
 * edit-mode signal, saveLayout() reads back GridStack's own node geometry
 * and PATCHes it per widget. */
@Component({
  selector: 'app-dashboard-grid',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, DashboardWidgetComponent, FilterBarComponent],
  template: `
    <div class="bm-dashboard-toolbar">
      <div class="bm-dashboard-picker">
        <select class="bm-dash-select" (change)="switchDashboard($any($event.target).value)">
          @for (d of dashboards(); track d.id) {
            <option [value]="d.id" [selected]="d.id === currentId()">{{ d.name }}{{ d.is_default ? ' ★' : '' }}{{ d.source === 'ai' ? ' (AI)' : '' }}</option>
          }
        </select>
        <button mat-icon-button title="New dashboard" (click)="newDashboard()"><mat-icon>add_box</mat-icon></button>
        @if (current(); as c) {
          <button mat-icon-button title="Rename" (click)="renameDashboard()"><mat-icon>edit</mat-icon></button>
          <button mat-icon-button title="Set as default" [disabled]="c.is_default" (click)="setDefault()"><mat-icon>{{ c.is_default ? 'star' : 'star_border' }}</mat-icon></button>
          <button mat-icon-button title="Delete dashboard" [disabled]="dashboards().length <= 1" (click)="deleteDashboard()"><mat-icon>delete</mat-icon></button>
        }
      </div>
      <div class="bm-dashboard-actions">
        @if (editMode()) {
          <button mat-button (click)="addWidget()">
            <mat-icon>add</mat-icon>
            Add widget
          </button>
        }
        <button mat-stroked-button [color]="editMode() ? 'primary' : undefined" (click)="toggleEditMode()">
          <mat-icon>{{ editMode() ? 'done' : 'dashboard_customize' }}</mat-icon>
          {{ editMode() ? 'Save layout' : 'Customize' }}
        </button>
      </div>
    </div>

    @if (current()) {
      <app-filter-bar class="bm-dash-filters" [filters]="contextFilters" [values]="contextValues()" (valuesChange)="onContext($event)" />
    }

    @if (!widgets().length && !editMode()) {
      <div class="bm-dashboard-empty">
        <p>No dashboard widgets yet.</p>
        <button mat-flat-button color="primary" (click)="enterEditModeAndAdd()">
          <mat-icon>add</mat-icon>
          Add your first widget
        </button>
      </div>
    } @else {
      <div #grid class="grid-stack" [class.bm-edit-mode]="editMode()">
        @for (widget of widgets(); track widget.id) {
          <div class="grid-stack-item" [attr.gs-id]="widget.id" [attr.gs-x]="widget.gs_x" [attr.gs-y]="widget.gs_y" [attr.gs-w]="widget.gs_w" [attr.gs-h]="widget.gs_h">
            <div class="grid-stack-item-content">
              <app-dashboard-widget [widget]="widget" [data]="widgetData()[widget.id] ?? null" [editMode]="editMode()" (remove)="deleteWidget(widget.id)" />
            </div>
          </div>
        }
      </div>
    }
  `,
  styles: [
    `
      .bm-dashboard-toolbar {
        display: flex;
        align-items: center;
        justify-content: space-between;
        margin-bottom: 12px;
      }
      .bm-dashboard-toolbar h2 {
        margin: 0;
        font-size: 18px;
      }
      .bm-dashboard-actions {
        display: flex;
        gap: 8px;
      }
      .bm-dashboard-picker {
        display: flex;
        align-items: center;
        gap: 2px;
      }
      .bm-dash-filters {
        display: block;
        margin-bottom: 12px;
        padding: 8px 10px;
        border-radius: 8px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 3%, transparent);
      }
      .bm-dash-select {
        padding: 6px 10px;
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 6px;
        background: var(--mat-sys-surface);
        color: inherit;
        font-size: 15px;
        font-weight: 600;
        max-width: 260px;
      }
      .bm-dashboard-empty {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 12px;
        padding: 40px 16px;
        opacity: 0.75;
      }
      .grid-stack {
        min-height: 120px;
      }
      .grid-stack.bm-edit-mode {
        background-image: linear-gradient(var(--mat-sys-outline-variant) 1px, transparent 1px), linear-gradient(90deg, var(--mat-sys-outline-variant) 1px, transparent 1px);
        background-size: 80px 80px;
      }
      .grid-stack-item-content {
        inset: 4px !important;
        overflow: hidden !important;
      }
    `,
  ],
})
export class DashboardGridComponent implements AfterViewInit, OnDestroy {
  @ViewChild('grid') private gridEl!: ElementRef<HTMLElement>;

  private dashboardService = inject(DashboardService);
  private dialog = inject(MatDialog);
  private injector = inject(Injector);
  private route = inject(ActivatedRoute);

  widgets = signal<DashboardWidget[]>([]);
  widgetData = signal<Record<string, WidgetData | undefined>>({});
  editMode = signal(false);
  dashboards = signal<Dashboard[]>([]);
  currentId = signal<string | null>(null);
  current = computed(() => this.dashboards().find((d) => d.id === this.currentId()) ?? null);
  contextValues = computed<FilterValues>(() => (this.current()?.context as FilterValues) ?? {});
  contextFilters: FilterDef[] = [
    { ident: 'host', label: 'Host', kind: 'text', placeholder: 'Scope widgets to host…' },
    { ident: 'state', label: 'State', kind: 'select', options: [
      { value: 'OK', label: 'OK' }, { value: 'WARN', label: 'WARN' },
      { value: 'CRIT', label: 'CRIT' }, { value: 'UNKNOWN', label: 'UNKNOWN' },
    ] },
  ];
  private grid?: GridStack;

  ngAfterViewInit(): void {
    // ?dashboard=<id> (e.g. from the AI page's "open editable dashboard") preselects it.
    this.loadDashboards(this.route.snapshot.queryParamMap.get('dashboard') ?? undefined);
  }

  ngOnDestroy(): void {
    this.grid?.destroy(false);
  }

  private loadDashboards(selectId?: string): void {
    this.dashboardService.listDashboards().subscribe((dashboards) => {
      this.dashboards.set(dashboards);
      const pick =
        (selectId && dashboards.find((d) => d.id === selectId)?.id) ||
        dashboards.find((d) => d.is_default)?.id ||
        dashboards[0]?.id ||
        null;
      this.currentId.set(pick);
      if (pick) this.loadWidgets();
      else this.widgets.set([]);
    });
  }

  switchDashboard(id: string): void {
    if (id === this.currentId()) return;
    if (this.editMode()) this.toggleEditMode(); // save the layout of the one we're leaving
    this.currentId.set(id);
    this.loadWidgets();
  }

  newDashboard(): void {
    const name = window.prompt('New dashboard name:')?.trim();
    if (!name) return;
    this.dashboardService.createDashboard({ name }).subscribe((d) => this.loadDashboards(d.id));
  }

  renameDashboard(): void {
    const c = this.current();
    if (!c) return;
    const name = window.prompt('Rename dashboard:', c.name)?.trim();
    if (!name || name === c.name) return;
    this.dashboardService.updateDashboard(c.id, { name }).subscribe(() => this.loadDashboards(c.id));
  }

  setDefault(): void {
    const c = this.current();
    if (!c || c.is_default) return;
    this.dashboardService.updateDashboard(c.id, { is_default: true }).subscribe(() => this.loadDashboards(c.id));
  }

  deleteDashboard(): void {
    const c = this.current();
    if (!c || this.dashboards().length <= 1) return;
    if (!window.confirm(`Delete dashboard "${c.name}" and its widgets?`)) return;
    this.dashboardService.deleteDashboard(c.id).subscribe(() => this.loadDashboards());
  }

  private loadWidgets(): void {
    const id = this.currentId() ?? undefined;
    this.dashboardService.list(id).subscribe((widgets) => {
      this.widgets.set(widgets);
      this.widgetData.set({});
      this.rebuildGrid(true);
    });
  }

  /** Persist the dashboard's filter context and re-fetch widget data so the
   * item widgets (top_hosts/problems) rescope — Checkmk's per-dashboard context. */
  onContext(values: FilterValues): void {
    const c = this.current();
    if (!c) return;
    this.dashboards.update((ds) => ds.map((d) => (d.id === c.id ? { ...d, context: values as Record<string, unknown> } : d)));
    this.dashboardService.updateDashboard(c.id, { context: values as Record<string, unknown> }).subscribe({
      next: () => this.widgets().forEach((w) => this.loadWidgetData(w.id)),
      error: () => this.widgets().forEach((w) => this.loadWidgetData(w.id)),
    });
  }

  private rebuildGrid(loadData = false): void {
    afterNextRender(
      () => {
        this.grid?.destroy(false);
        if (!this.widgets().length) return;
        this.grid = GridStack.init(
          {
            cellHeight: 90,
            minRow: 2,
            margin: 8,
            float: false,
            disableDrag: !this.editMode(),
            disableResize: !this.editMode(),
          },
          this.gridEl.nativeElement,
        );
        if (loadData) {
          this.widgets().forEach((w) => this.loadWidgetData(w.id));
        }
      },
      { injector: this.injector },
    );
  }

  private loadWidgetData(widgetId: string): void {
    this.dashboardService.data(widgetId).subscribe({
      next: (data) => this.widgetData.update((m) => ({ ...m, [widgetId]: data })),
      error: () => undefined,
    });
  }

  toggleEditMode(): void {
    const next = !this.editMode();
    this.editMode.set(next);
    if (next) {
      this.grid?.enable();
    } else {
      this.grid?.disable();
      this.saveLayout();
    }
  }

  private saveLayout(): void {
    const items = this.grid?.getGridItems() ?? [];
    for (const el of items) {
      const patch = this.layoutPatch(el);
      if (!patch) continue;
      this.dashboardService.update(patch.id, patch.body).subscribe();
    }
  }

  private layoutPatch(el: GridItemHTMLElement): { id: string; body: { gs_x: number; gs_y: number; gs_w: number; gs_h: number } } | null {
    const id = el.getAttribute('gs-id');
    const n = el.gridstackNode;
    if (!id || !n) return null;
    return { id, body: { gs_x: n.x ?? 0, gs_y: n.y ?? 0, gs_w: n.w ?? 4, gs_h: n.h ?? 3 } };
  }

  enterEditModeAndAdd(): void {
    this.editMode.set(true);
    this.addWidget();
  }

  addWidget(): void {
    const ref = this.dialog.open(AddWidgetDialogComponent, { width: '520px' });
    ref.afterClosed().subscribe((payload) => {
      if (!payload) return;
      const withDash = { ...payload, dashboard_id: this.currentId() ?? undefined };
      this.dashboardService.create(withDash).subscribe((widget) => {
        this.widgets.update((ws) => [...ws, widget]);
        this.rebuildGrid();
        this.loadWidgetData(widget.id);
      });
    });
  }

  deleteWidget(widgetId: string): void {
    this.dashboardService.delete(widgetId).subscribe(() => {
      this.widgets.update((ws) => ws.filter((w) => w.id !== widgetId));
      this.widgetData.update((data) => {
        const next = { ...data };
        delete next[widgetId];
        return next;
      });
      this.rebuildGrid();
    });
  }
}
