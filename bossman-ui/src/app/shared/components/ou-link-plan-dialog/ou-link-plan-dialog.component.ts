import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { OrchestrationPlan } from '../../../core/models/orchestration.model';
import { OrchestrationService } from '../../../core/services/orchestration.service';

export interface OuLinkPlanDialogData {
  ouId: string;
  ouPath: string;
}

/** Result: link an existing orchestration plan to an OU (Block L3c). */
export interface OuLinkPlanResult {
  plan_id: string;
  enforced: boolean;
  auto_apply: boolean;
}

/** Link an existing orchestration plan to this OU. Restores the orchestration
 * management the flat page had, now OU-scoped from the tree console. Creating
 * brand-new plans is a separate action (New orchestration plan in the header). */
@Component({
  selector: 'app-ou-link-plan-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Link orchestration plan to {{ data.ouPath }}</h2>
    <mat-dialog-content [formGroup]="form">
      @if (plans().length) {
        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>Plan</mat-label>
          <mat-select formControlName="plan_id">
            @for (p of plans(); track p.id) {
              <mat-option [value]="p.id">{{ p.display_name }} ({{ p.plan_type }})</mat-option>
            }
          </mat-select>
        </mat-form-field>
        <mat-slide-toggle formControlName="enforced">Enforced</mat-slide-toggle>
        <br /><br />
        <mat-slide-toggle formControlName="auto_apply">Activate immediately (skip approval)</mat-slide-toggle>
      } @else {
        <p class="bm-empty">No orchestration plans yet — create one first via “New orchestration plan”.</p>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid || !plans().length" (click)="save()">Link</button>
    </mat-dialog-actions>
  `,
  styles: [`.bm-full-width { width: 100%; } .bm-empty { opacity: 0.75; }`],
})
export class OuLinkPlanDialogComponent implements OnInit {
  dialogRef = inject(MatDialogRef<OuLinkPlanDialogComponent, OuLinkPlanResult>);
  private orchestration = inject(OrchestrationService);
  plans = signal<OrchestrationPlan[]>([]);

  form = new FormGroup({
    plan_id: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    enforced: new FormControl(false, { nonNullable: true }),
    auto_apply: new FormControl(false, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: OuLinkPlanDialogData) {}

  ngOnInit(): void {
    this.orchestration.listPlans().subscribe((p) => this.plans.set(p));
  }

  save(): void {
    this.dialogRef.close(this.form.getRawValue());
  }
}
