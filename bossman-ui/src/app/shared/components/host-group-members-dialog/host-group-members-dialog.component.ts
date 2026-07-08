import { Component, Inject, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatDialogModule, MatDialogRef, MAT_DIALOG_DATA } from '@angular/material/dialog';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatButtonModule } from '@angular/material/button';
import { Agent } from '../../../core/models/agent.model';
import { HostGroup } from '../../../core/models/host-group.model';

export interface HostGroupMembersDialogData {
  group: HostGroup;
  agents: Agent[];
}

/** Replace-all membership editor for a host group (Block L1) — mirrors the
 * REST endpoint's own replace-not-diff semantics
 * (PUT /host-groups/{id}/members). */
@Component({
  selector: 'app-host-group-members-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatCheckboxModule, MatButtonModule],
  template: `
    <h2 mat-dialog-title>Members of {{ data.group.name }}</h2>
    <mat-dialog-content>
      @if (data.agents.length) {
        <div class="bm-member-list">
          @for (agent of data.agents; track agent.id) {
            <mat-checkbox [checked]="selected().has(agent.id)" (change)="toggle(agent.id)">{{ agent.name }}</mat-checkbox>
          }
        </div>
      } @else {
        <p class="bm-empty">No hosts enrolled yet.</p>
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button (click)="dialogRef.close()">Cancel</button>
      <button mat-raised-button color="primary" (click)="save()">Save</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      .bm-member-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
        min-width: 280px;
      }
      .bm-empty {
        opacity: 0.75;
      }
    `,
  ],
})
export class HostGroupMembersDialogComponent {
  dialogRef = inject(MatDialogRef<HostGroupMembersDialogComponent, string[]>);
  selected = signal<Set<string>>(new Set());

  constructor(@Inject(MAT_DIALOG_DATA) public data: HostGroupMembersDialogData) {
    this.selected.set(new Set(data.group.member_agent_ids));
  }

  toggle(agentId: string): void {
    this.selected.update((current) => {
      const next = new Set(current);
      if (next.has(agentId)) next.delete(agentId);
      else next.add(agentId);
      return next;
    });
  }

  save(): void {
    this.dialogRef.close([...this.selected()]);
  }
}
