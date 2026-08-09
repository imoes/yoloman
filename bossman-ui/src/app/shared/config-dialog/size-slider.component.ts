import { Component, computed, effect, input, model, signal } from '@angular/core';
import { MatSliderModule } from '@angular/material/slider';
import { MatSelectModule } from '@angular/material/select';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { FormsModule } from '@angular/forms';

const UNITS: { title: string; factor: number }[] = [
  { title: 'KiB', factor: 1024 },
  { title: 'MiB', factor: 1024 * 1024 },
  { title: 'GiB', factor: 1024 * 1024 * 1024 },
  { title: 'TiB', factor: 1024 * 1024 * 1024 * 1024 },
];

/** Cockpit's SizeSlider (../cockpit/pkg/storaged/dialog.jsx:1042): a slider +
 * numeric input + unit select that stay in sync, snapping to `round` and
 * clamping to [min,max]. The bound value() is always bytes. Supports
 * allowInfinite (thin over-provisioning) via an "unlimited" checkbox. */
@Component({
  selector: 'app-size-slider',
  standalone: true,
  imports: [MatSliderModule, MatSelectModule, MatFormFieldModule, MatInputModule, MatCheckboxModule, FormsModule],
  template: `
    <div class="ss">
      <mat-slider class="ss-slider" [min]="min()" [max]="max()" [step]="step()" [disabled]="infinite()">
        <input matSliderThumb [value]="value()" (valueChange)="onSlider($event)" />
      </mat-slider>
      <mat-form-field appearance="outline" class="ss-num">
        <input matInput type="number" [ngModel]="numDisplay()" (ngModelChange)="onNum($event)" [disabled]="infinite()" />
      </mat-form-field>
      <mat-form-field appearance="outline" class="ss-unit">
        <mat-select [ngModel]="unitIdx()" (ngModelChange)="onUnit($event)" [disabled]="infinite()">
          @for (u of units; track u.title; let i = $index) {
            <mat-option [value]="i">{{ u.title }}</mat-option>
          }
        </mat-select>
      </mat-form-field>
      @if (allowInfinite()) {
        <mat-checkbox [ngModel]="infinite()" (ngModelChange)="onInfinite($event)">unlimited</mat-checkbox>
      }
    </div>
  `,
  styles: [
    `
      .ss { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
      .ss-slider { flex: 1; min-width: 160px; }
      .ss-num { width: 110px; }
      .ss-num .mat-mdc-form-field-subscript-wrapper, .ss-unit .mat-mdc-form-field-subscript-wrapper { display: none; }
      .ss-unit { width: 90px; }
    `,
  ],
})
export class SizeSliderComponent {
  /** Bytes. Bound both ways. A negative value means "infinite". */
  value = model<number>(0);
  min = input<number>(0);
  max = input<number>(0);
  /** Snap granularity in bytes (extent size / 1 MiB). Default 1 MiB. */
  round = input<number>(1024 * 1024);
  allowInfinite = input<boolean>(false);

  units = UNITS;
  unitIdx = signal(2); // default GiB
  infinite = signal(false);

  constructor() {
    // Pick a sensible default unit from the initial/max value once.
    effect(() => {
      const ref = this.value() || this.max();
      if (ref >= UNITS[2].factor) this.unitIdx.set(2);
      else if (ref >= UNITS[1].factor) this.unitIdx.set(1);
      else this.unitIdx.set(0);
    });
  }

  step = computed(() => Math.max(this.round(), 1));

  numDisplay = computed(() => {
    const f = this.units[this.unitIdx()].factor;
    return +(this.value() / f).toFixed(3);
  });

  private clampSnap(bytes: number): number {
    const r = this.round();
    let v = Math.round(bytes / r) * r;
    if (v < this.min()) v = this.min();
    if (this.max() && v > this.max()) v = this.max();
    return v;
  }

  onSlider(v: number): void {
    this.value.set(this.clampSnap(v));
  }

  onNum(v: number): void {
    if (v == null || isNaN(v)) return;
    this.value.set(this.clampSnap(v * this.units[this.unitIdx()].factor));
  }

  onUnit(i: number): void {
    this.unitIdx.set(i);
  }

  onInfinite(on: boolean): void {
    this.infinite.set(on);
    this.value.set(on ? -1 : this.clampSnap(this.max() || this.min()));
  }
}
