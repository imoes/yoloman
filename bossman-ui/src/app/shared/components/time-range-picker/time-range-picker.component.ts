import { Component, input, output } from '@angular/core';
import { MatButtonToggleModule, MatButtonToggleChange } from '@angular/material/button-toggle';

const RANGE_MS: Record<string, number> = {
  '1h': 3_600_000,
  '6h': 21_600_000,
  '24h': 86_400_000,
  '7d': 604_800_000,
};

@Component({
  selector: 'app-time-range-picker',
  standalone: true,
  imports: [MatButtonToggleModule],
  template: `
    <mat-button-toggle-group [value]="selectedRange()" (change)="onChange($event)">
      @for (r of ranges; track r) {
        <mat-button-toggle [value]="r">{{ r }}</mat-button-toggle>
      }
    </mat-button-toggle-group>
  `,
})
export class TimeRangePickerComponent {
  selectedRange = input<string>('1h');
  /** Emits the ISO "since" timestamp for the newly selected range. */
  rangeChange = output<string>();

  ranges = Object.keys(RANGE_MS);

  onChange(event: MatButtonToggleChange): void {
    const ms = RANGE_MS[event.value] ?? RANGE_MS['1h'];
    this.rangeChange.emit(new Date(Date.now() - ms).toISOString());
  }
}
