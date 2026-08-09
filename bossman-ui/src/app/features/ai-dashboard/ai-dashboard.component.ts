import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { ChatService } from '../../core/services/chat.service';
import { GeneratedWidgetSpec } from '../../core/models/chat.model';
import { DashboardWidget } from '../../core/models/dashboard.model';
import { DashboardWidgetComponent } from '../../shared/components/dashboard-widget/dashboard-widget.component';

/** Block W2 — the AI-generated dashboard. The user describes what they want,
 * the configured AI designs a set of widgets (calling fleet tools for real
 * data), and they render here in a responsive grid via the shared widget
 * component. Persisted per user (last generation wins). */
@Component({
  selector: 'app-ai-dashboard',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule, DashboardWidgetComponent],
  template: `
    <div class="bm-aidash">
      <div class="bm-aidash-bar">
        <mat-icon class="bm-aidash-spark">auto_awesome</mat-icon>
        <input
          class="bm-aidash-prompt"
          type="text"
          placeholder="Describe the dashboard you want… (e.g. 'fleet health + hosts by state + open problems')"
          [value]="prompt()"
          (input)="prompt.set($any($event.target).value)"
          [disabled]="busy()"
          (keyup.enter)="generate()"
        />
        <button mat-flat-button color="primary" (click)="generate()" [disabled]="busy()">
          @if (busy()) { <mat-spinner diameter="18" /> Generating… } @else { Generate }
        </button>
      </div>

      @if (err()) { <p class="bm-aidash-err">{{ err() }}</p> }

      @if (saved(); as s) {
        <div class="bm-aidash-saved">
          <mat-icon>check_circle</mat-icon>
          <span>Saved as dashboard <strong>{{ s.name }}</strong> — editable in Fleet Overview.</span>
          <button mat-stroked-button (click)="openSaved()"><mat-icon>open_in_new</mat-icon> Open editable dashboard</button>
        </div>
      }

      @if (widgets().length) {
        <div class="bm-aidash-grid">
          @for (w of built(); track $index) {
            <div class="bm-aidash-cell" [style.grid-column]="'span ' + span(w.widget.gs_w)">
              <app-dashboard-widget [widget]="w.widget" [data]="w.data" />
            </div>
          }
        </div>
      } @else if (!busy()) {
        <div class="bm-aidash-empty">
          <mat-icon>insights</mat-icon>
          <p>No dashboard yet. Describe what you want and hit Generate — the assistant designs it from live fleet data.</p>
        </div>
      }
    </div>
  `,
  styles: [
    `
      .bm-aidash { padding: 16px; height: 100%; overflow: auto; }
      .bm-aidash-bar { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
      .bm-aidash-spark { color: var(--mat-sys-tertiary); }
      .bm-aidash-prompt { flex: 1; padding: 10px 12px; border: 1px solid var(--mat-sys-outline); border-radius: 8px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-aidash-err { color: var(--mat-sys-error); }
      .bm-aidash-saved { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; padding: 8px 12px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); border: 1px solid var(--mat-sys-primary); }
      .bm-aidash-saved mat-icon { color: var(--mat-sys-primary); }
      .bm-aidash-grid { display: grid; grid-template-columns: repeat(12, 1fr); gap: 12px; }
      .bm-aidash-cell { min-height: 200px; }
      .bm-aidash-empty { display: flex; flex-direction: column; align-items: center; gap: 8px; color: var(--mat-sys-on-surface-variant); padding: 60px; text-align: center; }
      .bm-aidash-empty mat-icon { font-size: 42px; width: 42px; height: 42px; }
      @media (max-width: 900px) { .bm-aidash-cell { grid-column: span 12 !important; } }
    `,
  ],
})
export class AiDashboardComponent implements OnInit {
  private chat = inject(ChatService);
  private router = inject(Router);

  prompt = signal('');
  widgets = signal<GeneratedWidgetSpec[]>([]);
  busy = signal(false);
  err = signal<string | null>(null);
  saved = signal<{ id: string; name: string } | null>(null);

  built = computed(() =>
    this.widgets().map((spec, i) => ({
      widget: {
        id: String(i),
        widget_type: spec.widget_type as DashboardWidget['widget_type'],
        title: spec.title ?? '',
        gs_x: 0,
        gs_y: 0,
        gs_w: spec.gs_w ?? 4,
        gs_h: spec.gs_h ?? 4,
        config: {},
        pinned: false,
        hidden: false,
        created_at: '',
      } as DashboardWidget,
      data: (spec.data ?? null) as any,
    })),
  );

  span(w: number): number {
    return Math.max(2, Math.min(12, w || 4));
  }

  openSaved(): void {
    const s = this.saved();
    if (s) this.router.navigate(['/fleet'], { queryParams: { dashboard: s.id } });
  }

  ngOnInit(): void {
    this.chat.getDashboard().subscribe({
      next: (res) => {
        this.widgets.set(res.widgets ?? []);
        if (res.prompt) this.prompt.set(res.prompt);
      },
      error: () => {},
    });
  }

  generate(): void {
    if (this.busy()) return;
    this.busy.set(true);
    this.err.set(null);
    this.chat.generateDashboard(this.prompt().trim()).subscribe({
      next: (res) => {
        this.widgets.set(res.widgets ?? []);
        this.busy.set(false);
        if (res.dashboard_id) this.saved.set({ id: res.dashboard_id, name: res.dashboard_name ?? 'AI dashboard' });
      },
      error: (e) => {
        this.busy.set(false);
        this.err.set(e?.error?.detail ?? 'generation failed — is the AI backend configured/logged in?');
      },
    });
  }
}
