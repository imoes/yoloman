import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { DatePipe, JsonPipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { RunService } from '../../core/services/run.service';
import { PlanRunDetail } from '../../core/models/run.model';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { runStatusBadge } from '../../shared/status.util';

@Component({
  selector: 'app-run-detail',
  standalone: true,
  imports: [RouterLink, DatePipe, JsonPipe, MatCardModule, HostStatusBadgeComponent],
  template: `
    @if (run(); as run) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ run.plan_name }}</h1>
          <app-status-badge [status]="statusOf(run)" [label]="run.status" />
        </div>

        <dl class="bm-facts">
          <dt>Host</dt>
          <dd><a [routerLink]="['/hosts', run.agent_id]">{{ run.agent_id }}</a></dd>
          <dt>Requested by</dt>
          <dd>{{ run.requested_by || '—' }}</dd>
          <dt>Dry run</dt>
          <dd>{{ run.dry_run ? 'yes' : 'no' }}</dd>
          <dt>Plan version</dt>
          <dd>{{ run.plan_version || '—' }}</dd>
          <dt>Started</dt>
          <dd>{{ run.started_at | date: 'medium' }}</dd>
          <dt>Finished</dt>
          <dd>{{ run.finished_at ? (run.finished_at | date: 'medium') : 'running…' }}</dd>
          <dt>Params</dt>
          <dd><code>{{ run.params | json }}</code></dd>
        </dl>

        <mat-card class="bm-steps-card">
          <mat-card-header>
            <mat-card-title>Steps</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            <ol class="bm-step-list">
              @for (step of run.steps; track step.step_index) {
                <li>
                  <div class="bm-step-header">
                    <strong>{{ step.step_name }}</strong>
                    <span class="bm-step-module">{{ step.module }}</span>
                    @if (step.error) {
                      <span class="bm-step-error">error</span>
                    } @else if (step.changed !== null) {
                      <span class="bm-step-changed">changed: {{ step.changed }}</span>
                    }
                  </div>
                  @if (step.error) {
                    <p class="bm-error">{{ step.error }}</p>
                  }
                  @if (step.response_body) {
                    <pre class="bm-response">{{ step.response_body | json }}</pre>
                  }
                </li>
              }
            </ol>
          </mat-card-content>
        </mat-card>
      </div>
    }
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 900px;
        margin: 0 auto;
      }
      .bm-header-row {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .bm-facts {
        display: grid;
        grid-template-columns: 160px 1fr;
        row-gap: 8px;
        margin: 16px 0;
      }
      .bm-facts dt {
        opacity: 0.7;
      }
      .bm-facts dd {
        margin: 0;
        word-break: break-all;
      }
      .bm-steps-card {
        margin-top: 8px;
      }
      .bm-step-list {
        list-style: none;
        padding: 0;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }
      .bm-step-list li {
        border-top: 1px solid var(--mat-sys-outline-variant);
        padding-top: 12px;
      }
      .bm-step-header {
        display: flex;
        align-items: center;
        gap: 10px;
      }
      .bm-step-module {
        font-size: 12px;
        opacity: 0.7;
      }
      .bm-step-changed {
        font-size: 12px;
        color: var(--bm-green);
      }
      .bm-step-error {
        font-size: 12px;
        color: var(--bm-red);
        text-transform: uppercase;
      }
      .bm-response {
        background: color-mix(in srgb, var(--mat-sys-surface-container) 80%, transparent);
        padding: 8px;
        border-radius: 4px;
        font-size: 12px;
        overflow-x: auto;
      }
      .bm-error {
        color: var(--bm-red);
        font-size: 13px;
      }
    `,
  ],
})
export class RunDetailComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private runService = inject(RunService);

  run = signal<PlanRunDetail | null>(null);

  ngOnInit(): void {
    const id = this.route.snapshot.paramMap.get('id')!;
    this.runService.get(id).subscribe((run) => this.run.set(run));
  }

  statusOf(run: PlanRunDetail) {
    return runStatusBadge(run.status);
  }
}
