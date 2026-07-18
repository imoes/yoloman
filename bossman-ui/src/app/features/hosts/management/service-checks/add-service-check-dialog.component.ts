import { Component, Inject, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { CheckService } from '../../../../core/services/check.service';
import { CheckCatalogEntry, CheckOption } from '../../../../core/models/check.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema, ParamSpec } from '../../../../shared/param-form/param-form.types';

export interface AddServiceCheckData { agentId: string; hostName: string; }

/** Configure & assign an active service check to a host — the same
 * catalog→form→assign flow as the Roles & Features wizard, reusing app-param-form
 * over the check's typed `options`. */
@Component({
  selector: 'app-add-service-check-dialog',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule, ParamFormComponent],
  template: `
    <h2 mat-dialog-title>Add a service check <span class="bm-dim">on {{ data.hostName }}</span></h2>
    <mat-dialog-content class="bm-sc-body">
      @if (!picked()) {
        <input class="bm-sc-search" placeholder="Search service checks…" [ngModel]="query()" (ngModelChange)="query.set($event)" />
        <div class="bm-sc-list">
          @for (c of hits(); track c.name) {
            <button type="button" class="bm-sc-item" (click)="pick(c)">
              <div class="bm-sc-label">{{ label(c) }} <span class="bm-sc-key">· {{ c.name }}</span></div>
              @if (c.summary) { <div class="bm-sc-desc">{{ c.summary }}</div> }
            </button>
          } @empty {
            <p class="bm-dim">No service checks yet — they are being translated in the background.</p>
          }
        </div>
      } @else {
        <div class="bm-sc-cfg-head">
          <button type="button" class="bm-sc-back" (click)="picked.set(null)"><mat-icon>arrow_back</mat-icon></button>
          <div>
            <div class="bm-sc-label">{{ label(picked()!) }}</div>
            @if (picked()!.summary) { <div class="bm-sc-desc">{{ picked()!.summary }}</div> }
          </div>
        </div>
        <app-param-form [params]="schema()" [initial]="initial()" (valuesChange)="values.set($event)" />
      }
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      <button mat-button mat-dialog-close>Cancel</button>
      @if (picked()) {
        <button mat-flat-button color="primary" [disabled]="!canSave() || saving()" (click)="save()">
          <mat-icon>add_task</mat-icon> {{ saving() ? 'Assigning…' : 'Add check' }}
        </button>
      }
    </mat-dialog-actions>
  `,
  styles: [`
    .bm-dim { opacity: 0.6; font-weight: 400; }
    .bm-sc-body { min-width: 560px; max-width: 720px; }
    .bm-sc-search { width: 100%; box-sizing: border-box; padding: 8px 11px; margin-bottom: 10px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-sc-list { max-height: 46vh; overflow-y: auto; display: flex; flex-direction: column; gap: 2px; }
    .bm-sc-item { text-align: left; background: none; border: none; border-radius: 6px; padding: 8px 10px; cursor: pointer; color: inherit; }
    .bm-sc-item:hover { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
    .bm-sc-label { font-size: 13.5px; font-weight: 600; }
    .bm-sc-key { opacity: 0.5; font-weight: 400; font-size: 12px; }
    .bm-sc-desc { font-size: 11.5px; opacity: 0.6; margin-top: 2px; line-height: 1.35; }
    .bm-sc-cfg-head { display: flex; align-items: flex-start; gap: 8px; margin-bottom: 12px; }
    .bm-sc-back { background: none; border: none; color: inherit; cursor: pointer; opacity: 0.7; padding: 2px; }
  `],
})
export class AddServiceCheckDialogComponent {
  private checkService = inject(CheckService);
  private ref = inject(MatDialogRef<AddServiceCheckDialogComponent>);

  private catalog = signal<CheckCatalogEntry[]>([]);
  query = signal('');
  picked = signal<CheckCatalogEntry | null>(null);
  values = signal<Record<string, unknown>>({});
  saving = signal(false);

  hits = computed(() => {
    const q = this.query().trim().toLowerCase();
    return this.catalog()
      .filter((c) => !q || c.name.toLowerCase().includes(q) || this.label(c).toLowerCase().includes(q) || (c.summary || '').toLowerCase().includes(q))
      .slice(0, 80);
  });

  // The check's options → the param-form schema (choices→enum, type normalised).
  schema = computed<ParamSchema>(() => {
    const opts = this.picked()?.options ?? {};
    const out: ParamSchema = {};
    for (const [key, o] of Object.entries(opts as Record<string, CheckOption>)) {
      out[key] = this.toSpec(o);
    }
    return out;
  });
  initial = computed<Record<string, unknown>>(() => ({ service_name: this.picked() ? this.label(this.picked()!) : '' }));

  constructor(@Inject(MAT_DIALOG_DATA) public data: AddServiceCheckData) {
    this.checkService.listChecks().subscribe((r) => {
      this.catalog.set((r.checks || []).filter((c) => c.category === 'Service checks').sort((a, b) => this.label(a).localeCompare(this.label(b))));
    });
  }

  private toSpec(o: CheckOption): ParamSpec {
    const t = (o.type || 'string') as string;
    const type = (t === 'boolean' ? 'bool' : t) as ParamSpec['type'];
    const choices = (o as CheckOption & { enum?: unknown[] }).enum ?? o.choices;
    return {
      type: (['string', 'number', 'bool', 'list', 'object'].includes(type) ? type : 'string') as ParamSpec['type'],
      description: o.description,
      default: o.default,
      required: o.required,
      secret: (o as CheckOption & { secret?: boolean }).secret,
      enum: choices as unknown[] | undefined,
    };
  }

  label(c: CheckCatalogEntry): string {
    const d = (c.short_description || '').replace(/%s/g, '').replace(/\s+/g, ' ').trim();
    return d || c.name.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
  }

  pick(c: CheckCatalogEntry): void { this.picked.set(c); this.values.set({}); }

  canSave(): boolean {
    const sn = (this.values()['service_name'] ?? this.initial()['service_name']) as string;
    return !!this.picked() && !!(sn && String(sn).trim());
  }

  save(): void {
    const check = this.picked();
    if (!check || this.saving()) return;
    this.saving.set(true);
    const parameters = { ...this.initial(), ...this.values() };
    this.checkService.createAssignment({
      check_name: check.name, scope_type: 'host', agent_id: this.data.agentId, parameters, source: 'manual',
    }).subscribe({
      next: () => this.ref.close(true),
      error: () => this.saving.set(false),
    });
  }
}
