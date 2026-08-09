import { Component, Inject, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatDialogModule, MatDialogRef, MAT_DIALOG_DATA } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { Agent } from '../../../core/models/agent.model';
import { HostGroup } from '../../../core/models/host-group.model';

export interface HostGroupMembersDialogData {
  group: HostGroup;
  agents: Agent[];
}

/** Two-column membership editor for a host group: AVAILABLE hosts on the left,
 * MEMBERS on the right — a host is in exactly one column. Click a host (or its
 * ›/‹ button) to move it across. Replace-all semantics on save
 * (PUT /host-groups/{id}/members). */
@Component({
  selector: 'app-host-group-members-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Members of {{ data.group.name }}</h2>
    <mat-dialog-content>
      @if (data.agents.length) {
        <div class="bm-xfer">
          <div class="bm-col">
            <div class="bm-col-hd">Available <span class="bm-cnt">{{ available().length }}</span></div>
            <input class="bm-search" type="search" placeholder="filter…" [ngModel]="qAvail()" (ngModelChange)="qAvail.set($event)" />
            <div class="bm-list">
              @for (a of available(); track a.id) {
                <button class="bm-item" (click)="add(a.id)" [title]="'Add ' + a.name">
                  <span class="bm-item-name">{{ a.name }}</span><mat-icon>chevron_right</mat-icon>
                </button>
              } @empty { <p class="bm-none">— none —</p> }
            </div>
          </div>
          <div class="bm-mid">
            <button mat-stroked-button (click)="addAll()" [disabled]="!available().length" title="Add all shown">»</button>
            <button mat-stroked-button (click)="removeAll()" [disabled]="!members().length" title="Remove all">«</button>
          </div>
          <div class="bm-col">
            <div class="bm-col-hd">In group <span class="bm-cnt">{{ members().length }}</span></div>
            <input class="bm-search" type="search" placeholder="filter…" [ngModel]="qMemb()" (ngModelChange)="qMemb.set($event)" />
            <div class="bm-list">
              @for (a of members(); track a.id) {
                <button class="bm-item bm-in" (click)="remove(a.id)" [title]="'Remove ' + a.name">
                  <mat-icon>chevron_left</mat-icon><span class="bm-item-name">{{ a.name }}</span>
                </button>
              } @empty { <p class="bm-none">— empty —</p> }
            </div>
          </div>
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
  styles: [`
    .bm-xfer { display: flex; gap: 12px; align-items: stretch; min-width: 560px; }
    .bm-col { flex: 1; display: flex; flex-direction: column; min-width: 0; }
    .bm-col-hd { font-weight: 600; font-size: 13px; margin-bottom: 6px; display: flex; align-items: center; gap: 6px; }
    .bm-cnt { font-size: 11px; opacity: 0.6; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 0 6px; }
    .bm-search { padding: 5px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: transparent; color: inherit; margin-bottom: 6px; }
    .bm-list { flex: 1; min-height: 240px; max-height: 320px; overflow: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; }
    .bm-item { display: flex; align-items: center; gap: 4px; width: 100%; text-align: left; border: 0; background: transparent; color: inherit; padding: 5px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; }
    .bm-item:hover { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-item-name { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-item mat-icon { font-size: 18px; height: 18px; width: 18px; opacity: 0.6; }
    .bm-mid { display: flex; flex-direction: column; justify-content: center; gap: 8px; }
    .bm-none { opacity: 0.5; font-size: 12px; text-align: center; padding: 8px; }
    .bm-empty { opacity: 0.75; }
  `],
})
export class HostGroupMembersDialogComponent {
  dialogRef = inject(MatDialogRef<HostGroupMembersDialogComponent, string[]>);
  selected = signal<Set<string>>(new Set());
  qAvail = signal('');
  qMemb = signal('');

  constructor(@Inject(MAT_DIALOG_DATA) public data: HostGroupMembersDialogData) {
    this.selected.set(new Set(data.group.member_agent_ids));
  }

  private match(a: Agent, q: string): boolean { return !q || a.name.toLowerCase().includes(q.trim().toLowerCase()); }
  available = computed(() => this.data.agents.filter((a) => !this.selected().has(a.id) && this.match(a, this.qAvail())).sort((x, y) => x.name.localeCompare(y.name)));
  members = computed(() => this.data.agents.filter((a) => this.selected().has(a.id) && this.match(a, this.qMemb())).sort((x, y) => x.name.localeCompare(y.name)));

  add(id: string): void { this.selected.update((s) => new Set(s).add(id)); }
  remove(id: string): void { this.selected.update((s) => { const n = new Set(s); n.delete(id); return n; }); }
  addAll(): void { this.selected.update((s) => { const n = new Set(s); for (const a of this.available()) n.add(a.id); return n; }); }
  removeAll(): void { this.selected.update((s) => { const n = new Set(s); for (const a of this.members()) n.delete(a.id); return n; }); }

  save(): void { this.dialogRef.close([...this.selected()]); }
}
