import { Component, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { forkJoin, of } from 'rxjs';
import { catchError, map } from 'rxjs/operators';
import { DashboardService, Dashboard } from '../../core/services/dashboard.service';
import { DashboardWidget, WidgetData } from '../../core/models/dashboard.model';
import { DashboardWidgetComponent } from '../../shared/components/dashboard-widget/dashboard-widget.component';

/** NOC view (gap #14): a chrome-less, full-screen, auto-refreshing wall display
 * of a saved dashboard. Read-only (reuses the dashboard-widget renderer),
 * optional rotation through several dashboards, native fullscreen. For an ops
 * screen / big-board. The editable dashboards live in Fleet Overview. */
@Component({
  selector: 'app-noc',
  standalone: true,
  imports: [DatePipe, FormsModule, MatIconModule, DashboardWidgetComponent],
  template: `
    <div class="noc" [class.noc--idle]="idle()">
      <div class="noc-bar">
        <div class="noc-left">
          <mat-icon class="noc-logo">desktop_windows</mat-icon>
          <select [ngModel]="selectedId()" (ngModelChange)="pick($event)" title="Dashboard">
            @for (d of dashboards(); track d.id) { <option [value]="d.id">{{ d.name }}</option> }
          </select>
          <label class="noc-rotate" title="Cycle through all dashboards">
            <input type="checkbox" [ngModel]="rotate()" (ngModelChange)="setRotate($event)" /> rotate
          </label>
        </div>
        <div class="noc-right">
          <span class="noc-clock">{{ now() | date:'EEE HH:mm:ss' }}</span>
          <select [ngModel]="refreshSecs()" (ngModelChange)="setRefresh($event)" title="Refresh interval">
            <option [value]="10">10s</option><option [value]="30">30s</option>
            <option [value]="60">1m</option><option [value]="300">5m</option>
          </select>
          <button class="noc-btn" (click)="toggleFullscreen()" title="Fullscreen"><mat-icon>{{ isFullscreen() ? 'fullscreen_exit' : 'fullscreen' }}</mat-icon></button>
          <button class="noc-btn" (click)="exit()" title="Exit NOC view"><mat-icon>close</mat-icon></button>
        </div>
      </div>

      @if (widgets().length) {
        <div class="noc-grid">
          @for (w of widgets(); track w.id) {
            <div class="noc-cell" [style.grid-column]="'span ' + w.gs_w" [style.grid-row]="'span ' + w.gs_h">
              <app-dashboard-widget [widget]="w" [data]="widgetData()[w.id] ?? null" [editMode]="false" />
            </div>
          }
        </div>
      } @else {
        <div class="noc-empty">
          <mat-icon>dashboard</mat-icon>
          <p>{{ dashboards().length ? 'This dashboard has no widgets. Add some in Fleet Overview.' : 'No dashboards yet — create one in Fleet Overview.' }}</p>
        </div>
      }
    </div>
  `,
  styles: [`
    :host { display: block; }
    .noc { min-height: 100vh; background: #0b0f14; color: #e6edf3; padding: 0 0 24px; }
    .noc-bar { position: sticky; top: 0; z-index: 10; display: flex; justify-content: space-between; align-items: center;
      gap: 12px; padding: 10px 18px; background: #0d1218; border-bottom: 1px solid #1c2530; transition: opacity .4s; }
    .noc--idle .noc-bar { opacity: 0.12; }
    .noc-bar:hover { opacity: 1; }
    .noc-left, .noc-right { display: flex; align-items: center; gap: 12px; }
    .noc-logo { color: #4a9eff; }
    .noc select { background: #131a22; color: #e6edf3; border: 1px solid #2a3644; border-radius: 6px; padding: 5px 8px; font: inherit; font-size: 13px; }
    .noc-rotate { display: flex; align-items: center; gap: 5px; font-size: 13px; opacity: 0.8; }
    .noc-clock { font-variant-numeric: tabular-nums; font-size: 15px; font-weight: 600; letter-spacing: 0.5px; }
    .noc-btn { background: transparent; border: none; color: #9fb0c0; cursor: pointer; display: flex; padding: 4px; border-radius: 6px; }
    .noc-btn:hover { background: #1c2530; color: #e6edf3; }
    .noc-grid { display: grid; grid-template-columns: repeat(12, 1fr); grid-auto-rows: 92px; gap: 12px; padding: 16px 18px; }
    .noc-cell { min-height: 0; min-width: 0; background: #111820; border: 1px solid #1c2530; border-radius: 12px; overflow: hidden; }
    .noc-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; height: 70vh; opacity: 0.5; }
    .noc-empty mat-icon { font-size: 56px; width: 56px; height: 56px; }
  `],
})
export class NocComponent implements OnInit, OnDestroy {
  private svc = inject(DashboardService);
  private router = inject(Router);
  private route = inject(ActivatedRoute);

  dashboards = signal<Dashboard[]>([]);
  selectedId = signal<string>('');
  widgets = signal<DashboardWidget[]>([]);
  widgetData = signal<Record<string, WidgetData>>({});
  refreshSecs = signal<number>(30);
  rotate = signal<boolean>(false);
  now = signal<Date>(new Date(0));
  isFullscreen = signal<boolean>(false);
  idle = signal<boolean>(false);

  private dataTimer?: ReturnType<typeof setInterval>;
  private clockTimer?: ReturnType<typeof setInterval>;
  private rotateTimer?: ReturnType<typeof setInterval>;
  private idleTimer?: ReturnType<typeof setTimeout>;
  private fsHandler = () => this.isFullscreen.set(!!document.fullscreenElement);
  private moveHandler = () => this.wake();

  ngOnInit(): void {
    this.svc.listDashboards().subscribe((ds) => {
      this.dashboards.set(ds);
      const qp = this.route.snapshot.queryParamMap.get('dashboard');
      const initial = qp || ds.find((d) => d.is_default)?.id || ds[0]?.id || '';
      if (initial) this.pick(initial);
    });
    this.clockTimer = setInterval(() => this.now.set(new Date()), 1000);
    this.startDataTimer();
    document.addEventListener('fullscreenchange', this.fsHandler);
    window.addEventListener('mousemove', this.moveHandler);
    this.wake();
  }
  ngOnDestroy(): void {
    for (const t of [this.dataTimer, this.rotateTimer]) if (t) clearInterval(t);
    if (this.clockTimer) clearInterval(this.clockTimer);
    if (this.idleTimer) clearTimeout(this.idleTimer);
    document.removeEventListener('fullscreenchange', this.fsHandler);
    window.removeEventListener('mousemove', this.moveHandler);
  }

  pick(id: string): void {
    this.selectedId.set(id);
    this.svc.list(id).subscribe((ws) => {
      this.widgets.set([...ws].sort((a, b) => a.gs_y - b.gs_y || a.gs_x - b.gs_x));
      this.loadData();
    });
  }

  private loadData(): void {
    const ws = this.widgets();
    if (!ws.length) { this.widgetData.set({}); return; }
    forkJoin(ws.map((w) =>
      this.svc.data(w.id).pipe(map((d) => [w.id, d] as const), catchError(() => of([w.id, null] as const))),
    )).subscribe((pairs) => {
      const m: Record<string, WidgetData> = {};
      for (const [id, d] of pairs) if (d) m[id] = d;
      this.widgetData.set(m);
    });
  }

  private startDataTimer(): void {
    if (this.dataTimer) clearInterval(this.dataTimer);
    this.dataTimer = setInterval(() => this.loadData(), this.refreshSecs() * 1000);
  }
  setRefresh(s: number): void { this.refreshSecs.set(Number(s)); this.startDataTimer(); }

  setRotate(on: boolean): void {
    this.rotate.set(on);
    if (this.rotateTimer) { clearInterval(this.rotateTimer); this.rotateTimer = undefined; }
    if (on) {
      this.rotateTimer = setInterval(() => {
        const ds = this.dashboards();
        if (ds.length < 2) return;
        const i = ds.findIndex((d) => d.id === this.selectedId());
        this.pick(ds[(i + 1) % ds.length].id);
      }, 30000);
    }
  }

  toggleFullscreen(): void {
    if (document.fullscreenElement) document.exitFullscreen();
    else document.documentElement.requestFullscreen?.();
  }
  exit(): void { if (document.fullscreenElement) document.exitFullscreen(); this.router.navigate(['/fleet']); }

  private wake(): void {
    this.idle.set(false);
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.idle.set(true), 5000);
  }
}
