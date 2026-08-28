import { Component, OnInit, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { PlanService } from '../../core/services/plan.service';
import { Plan } from '../../core/models/plan.model';

/**
 * Plans: the runbooks Bossman holds, as a list.
 *
 * A PLAN IS THE INTENT, a run is one execution of it — the same distinction the whole product keeps between a
 * rule and its instances. This screen is the intent side: what may be run, with its parameters, from a
 * library that is the same for every host. Which hosts a plan has actually been run against, and how it went,
 * is the Runs screen; that split is deliberate, because "we have a patch plan" and "the patch plan ran on
 * these forty hosts" are different claims and merging them into one list is how the second gets assumed.
 */
@Component({
  selector: 'app-plans-list',
  standalone: true,
  imports: [RouterLink, MatCardModule, MatButtonModule],
  template: `
    <div class="bm-page">
      <h1>Plans</h1>
      <div class="bm-plan-grid">
        @for (plan of plans(); track plan.name) {
          <mat-card class="bm-plan-card">
            <mat-card-header>
              <mat-card-title>{{ plan.name }}</mat-card-title>
            </mat-card-header>
            <mat-card-content>
              <p>{{ plan.description || 'No description.' }}</p>
              <p class="bm-param-count">{{ paramCount(plan) }} parameter(s)</p>
            </mat-card-content>
            <mat-card-actions>
              <button mat-button [routerLink]="['/plans', plan.name]">View</button>
            </mat-card-actions>
          </mat-card>
        } @empty {
          <p class="bm-empty">No plans available — add one under the configured plans directory.</p>
        }
      </div>
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 1100px;
        margin: 0 auto;
      }
      .bm-plan-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
        gap: 16px;
      }
      .bm-param-count {
        font-size: 12px;
        opacity: 0.6;
      }
      .bm-empty {
        opacity: 0.6;
      }
    `,
  ],
})
export class PlansListComponent implements OnInit {
  private planService = inject(PlanService);
  plans = signal<Plan[]>([]);

  ngOnInit(): void {
    this.planService.list().subscribe((plans) => this.plans.set(plans));
  }

  paramCount(plan: Plan): number {
    return Object.keys(plan.params).length;
  }
}
