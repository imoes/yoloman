import { Component, Inject, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { MatButtonModule } from '@angular/material/button';
import { Agent } from '../../../core/models/agent.model';
import { HostGroup } from '../../../core/models/host-group.model';
import { OUNode } from '../../../core/models/ou.model';
import { OrchestrationPlanLinkInput, PlanLinkPreview, PlanLinkTargetType } from '../../../core/models/orchestration.model';
import { OrchestrationService } from '../../../core/services/orchestration.service';

export interface PlanLinkDialogData {
  planId: string;
  planName: string;
  nodes: OUNode[];
  agents: Agent[];
  groups: HostGroup[];
}

/** Link a plan to a scope (Block L1/L2) — "activate immediately" is a
 * deliberate, human-driven auto_apply=true: the one legitimate way to
 * bypass the approval gate, since only this dialog (never MCP) can set it.
 * Left unchecked, the link starts pending_approval unless the global
 * YOLO-MAN switch is already on. */
@Component({
  selector: 'app-plan-link-dialog',
  standalone: true,
  imports: [ReactiveFormsModule, MatDialogModule, MatFormFieldModule, MatInputModule, MatSelectModule, MatSlideToggleModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Link "{{ data.planName }}" to a scope</h2>
    <mat-dialog-content [formGroup]="form">
      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Target type</mat-label>
        <mat-select formControlName="target_type">
          <mat-option value="global">Global (every host)</mat-option>
          <mat-option value="ou">OU (subtree)</mat-option>
          <mat-option value="group">Host group</mat-option>
          <mat-option value="host">Single host</mat-option>
        </mat-select>
      </mat-form-field>

      @if (form.value.target_type === 'ou') {
        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>OU</mat-label>
          <mat-select formControlName="ou_id">
            @for (n of data.nodes; track n.id) {
              <mat-option [value]="n.id">{{ n.path }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
      }
      @if (form.value.target_type === 'group') {
        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>Host group</mat-label>
          <mat-select formControlName="host_group_id">
            @for (g of data.groups; track g.id) {
              <mat-option [value]="g.id">{{ g.name }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
      }
      @if (form.value.target_type === 'host') {
        <mat-form-field appearance="outline" class="bm-full-width">
          <mat-label>Host</mat-label>
          <mat-select formControlName="agent_id">
            @for (a of data.agents; track a.id) {
              <mat-option [value]="a.id">{{ a.name }}</mat-option>
            }
          </mat-select>
        </mat-form-field>
      }

      <mat-form-field appearance="outline" class="bm-full-width">
        <mat-label>Priority (higher wins on conflict)</mat-label>
        <input matInput type="number" formControlName="priority" />
      </mat-form-field>

      <mat-slide-toggle formControlName="activate_immediately">
        Activate immediately (skip approval)
      </mat-slide-toggle>

      <div class="bm-preview-row">
        <button mat-button [disabled]="!canPreview() || previewing()" (click)="preview()">Preview impact</button>
        @if (previewResult(); as p) {
          <div class="bm-preview-result">
            <p>{{ p.affected_host_count }} host(s) affected.</p>
            @if (p.sample_diff) {
              <p class="bm-empty">
                Sample ({{ p.sample_diff.host }}): +checks {{ p.sample_diff.checks_added.join(', ') || 'none' }}, +roles
                {{ p.sample_diff.roles_added.join(', ') || 'none' }}
              </p>
            }
          </div>
        }
      </div>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" [disabled]="form.invalid" (click)="save()">Create link</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-full-width {
        width: 100%;
      }
      .bm-preview-row {
        margin-top: 8px;
      }
      .bm-preview-result {
        margin-top: 8px;
        padding: 8px 10px;
        border-radius: 6px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent);
      }
      .bm-empty {
        opacity: 0.75;
        font-size: 12.5px;
      }
    `,
  ],
})
export class PlanLinkDialogComponent {
  dialogRef = inject(MatDialogRef<PlanLinkDialogComponent, OrchestrationPlanLinkInput>);
  private orchestrationService = inject(OrchestrationService);

  previewing = signal(false);
  previewResult = signal<PlanLinkPreview | null>(null);

  form = new FormGroup({
    target_type: new FormControl<PlanLinkTargetType>('host', { nonNullable: true, validators: [Validators.required] }),
    ou_id: new FormControl<string | null>(null),
    host_group_id: new FormControl<string | null>(null),
    agent_id: new FormControl<string | null>(null),
    priority: new FormControl(100, { nonNullable: true }),
    activate_immediately: new FormControl(false, { nonNullable: true }),
  });

  constructor(@Inject(MAT_DIALOG_DATA) public data: PlanLinkDialogData) {
    this.form.valueChanges.subscribe(() => this.previewResult.set(null));
  }

  canPreview(): boolean {
    const v = this.form.value;
    if (v.target_type === 'global') return true;
    if (v.target_type === 'ou') return !!v.ou_id;
    if (v.target_type === 'group') return !!v.host_group_id;
    if (v.target_type === 'host') return !!v.agent_id;
    return false;
  }

  preview(): void {
    const v = this.form.getRawValue();
    this.previewing.set(true);
    this.orchestrationService
      .previewLink(this.data.planId, {
        target_type: v.target_type,
        ou_id: v.ou_id,
        host_group_id: v.host_group_id,
        agent_id: v.agent_id,
      })
      .subscribe({
        next: (result) => {
          this.previewResult.set(result);
          this.previewing.set(false);
        },
        error: () => this.previewing.set(false),
      });
  }

  save(): void {
    const v = this.form.getRawValue();
    this.dialogRef.close({
      target_type: v.target_type,
      ou_id: v.target_type === 'ou' ? v.ou_id : null,
      host_group_id: v.target_type === 'group' ? v.host_group_id : null,
      agent_id: v.target_type === 'host' ? v.agent_id : null,
      priority: v.priority,
      auto_apply: v.activate_immediately,
      require_approval: !v.activate_immediately,
    });
  }
}
