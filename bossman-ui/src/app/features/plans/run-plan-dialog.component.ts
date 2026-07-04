import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { FormControl, FormGroup, ReactiveFormsModule, ValidatorFn, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { PlanService } from '../../core/services/plan.service';
import { RunService } from '../../core/services/run.service';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { PlanDetail, PlanParam } from '../../core/models/plan.model';
import { PlanRunDetail } from '../../core/models/run.model';
import { HostPickerComponent } from '../../shared/components/host-picker/host-picker.component';
import { HostStatusBadgeComponent } from '../../shared/components/host-status-badge/host-status-badge.component';
import { runStatusBadge } from '../../shared/status.util';

export interface RunPlanDialogData {
  plan: PlanDetail;
}

type Stage = 'form' | 'previewing' | 'previewed' | 'applying' | 'applied';

interface ParamEntry {
  name: string;
  spec: PlanParam;
}

/**
 * The "Ausführen"-Dialog from docs/plan.md's Bossman plan (section C.1):
 * host picker -> parameter form -> preview (check_mode / dry_run) ->
 * confirm -> real apply. Mirrors the Nordstern-UX check_mode-first flow
 * the whole project is built around, at the UI layer.
 */
@Component({
  selector: 'app-run-plan-dialog',
  standalone: true,
  imports: [
    ReactiveFormsModule,
    MatDialogModule,
    MatFormFieldModule,
    MatInputModule,
    MatCheckboxModule,
    MatButtonModule,
    MatProgressSpinnerModule,
    HostPickerComponent,
    HostStatusBadgeComponent,
  ],
  template: `
    <h2 mat-dialog-title>Run {{ data.plan.name }}</h2>
    <mat-dialog-content>
      @if (stage() === 'form') {
        <app-host-picker [agents]="agents()" (selected)="selectedHost.set($event)" />
        <form [formGroup]="form" class="bm-param-form">
          @for (p of paramEntries; track p.name) {
            @if (p.spec.type === 'bool') {
              <mat-checkbox [formControlName]="p.name">{{ p.name }}</mat-checkbox>
            } @else {
              <mat-form-field appearance="outline" class="bm-full-width">
                <mat-label>{{ p.name }}{{ p.spec.required ? ' *' : '' }}</mat-label>
                <input matInput [type]="p.spec.type === 'number' ? 'number' : 'text'" [formControlName]="p.name" />
              </mat-form-field>
            }
          }
        </form>
      }

      @if (stage() === 'previewing' || stage() === 'applying') {
        <div class="bm-loading"><mat-spinner diameter="32" /></div>
      }

      @if (stage() === 'previewed' && previewResult(); as preview) {
        <h3>Preview result (dry run)</h3>
        <app-status-badge [status]="statusOf(preview.status)" [label]="preview.status" />
        <ul class="bm-step-list">
          @for (step of preview.steps; track step.step_index) {
            <li>
              <strong>{{ step.step_name }}</strong> ({{ step.module }})
              @if (step.error) {
                — <span class="bm-error">{{ step.error }}</span>
              } @else {
                — changed: {{ step.changed }}
              }
            </li>
          }
        </ul>
      }

      @if (stage() === 'applied' && applyResult(); as result) {
        <h3>Applied</h3>
        <app-status-badge [status]="statusOf(result.status)" [label]="result.status" />
      }

      @if (error()) {
        <p class="bm-error">{{ error() }}</p>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      @if (stage() === 'form') {
        <button mat-button (click)="dialogRef.close()">Cancel</button>
        <button mat-raised-button color="primary" [disabled]="!canPreview()" (click)="preview()">
          Preview (dry run)
        </button>
      }
      @if (stage() === 'previewed') {
        <button mat-button (click)="stage.set('form')">Back</button>
        <button mat-raised-button color="primary" (click)="apply()">Apply for real</button>
      }
      @if (stage() === 'applied') {
        <button mat-raised-button color="primary" (click)="viewRun()">View run</button>
      }
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width {
        width: 100%;
      }
      .bm-param-form {
        display: flex;
        flex-direction: column;
        gap: 4px;
        margin-top: 12px;
      }
      .bm-loading {
        display: flex;
        justify-content: center;
        padding: 24px;
      }
      .bm-step-list {
        list-style: none;
        padding: 0;
      }
      .bm-step-list li {
        padding: 6px 0;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-error {
        color: var(--bm-red);
      }
    `,
  ],
})
export class RunPlanDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<RunPlanDialogComponent>);
  private planService = inject(PlanService);
  private runService = inject(RunService);
  private agentService = inject(AgentService);
  private router = inject(Router);

  agents = signal<Agent[]>([]);
  selectedHost = signal<string | null>(null);
  stage = signal<Stage>('form');
  previewResult = signal<PlanRunDetail | null>(null);
  applyResult = signal<PlanRunDetail | null>(null);
  error = signal<string | null>(null);

  paramEntries: ParamEntry[] = [];
  form = new FormGroup<Record<string, FormControl>>({});

  constructor(@Inject(MAT_DIALOG_DATA) public data: RunPlanDialogData) {
    this.paramEntries = Object.entries(data.plan.params).map(([name, spec]) => ({ name, spec }));
    const controls: Record<string, FormControl> = {};
    for (const { name, spec } of this.paramEntries) {
      const validators: ValidatorFn[] = [];
      if (spec.required) validators.push(Validators.required);
      if (spec.pattern) validators.push(Validators.pattern(spec.pattern));
      const defaultValue = spec.default ?? (spec.type === 'bool' ? false : '');
      controls[name] = new FormControl(defaultValue, validators);
    }
    this.form = new FormGroup(controls);
  }

  ngOnInit(): void {
    this.agentService.list().subscribe((agents) => this.agents.set(agents));
  }

  canPreview(): boolean {
    return !!this.selectedHost() && this.form.valid;
  }

  preview(): void {
    this.runPlan(true, 'previewing', 'previewed', this.previewResult);
  }

  apply(): void {
    this.runPlan(false, 'applying', 'applied', this.applyResult);
  }

  private runPlan(dryRun: boolean, busyStage: Stage, doneStage: Stage, target: typeof this.previewResult): void {
    const host = this.selectedHost();
    if (!host) return;
    this.error.set(null);
    this.stage.set(busyStage);
    this.planService.run(this.data.plan.name, { agent: host, params: this.form.getRawValue(), dry_run: dryRun }).subscribe({
      next: (res) => {
        this.runService.get(res.plan_run_id).subscribe({
          next: (detail) => {
            target.set(detail);
            this.stage.set(doneStage);
          },
          error: () => {
            this.error.set('Run started but its detail could not be loaded.');
            this.stage.set('form');
          },
        });
      },
      error: (err) => {
        this.error.set(err.error?.detail ?? 'Failed to run plan.');
        this.stage.set('form');
      },
    });
  }

  statusOf(status: string) {
    return runStatusBadge(status);
  }

  viewRun(): void {
    const result = this.applyResult();
    if (!result) return;
    this.dialogRef.close();
    this.router.navigate(['/runs', result.id]);
  }
}
