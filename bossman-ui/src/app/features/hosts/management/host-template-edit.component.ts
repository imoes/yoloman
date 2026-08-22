import { Component, effect, inject, input, output, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { ConfigResource } from '../../../core/models/agent.model';
import { AgentService } from '../../../core/services/agent.service';
import { ParamFormComponent } from '../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../shared/param-form/param-form.types';
import { HostConfigScopeService } from '../host-config-scope.service';

/** Edit a config file through its template: fill the schema's values, the WHOLE file is rendered from
 * them.
 *
 * This is the strongest of the three editors and also the bluntest. A codec'd file is merged per key, so
 * foreign keys survive; this one replaces the file. That is why the path→template binding had to become
 * an explicit index first (see services/template_index.py): rendering the right values into the wrong
 * file is a total loss, and the old basename guess did exactly that for
 * /etc/aardvark-dns/aardvark-dns.conf.
 *
 * Fifth slice out of host-detail.component.ts. It fetches the ONE template it needs — the page used to
 * preload every template body, 33.7 MB across 5460 directories, to answer a string comparison.
 *
 * TWO DEAD ERROR PATHS WERE DROPPED, not carried over. previewTemplate and applyTemplate each wrapped
 * the values lookup in try/catch and reported "invalid JSON in a list/object field" — but the lookup is
 * a signal read that cannot throw, as its own docstring said ("ParamForm already parsed each field by
 * its schema type … no manual JSON parsing / no throw"). An error message for an impossible state is
 * worse than none: it survives review because it looks careful, and it describes a failure mode that no
 * longer exists.
 */
@Component({
  selector: 'app-host-template-edit',
  standalone: true,
  imports: [MatButtonModule, ParamFormComponent],
  template: `
    @if (loading()) {
      <p class="bm-empty">Loading template <strong>{{ templateName() }}</strong>…</p>
    } @else if (loadError(); as le) {
      <p class="bm-cfg-err">{{ le }}</p>
      <div class="bm-rollback-actions"><button mat-button (click)="cancelled.emit()">Close</button></div>
    } @else {
      <p class="bm-dim">Managed via template <strong>{{ templateName() }}</strong> — edit the values, the
        whole file is rendered from them.</p>
      @if (withheld(); as w) {
        <p class="bm-dim" [title]="w.fields.join(', ')">{{ w.count }} further field(s) declared by this
          template are not shown: {{ w.reason }}.</p>
      }
      @if (rendererGaps(); as g) {
        <p class="bm-cfg-err">This template calls {{ g.calls.join(', ') }} — the renderer does not implement
          {{ g.calls.length > 1 ? 'those' : 'that' }}, so a value reaching that line will make Apply fail.</p>
      }
      @if (unsettable(); as u) {
        <p class="bm-dim" [title]="u.variables.join(', ')">This template also reads {{ u.count }} value(s)
          no field offers ({{ u.variables.slice(0, 3).join(', ') }}@if (u.count > 3) {, …}) — they will
          render empty.</p>
      }
      <app-param-form [params]="schema()" [initial]="initial()" [agentId]="agentId()"
                      (valuesChange)="values.set($event)" />
      @if (error(); as e) { <p class="bm-cfg-err">{{ e }}</p> }
      @if (rendered(); as text) {
        <p class="bm-dim">Rendered file (would be written):</p>
        <pre class="bm-cfg-values">{{ text }}</pre>
      }
      <label class="bm-scope">Apply to:
        <select [value]="scope.applyScope()" (change)="scope.applyScope.set($any($event.target).value)">
          <option value="host">this host</option>
          @if (ouId()) { <option value="ou">OU (every host under it)</option> }
          @for (g of scope.hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
        </select>
      </label>
      <div class="bm-rollback-actions">
        <button mat-button (click)="cancelled.emit()" [disabled]="busy()">Cancel</button>
        <button mat-button (click)="preview()" [disabled]="busy()">Preview (render)</button>
        <button mat-flat-button color="primary" (click)="apply()" [disabled]="busy()">
          {{ scope.applyScope() === 'host' ? 'Apply' : 'Apply to scope' }}
        </button>
      </div>
    }
  `,
  styles: [`
    .bm-cfg-values { max-height: 420px; overflow: auto; font-size: 12.5px;
      background: color-mix(in srgb, var(--mat-sys-surface-variant) 40%, transparent);
      padding: 10px 12px; border-radius: 6px; }
    .bm-scope { display: inline-flex; align-items: center; gap: 8px; font-size: 12.5px; margin-top: 10px; }
    .bm-rollback-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; }
    .bm-dim { opacity: 0.62; font-size: 12.5px; }
    .bm-empty { opacity: 0.6; font-size: 13px; }
    .bm-cfg-err { font-size: 13px; color: var(--bm-red, #d0021b); }
  `],
})
export class HostTemplateEditComponent {
  private agentService = inject(AgentService);
  /** Page-scoped, provided by the host component — "where does this write go" is one answer the whole
   * screen shares, and it must never be carried from one host page to another. */
  readonly scope = inject(HostConfigScopeService);

  agentId = input.required<string>();
  path = input.required<string>();
  /** The template directory name, as resolved by the path→template index. */
  templateName = input.required<string>();
  /** The host's OU, or absent. Typed to match Agent.ou_id (`string | null | undefined`) instead of
   * making the caller cast: three ways to say "no OU" is two too many, and a cast at the binding site is
   * where a real null would slip through unnoticed. Only decides whether the OU scope is OFFERED; the
   * write resolves through the scope service, so the two cannot disagree. */
  ouId = input<string | null | undefined>(null);

  cancelled = output<void>();
  /** The file was written — the page's observed state is stale. */
  applied = output<void>();

  schema = signal<ParamSchema>({});
  /** Fields the template declares but never places. Shown as a count with the names on hover: a form that
   * silently drops an input is the "nothing vanishes" rule broken in the most literal way. */
  withheld = signal<{ count: number; fields: string[]; reason: string } | null>(null);
  /** Values the template reads that this form cannot supply — they render empty. The operator should know
   * BEFORE pressing Apply that the rendered file will be missing them. */
  unsettable = signal<{ count: number; variables: string[]; reason: string } | null>(null);
  /** Calls the renderer cannot execute. Shown because the failure is LATENT: the sample renders, and a
   * value that reaches that line makes Apply fail — better said before than discovered after. */
  rendererGaps = signal<{ calls: string[]; reason: string } | null>(null);
  initial = signal<Record<string, unknown>>({});
  values = signal<Record<string, unknown>>({});
  rendered = signal<string | null>(null);
  loading = signal(true);
  loadError = signal<string | null>(null);
  busy = signal(false);
  error = signal<string | null>(null);
  private body = '';

  constructor() {
    // In an effect, not the constructor: a required input is not bound yet there (NG0950, caught in the
    // browser on an earlier slice). Reading templateName() also means re-fetching if the pane is ever
    // pointed at a different template without being destroyed.
    effect(() => {
      this.templateName();
      this.load();
    });
    this.scope.loadGroups();
  }

  private load(): void {
    this.loading.set(true);
    this.loadError.set(null);
    this.rendered.set(null);
    // THROUGH describe(), not the raw template catalog. This used to call GET /config-templates/<name> and
    // hand ParamForm the schema verbatim — which offers every declared field, including the ones the
    // template never places. Measured across the library: 2561 of 54026 offered fields in 341 templates
    // appear NOWHERE in their own body (acme.sh offers 69 and places 5), so an operator filled them in and
    // the whole-file render dropped them without a word. /config-fields withholds those and says how many.
    this.agentService.configFields(this.path(), this.agentId()).subscribe({
      next: (spec) => {
        this.body = spec.template ?? '';
        this.schema.set((spec.fields || {}) as ParamSchema);
        this.initial.set((spec.sample || {}) as Record<string, unknown>);
        this.withheld.set(spec.withheld ?? null);
        this.unsettable.set(spec.unsettable ?? null);
        this.rendererGaps.set(spec.renderer_gaps ?? null);
        this.values.set({});
        this.loading.set(false);
      },
      error: (e: { error?: { detail?: string } }) => {
        // NAMED, and no form. A template the server cannot serve must not present an editor whose Apply
        // would render an empty file over the live one.
        this.loadError.set(e?.error?.detail ?? `could not load template ${this.templateName()}`);
        this.loading.set(false);
      },
    });
  }

  private resource(): ConfigResource {
    return { type: 'template_render', path: this.path(), template: this.body, values: this.values() };
  }

  /** Render with the current values and show the result. Writes nothing — and it is offered before Apply
   * precisely because Apply replaces the whole file. */
  preview(): void {
    this.busy.set(true);
    this.error.set(null);
    this.agentService.renderTemplate(this.agentId(), this.body, this.values(), this.path()).subscribe({
      next: (res) => {
        this.busy.set(false);
        this.rendered.set(res.result?.data?.rendered ?? '(empty render)');
      },
      error: (e: { error?: { detail?: string } }) => {
        this.error.set(e?.error?.detail ?? 'render failed');
        this.busy.set(false);
      },
    });
  }

  /** Write it: renders through the document loop and records a generation, at the chosen scope. */
  apply(): void {
    this.busy.set(true);
    this.error.set(null);
    this.agentService
      .stateApply(this.agentId(), [this.resource()], false, this.scope.scopeArg(this.ouId()))
      .subscribe({
        next: () => {
          this.busy.set(false);
          this.applied.emit();
          this.cancelled.emit();   // the pane closes; the page reloads what is now on disk
        },
        error: (e: { error?: { detail?: string } }) => {
          this.error.set(e?.error?.detail ?? 'apply failed');
          this.busy.set(false);
        },
      });
  }
}
