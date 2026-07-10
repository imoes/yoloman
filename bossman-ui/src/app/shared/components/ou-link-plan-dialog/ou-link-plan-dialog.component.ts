import { Component, Inject, OnInit, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { OrchestrationPlan, PlanLinkTargetType } from '../../../core/models/orchestration.model';
import { OrchestrationService } from '../../../core/services/orchestration.service';

export interface OuLinkPlanDialogData {
  ouId: string;
  ouPath: string;
  /** Block N3 — picker sources so a policy can be bound not only to the OU
   * but (GPO-style) to a specific host or host group within it. */
  hosts?: { id: string; name: string }[];
  groups?: { id: string; name: string }[];
}

/** Result: bind an existing orchestration plan to a target (Block L3c + N3).
 * target_type selects which id field is meaningful. */
export interface OuLinkPlanResult {
  plan_id: string;
  target_type: PlanLinkTargetType; // 'ou' | 'host' | 'group'
  ou_id: string | null;
  agent_id: string | null;
  host_group_id: string | null;
  enforced: boolean;
  auto_apply: boolean;
}

/** Bind an existing orchestration plan to this OU, or (GPO-style) to a
 * specific host or host group scoped within it. Creating brand-new plans is
 * a separate action (New Policy in the palette header). */
@Component({
  selector: 'app-ou-link-plan-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Bind policy within {{ data.ouPath }}</h2>
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

        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>Bind to</mat-label>
          <mat-select formControlName="target_type">
            <mat-option value="ou">This OU ({{ data.ouPath }})</mat-option>
            @if (data.hosts?.length) {
              <mat-option value="host">A specific host</mat-option>
            }
            @if (data.groups?.length) {
              <mat-option value="group">A host group</mat-option>
            }
          </mat-select>
        </mat-form-field>

        @if (form.controls.target_type.value === 'host') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Host</mat-label>
            <mat-select formControlName="agent_id">
              @for (h of data.hosts ?? []; track h.id) {
                <mat-option [value]="h.id">{{ h.name }}</mat-option>
              }
            </mat-select>
          </mat-form-field>
        }
        @if (form.controls.target_type.value === 'group') {
          <mat-form-field appearance="outline" class="bm-full-width">
            <mat-label>Host group</mat-label>
            <mat-select formControlName="host_group_id">
              @for (g of data.groups ?? []; track g.id) {
                <mat-option [value]="g.id">{{ g.name }}</mat-option>
              }
            </mat-select>
          </mat-form-field>
        }

        <mat-slide-toggle formControlName="enforced">Enforced</mat-slide-toggle>
        <br /><br />
        <mat-slide-toggle formControlName="auto_apply">Activate immediately (skip approval)</mat-slide-toggle>
      } @else {
        <p class="bm-empty">No orchestration plans yet — create one first via “New Policy”.</p>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="!canSave()" (click)="save()">Bind</button>
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
    target_type: new FormControl<PlanLinkTargetType>('ou', { nonNullable: true }),
    agent_id: new FormControl<string | null>(null),
    host_group_id: new FormControl<string | null>(null),
    enforced: new FormControl(false, { nonNullable: true }),
    auto_apply: new FormControl(false, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: OuLinkPlanDialogData) {}

  ngOnInit(): void {
    this.orchestration.listPlans().subscribe((p) => this.plans.set(p));
  }

  private targetValid(): boolean {
    const t = this.form.controls.target_type.value;
    if (t === 'host') return !!this.form.controls.agent_id.value;
    if (t === 'group') return !!this.form.controls.host_group_id.value;
    return true; // ou
  }

  /** Called from the template on each CD cycle (forms aren't signals). */
  canSave(): boolean {
    return this.plans().length > 0 && !!this.form.controls.plan_id.value && this.targetValid();
  }

  save(): void {
    if (!this.form.controls.plan_id.value || !this.targetValid()) return;
    const v = this.form.getRawValue();
    this.dialogRef.close({
      plan_id: v.plan_id,
      target_type: v.target_type,
      ou_id: v.target_type === 'ou' ? this.data.ouId : null,
      agent_id: v.target_type === 'host' ? v.agent_id : null,
      host_group_id: v.target_type === 'group' ? v.host_group_id : null,
      enforced: v.enforced,
      auto_apply: v.auto_apply,
    });
  }
}
