import { Component, input, output } from '@angular/core';
import { FormControl, ReactiveFormsModule } from '@angular/forms';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatSelectModule } from '@angular/material/select';
import { MatSelectChange } from '@angular/material/select';
import { Agent } from '../../../core/models/agent.model';

@Component({
  selector: 'app-host-picker',
  standalone: true,
  imports: [ReactiveFormsModule, MatFormFieldModule, MatSelectModule],
  template: `
    <mat-form-field appearance="outline" class="bm-host-picker">
      <mat-label>Host</mat-label>
      <mat-select [formControl]="control" (selectionChange)="onChange($event)">
        @for (agent of agents(); track agent.id) {
          <mat-option [value]="agent.name">{{ agent.name }}</mat-option>
        }
      </mat-select>
    </mat-form-field>
  `,
  styles: [
    `
      .bm-host-picker {
        width: 100%;
      }
    `,
  ],
})
export class HostPickerComponent {
  agents = input.required<Agent[]>();
  selected = output<string>();
  control = new FormControl<string | null>(null);

  onChange(event: MatSelectChange): void {
    this.selected.emit(event.value);
  }
}
