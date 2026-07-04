import { Component, input, output } from '@angular/core';
import { MatChipsModule, MatChipListboxChange } from '@angular/material/chips';

@Component({
  selector: 'app-status-filter-chips',
  standalone: true,
  imports: [MatChipsModule],
  template: `
    <mat-chip-listbox [value]="selected()" (change)="onChange($event)">
      @for (s of statuses; track s) {
        <mat-chip-option [value]="s">{{ s }}</mat-chip-option>
      }
    </mat-chip-listbox>
  `,
})
export class StatusFilterChipsComponent {
  selected = input<string | null>(null);
  statusChange = output<string | null>();
  statuses = ['running', 'succeeded', 'failed', 'aborted'];

  onChange(event: MatChipListboxChange): void {
    this.statusChange.emit(event.value ?? null);
  }
}
