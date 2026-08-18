import { Component, inject, input, output, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatCardModule } from '@angular/material/card';
import { ConfigResource, DirectiveSpec } from '../../../core/models/agent.model';
import { AgentService } from '../../../core/services/agent.service';
import { HostConfigScopeService } from '../host-config-scope.service';

/** One setting of one config file, as a policy: Host based / Configured / Removed.
 *
 * This is the Group Policy Editor's tri-state, and the three states are the point — they are not a
 * value plus two special cases:
 *
 *   Host based  no policy at all. The file keeps whatever it has; we stop asserting anything.
 *   Configured  the policy says "this key has this value".
 *   Removed     the policy says "this key must be ABSENT" — which is different from unmanaged, and the
 *               difference is exactly what a config that must not contain a directive needs.
 *
 * Writing goes through the codec, so only this key is touched and foreign keys in the file survive. That
 * is why the per-setting editor is the safe one and the template editor (whole file) is not.
 *
 * Sixth slice out of host-detail.component.ts, and the first piece of the settings editor proper. Taken
 * separately from the Miller columns because it has a real boundary: it needs one resource, one row, one
 * spec, and nothing else from the page.
 *
 * THE ROW IS AN INPUT, WHICH REMOVED A DEPENDENCY. The old valueOptions() called settingRows(r) — a
 * drift-derived computation over the whole file — only to find the row it was already editing, so
 * extracting it would have dragged settingRows and the drift state along. The opened row already carries
 * `desired` and `live`, which is all the value-family heuristic reads.
 */
@Component({
  selector: 'app-host-setting-dialog',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatCardModule],
  template: `
    <mat-card class="bm-setting-dlg">
      <strong>{{ row().key }}</strong>
      @if (spec(); as ds) {
        @if (ds.description) {
          <p class="bm-dim bm-directive-desc">{{ ds.description }}@if (ds.default) { <span> · default: <code>{{ ds.default }}</code></span> }</p>
        }
      }
      <label class="bm-radio"><input type="radio" name="setmode" [checked]="mode() === 'notconf'"
        (change)="mode.set('notconf')" /> Host based — no policy; the file keeps its own value</label>
      <label class="bm-radio"><input type="radio" name="setmode" [checked]="mode() === 'configured'"
        (change)="mode.set('configured')" /> Configured</label>
      @if (mode() === 'configured') {
        @if (valueOptions(); as opts) {
          <select class="bm-kvin bm-setting-val" [ngModel]="value()" (ngModelChange)="value.set($event)">
            @for (o of opts; track o) { <option [value]="o">{{ o }}</option> }
          </select>
        } @else {
          <input class="bm-kvin bm-setting-val" [value]="value()" (input)="value.set($any($event.target).value)" />
        }
      }
      <label class="bm-radio"><input type="radio" name="setmode" [checked]="mode() === 'removed'"
        (change)="mode.set('removed')" /> Removed — enforce the key's absence in the file</label>
      <label class="bm-scope">Scope:
        <select [value]="scope.applyScope()" (change)="scope.applyScope.set($any($event.target).value)">
          <option value="host">this host</option>
          @if (ouId()) { <option value="ou">OU (every host under it)</option> }
          @for (g of scope.hostGroups(); track g.id) { <option [value]="'group:' + g.id">group {{ g.name }}</option> }
        </select>
      </label>
      @if (service(); as svc) {
        <label class="bm-scope bm-restart-svc">
          <input type="checkbox" [checked]="restartAfterApply()" (change)="restartAfterApply.set($any($event.target).checked)" />
          Restart <span class="bm-mono">{{ svc }}</span> after applying, so the change takes effect
        </label>
      }
      @if (error(); as e) { <p class="bm-cfg-err">{{ e }}</p> }
      <div class="bm-rollback-actions">
        <button mat-button (click)="closed.emit()" [disabled]="busy()">Cancel</button>
        <button mat-flat-button color="primary" (click)="apply()" [disabled]="busy()">
          {{ (service() && restartAfterApply() && mode() !== 'notconf') ? ('Apply & restart ' + service()) : 'Apply' }}
        </button>
      </div>
    </mat-card>
  `,
  styles: [`
    .bm-setting-dlg { margin-top: 12px; padding: 12px 14px; display: flex; flex-direction: column; gap: 6px; }
    .bm-radio { display: flex; align-items: center; gap: 8px; font-size: 13px; }
    .bm-setting-val { max-width: 380px; }
    .bm-directive-desc { margin: 2px 0 6px; }
    .bm-scope { display: inline-flex; align-items: center; gap: 8px; font-size: 12.5px; }
    .bm-restart-svc { margin-top: 2px; }
    .bm-mono { font-family: var(--bm-mono, monospace); }
    .bm-rollback-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 10px; }
    .bm-dim { opacity: 0.62; font-size: 12.5px; }
    .bm-cfg-err { font-size: 13px; color: var(--bm-red, #d0021b); }
  `],
})
export class HostSettingDialogComponent {
  private agentService = inject(AgentService);
  readonly scope = inject(HostConfigScopeService);

