import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatDialog } from '@angular/material/dialog';
import { PlanService } from '../../core/services/plan.service';
import { PlanDetail } from '../../core/models/plan.model';
import { RunPlanDialogComponent } from './run-plan-dialog.component';

@Component({
  selector: 'app-plan-detail',
  standalone: true,
  imports: [MatCardModule, MatButtonModule, MatIconModule],
  template: `
    @if (plan(); as plan) {
      <div class="bm-page">
        <div class="bm-header-row">
          <h1>{{ plan.name }}</h1>
          <button mat-raised-button color="primary" (click)="openRunDialog(plan)">
            <mat-icon>play_arrow</mat-icon>
            Run
          </button>
        </div>
        <p>{{ plan.description }}</p>

        <mat-card>
          <mat-card-header>
            <mat-card-title>Parameters</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            @if (paramNames(plan).length) {
              <table class="bm-table">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Type</th>
                    <th>Required</th>
                    <th>Default</th>
                  </tr>
                </thead>
                <tbody>
                  @for (name of paramNames(plan); track name) {
                    <tr>
                      <td>{{ name }}</td>
                      <td>{{ plan.params[name].type }}</td>
                      <td>{{ plan.params[name].required ? 'yes' : 'no' }}</td>
                      <td>{{ plan.params[name].default ?? '—' }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else {
              <p class="bm-empty">This plan takes no parameters.</p>
            }
          </mat-card-content>
        </mat-card>

        <mat-card class="bm-steps-card">
          <mat-card-header>
            <mat-card-title>Steps</mat-card-title>
          </mat-card-header>
          <mat-card-content>
            <ol class="bm-step-list">
              @for (step of plan.steps; track step.name) {
                <li>
                  <strong>{{ step.name }}</strong>
                  <span class="bm-step-kind">{{ step.kind }}</span>
                  @if (step.module) {
                    <span class="bm-step-module">{{ step.module }}</span>
                  }
                  @if (step.check_mode) {
                    <span class="bm-step-flag">check_mode</span>
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
        justify-content: space-between;
        margin-bottom: 4px;
      }
      .bm-steps-card {
        margin-top: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 8px 10px;
      }
      .bm-table td {
        padding: 8px 10px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-step-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
        padding-left: 20px;
      }
      .bm-step-kind,
      .bm-step-module,
      .bm-step-flag {
        margin-left: 8px;
        font-size: 12px;
        opacity: 0.7;
      }
      .bm-step-flag {
        color: var(--bm-gold);
        opacity: 1;
      }
      .bm-empty {
        opacity: 0.6;
      }
    `,
  ],
})
export class PlanDetailComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private planService = inject(PlanService);
  private dialog = inject(MatDialog);

  plan = signal<PlanDetail | null>(null);

  ngOnInit(): void {
    const name = this.route.snapshot.paramMap.get('name')!;
    this.planService.get(name).subscribe((plan) => this.plan.set(plan));
  }

  paramNames(plan: PlanDetail): string[] {
    return Object.keys(plan.params);
  }

  openRunDialog(plan: PlanDetail): void {
    this.dialog.open(RunPlanDialogComponent, {
      width: '520px',
      data: { plan },
    });
  }
}