  agentId = input.required<string>();
  /** The file this setting belongs to. `format`/`separator` decide how the codec writes it, and whether
   * a dotted key means a nested structure (see the unflatten call in apply()). */
  resource = input.required<{ path: string; format: string; separator?: string }>();
  /** The row that was clicked: key plus its current desired/live values and state. */
  row = input.required<{ key: string; state: string; desired: string; live: string }>();
  /** The mined ADMX-style spec for this key, or null when the catalog does not know it. */
  spec = input<DirectiveSpec | null>(null);
  /** The systemd unit that owns this file, so Apply can also restart it. Null when none claims it. */
  service = input<string | null>(null);
  ouId = input<string | null | undefined>(null);

  closed = output<void>();
  /** The host was written — the page's observed state is stale. */
  applied = output<void>();

  mode = signal<'notconf' | 'configured' | 'removed'>('configured');
  value = signal('');
  busy = signal(false);
  error = signal<string | null>(null);
  restartAfterApply = signal(true);

  /** Seed from the row ONCE, in ngOnInit — inputs are bound by then, and this deliberately is NOT an
   * effect. The parent creates one dialog per clicked row and destroys it on close, so the row does not
   * change under a live instance; an effect would re-seed whenever the parent recomputed its rows (the
   * observed state reloads) and throw away whatever the user had typed. */
  ngOnInit(): void {
    const cur = this.row();
    this.mode.set(cur.state === 'Removed' ? 'removed' : cur.state === 'Configured' ? 'configured' : 'notconf');
    this.value.set(cur.desired || cur.live || '');
  }

  /** Values offered as a listbox, or null for free text.
   *
   * Prefers the mined catalog, so PermitRootLogin offers all four real values rather than the yes/no
   * pair guessed from whatever the file happens to say today. Falls back to a value-family heuristic,
   * and to free text when neither applies. The current value is prepended when it is not among the
   * offered ones — dropping it would silently rewrite a setting the moment someone opened the dialog. */
  valueOptions(): string[] | null {
    const spec = this.spec();
    if (spec) {
      if (spec.type === 'enum' && spec.values?.length) {
        const val = this.value();
        return spec.values.includes(val) || !val ? spec.values : [val, ...spec.values];
      }
      if (spec.type === 'bool') return ['yes', 'no'];
      if (spec.type === 'int' || spec.type === 'string' || spec.type === 'list') return null;
    }
    const cur = (this.row().desired || this.row().live || '').trim().toLowerCase();
    const families = [['yes', 'no'], ['true', 'false'], ['on', 'off'], ['enabled', 'disabled']];
    const fam = families.find((f) => f.includes(cur));
    if (!fam) return null;
    const val = this.value();
    return fam.includes(val) ? fam : [val, ...fam].filter((v, i, a) => v !== '' && a.indexOf(v) === i);
  }

  /** A dotted key means a nested structure for every format EXCEPT keyvalue, where a dot is just part of
   * the key (log.level in a keyvalue file is one key, in YAML it is two levels). */
  private unflatten(key: string, value: unknown, deep: boolean): Record<string, unknown> {
    if (!deep || !key.includes('.')) return { [key]: value };
    const parts = key.split('.');
    const root: Record<string, unknown> = {};
    let node = root;
    for (const p of parts.slice(0, -1)) {
      const n: Record<string, unknown> = {};
      node[p] = n;
      node = n;
    }
    node[parts[parts.length - 1]] = value;
    return root;
  }

  apply(): void {
    const r = this.resource();
    const key = this.row().key;
    const mode = this.mode();
    this.busy.set(true);
    this.error.set(null);

    const svc = this.service();
    const restart = !!svc && this.restartAfterApply() && mode !== 'notconf';
    const finish = () => {
      this.busy.set(false);
      this.applied.emit();
      this.closed.emit();
    };
    const done = () => {
      // Restart AFTER the config landed, and best-effort: a failed restart is reported while the config
      // change itself stays — reporting it as one failure would say the write did not happen.
      if (!restart) return finish();
      this.agentService.serviceControl(this.agentId(), svc!, 'restart').subscribe({
        next: finish,
        error: (e: { error?: { detail?: string } }) => {
          this.error.set(`Config applied, but restarting ${svc} failed: ${e?.error?.detail ?? 'error'}`);
          this.busy.set(false);
          this.applied.emit();   // the file DID change; the page must re-read it
        },
      });
    };
    const fail = (e: { error?: { detail?: string } }) => {
      this.error.set(e?.error?.detail ?? 'failed');
      this.busy.set(false);
    };

    if (mode === 'notconf') {
      // Stop managing this key at the chosen scope. The live file is left exactly as it is: "no policy"
      // is not "revert", and pretending otherwise would make un-managing a destructive act.
      const s = this.scope.scopeArg(this.ouId());
      this.agentService
        .unsetDesired(this.agentId(), { path: r.path, key, ou_id: s?.ouId, host_group_id: s?.groupId })
        .subscribe({ next: done, error: fail });
      return;
    }

    const value = mode === 'removed' ? null : this.value();   // null = enforce absence
    const resource: ConfigResource = {
      type: 'config', path: r.path, format: r.format, separator: r.separator,
      values: this.unflatten(key, value, r.format !== 'keyvalue'),
    };
    this.agentService.stateApply(this.agentId(), [resource], false, this.scope.scopeArg(this.ouId()))
      .subscribe({ next: done, error: fail });
  }
}
