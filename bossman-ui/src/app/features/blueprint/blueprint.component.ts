import { Component, OnInit, computed, effect, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { RouterLink } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';
import { ParamSchema } from '../../shared/param-form/param-form.types';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { BlueprintCanvasComponent } from './blueprint-canvas.component';
import { BlueprintStore, BackendBlueprintRow } from './blueprint-store';
import { PALETTE, PaletteEntry, RoleContract, isValidEnvName, paletteFor } from './compose-model';
import { ResolvedVar, resolveService, startOrder } from './compose-resolver';
import { CatalogPackage, PackageCatalogService } from '../../core/services/package-catalog.service';
import { CapabilitiesService, ProvidersResponse } from '../../core/services/capabilities.service';

interface RunbookRow { id: string; name: string; folder: string }

/**
 * Blueprint editor (PROTOTYPE — see the plan im-plan-war-ja-iridescent-pony.md).
 *
 * Place a component, pick a role, fill its real typed variables, connect it to the
 * next one — and the result IS a Docker Compose document (JSON + YAML), because
 * Compose already has services / environment / ports / depends_on. Nothing is
 * executed: this branch exists to judge the editor, so every call is a GET.
 *
 * Layout follows docs/design-philosophy.md §4 (source list → content → inspector).
 */
@Component({
  selector: 'app-blueprint',
  standalone: true,
  imports: [FormsModule, RouterLink, MatIconModule, MatButtonModule, ParamFormComponent, BlueprintCanvasComponent],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <h1>Blueprint <span class="bm-tag">Prototype</span></h1>
        <span class="bm-subtitle">
          Infrastructure as a Docker Compose document: place a service → pick a role → fill its variables →
          connect. The edge writes the wiring variables. Nothing is executed.
        </span>
      </div>

      @if (store.error(); as e) { <p class="bm-err">{{ e }}</p> }

      <div class="bm-cols">
        <!-- Palette -->
        <aside class="bm-pal">
          <div class="bm-pal-h">Components</div>
          @for (p of palette; track p.icon) {
            <button type="button" class="bm-pal-i" (click)="place(p)"
                    draggable="true" (dragstart)="onDragStart($event, p)"
                    [title]="p.kind + ' — drag or click'">
              <img [src]="'assets/blueprint/' + p.icon + '.svg'" [alt]="p.label" />
              <span>{{ p.label }}</span>
              <small>{{ p.kind }}</small>
            </button>
          }
          <div class="bm-pal-h" style="margin-top:14px">Document</div>
          <label class="bm-fld"><span>Stack name</span>
            <input [ngModel]="store.blueprint().name" (ngModelChange)="store.setName($event)" />
          </label>
          <button mat-stroked-button class="bm-w" (click)="download('json')"
                  title="Full blueprint — includes role, placement and layout; can be re-imported">
            <mat-icon>download</mat-icon> Blueprint (JSON)
          </button>
          <button mat-stroked-button class="bm-w" (click)="download('yaml')"
                  title="Plain Compose for docker compose — without editor metadata (layout/role are lost)">
            <mat-icon>description</mat-icon> compose.yaml
          </button>
          <button mat-stroked-button class="bm-w" (click)="fileInput.click()"><mat-icon>upload</mat-icon> Import</button>
          <input #fileInput type="file" accept=".yml,.yaml,.json" hidden (change)="onFile($event)" />
          <button mat-stroked-button class="bm-w" (click)="store.reset()"><mat-icon>delete_sweep</mat-icon> Clear</button>

          <div class="bm-pal-h" style="margin-top:14px">Fleet</div>
          <select class="bm-w bm-bp-pick" [ngModel]="''" (ngModelChange)="loadBackend($event)"
                  title="Load a saved blueprint from the fleet into the editor">
            <option value="" disabled selected>Load saved blueprint…</option>
            @for (b of backendList(); track b.id) { <option [value]="b.id">{{ b.name }} ({{ b.status }})</option> }
          </select>
          <button mat-flat-button color="primary" class="bm-w" (click)="saveToFleet()" [disabled]="store.saving() || !store.services().length">
            <mat-icon>cloud_upload</mat-icon> {{ store.backendId() ? 'Update in fleet' : 'Save to fleet' }}
          </button>
          @if (store.backendId(); as id) {
            <a class="bm-w bm-bp-open" [routerLink]="'/blueprint-drafts'" title="Open in Blueprint management (compile, wiring, save as runbook)">
              <mat-icon>open_in_new</mat-icon> Manage / compile
            </a>
          }
          @if (savedMsg()) { <p class="bm-ok">{{ savedMsg() }}</p> }
        </aside>

        <!-- Canvas + document -->
        <section class="bm-mid">
          <app-blueprint-canvas
            [blueprint]="store.blueprint()" [selected]="store.selected()"
            (select)="store.selected.set($event)"
            (selectEdge)="onSelectEdge($event)"
            (dropped)="onDropped($event)"
            (connectPair)="store.connect($event.from, $event.to)"
            (moved)="store.move($event.name, $event.x, $event.y)"
            (removeNode)="store.remove($event)" />

          @if (order().cycle.length) {
            <p class="bm-err">Cycle in depends_on: {{ order().cycle.join(' → ') }}</p>
          } @else if (order().order.length > 1) {
            <p class="bm-dim">Start order (depends_on, topological): <code>{{ order().order.join(' → ') }}</code></p>
          }

          <!-- The document is the payoff, so it stays visible by default — but it
               can be folded away to give the canvas the whole column. -->
          <div class="bm-doc">
            <div class="bm-doc-tabs">
              <button type="button" class="bm-doc-fold" (click)="docOpen.set(!docOpen())"
                      [title]="docOpen() ? 'Collapse document' : 'Expand document'">
                <mat-icon>{{ docOpen() ? 'expand_more' : 'chevron_right' }}</mat-icon>
              </button>
              <button type="button" [class.on]="view() === 'yaml'" (click)="view.set('yaml'); docOpen.set(true)">compose.yaml</button>
              <button type="button" [class.on]="view() === 'json'" (click)="view.set('json'); docOpen.set(true)">JSON</button>
              <span class="bm-doc-meta">{{ store.services().length }} services</span>
            </div>
            @if (docOpen()) {
              <pre>{{ view() === 'yaml' ? store.composeYaml() : store.composeJson() }}</pre>
            }
          </div>
        </section>

        <!-- Inspector -->
        <aside class="bm-insp">
          @if (store.selectedService(); as s) {
            <div class="bm-insp-h">
              <img [src]="'assets/blueprint/' + s.icon + '.svg'" alt="" />
              <strong>{{ s.name }}</strong>
              <span class="bm-tag">{{ s.kind }}</span>
            </div>

            <label class="bm-fld"><span>Service name (= address for other services)</span>
              <input [ngModel]="s.name" (ngModelChange)="store.rename(s.name, $event)" />
            </label>

            <!-- ONE schema source for both tiers (docs/app-model.md: one
                 values_schema, a different artifact per target) — the role's
                 template schema is where the typed variables come from, whether
                 the service ends up as a package or a container. -->
            <label class="bm-fld">
              <span>Role / template — supplies the variables
                @if (categoryHint(s.icon); as c) { <em class="bm-cat">{{ c }} only</em> }
              </span>
              <select [ngModel]="s.role ?? ''" (ngModelChange)="pickRole(s.name, $event)">
                <option value="">— none —</option>
                @for (r of rolesFor(s.icon); track r.id) { <option [value]="r.name">{{ r.label }}</option> }
              </select>
            </label>

            @if (s.kind === 'docker') {
              <label class="bm-fld"><span>Image (artifact for the Docker tier)</span>
                <input [ngModel]="s.image ?? ''" (ngModelChange)="store.update(s.name, { image: $event })"
                       placeholder="e.g. redis:7" />
              </label>
            }

            <label class="bm-fld"><span>Host (x-yolo-host) — where the service runs</span>
              <input [ngModel]="s.host ?? ''" (ngModelChange)="store.update(s.name, { host: $event })"
                     placeholder="e.g. docker-test" />
            </label>

            @if (s.kind === 'native') {
              <label class="bm-fld"><span>Planned address (IP/FQDN)</span>
                <input [ngModel]="s.address ?? ''" (ngModelChange)="store.update(s.name, { address: $event })"
                       placeholder="e.g. 192.0.2.60" />
              </label>
              @if (!s.address && !s.host) {
                <p class="bm-warn">Address still open — Compose DNS does not apply to native services. The IP is
                  allocated up front in IPAM; the DNS name is created by the managed BIND.</p>
              }
            }

            <label class="bm-fld"><span>Ports (comma-separated, host:container)</span>
              <input [ngModel]="s.ports.join(', ')" (ngModelChange)="setPorts(s.name, $event)" placeholder="8080:80" />
            </label>

            @if (store.openRequirementCaps(s.name); as open) {
              @if (open.length) {
                <div class="bm-insp-sec">Open requirements</div>
                @for (req of open; track req.capability) {
                  <div class="bm-req-block">
                    <p class="bm-warn">Needs <code class="bm-req">{{ req.capability }}</code>@if (req.backends?.length) { <span class="bm-req-be">({{ req.backends!.join(' | ') }})</span> }</p>
                    @if (suggestionFor(req.capability); as sug) {
                      @if (sug.providers.length) {
                        <div class="bm-sug-sec">Available in inventory:</div>
                        @for (p of sug.providers; track p.agent_id) {
                          <div class="bm-sug"><code>{{ p.hostname || p.address }}</code>
                            <span class="bm-sug-be">{{ p.backend }}{{ p.port ? ':' + p.port : '' }}</span>
                          </div>
                        }
                      } @else if (sug.roles.length) {
                        <div class="bm-sug-sec">No host provides it — new server with role:</div>
                        @for (r of sug.roles; track r.role) {
                          <div class="bm-sug"><code>{{ r.label || r.role }}</code>
                            <span class="bm-sug-be">{{ r.backend }}</span>
                          </div>
                        }
                      } @else {
                        <p class="bm-hint">No provider known yet (catalog is being enriched).</p>
                      }
                    }
                  </div>
                }
                <p class="bm-hint">Connect the role to a service that provides it.</p>
              }
            }

            @if (s.dependsOn.length) {
              <div class="bm-insp-sec">Depends on</div>
              @for (d of s.dependsOn; track d) {
                <div class="bm-dep">
                  <code>{{ d }}</code>
                  <button mat-button (click)="store.disconnect(s.name, d)">Disconnect</button>
                </div>
              }
            }

            <div class="bm-insp-sec">Variables
              @if (loadingSchema()) { <span class="bm-dim">· loading schema…</span> }
            </div>
            @if (schemaFor(s.role); as sch) {
              <app-param-form [params]="sch" [initial]="store.formValuesOf(s)" (valuesChange)="store.setValues(s.name, $event)" />
              <p class="bm-dim">These values are rendered by the config template (<code>x-yolo-values</code>) — they are
                directives, not environment variables. <code>environment:</code> holds only the wiring variables
                from the edges.</p>
              @if (badEnvKeys(s); as bad) {
                <p class="bm-warn">Not a valid env name: <code>{{ bad }}</code> — cannot be applied as an environment
                  variable.</p>
              }
            } @else if (!s.role) {
              <p class="bm-dim">Pick a role / template — its <code>schema.json</code> supplies the
                typed variables (enums become dropdowns). The wiring variables come additionally
                from the edges.</p>
            } @else {
              <p class="bm-dim">This role has no parameter schema — variables come only from the edges.</p>
            }

            @if (resolved(s.name).length) {
              <div class="bm-insp-sec">Resolution (preview)</div>
              <table class="bm-res">
                @for (v of resolved(s.name); track v.key) {
                  <tr [class.un]="v.state === 'unresolved'">
                    <td><code>{{ v.key }}</code></td>
                    <td>
                      @if (v.state === 'unresolved') { <em>unresolvable</em> } @else { {{ v.value }} }
                      @if (v.from) { <span class="bm-from">from {{ v.from }}</span> }
                      @if (v.note) { <span class="bm-note">{{ v.note }}</span> }
                    </td>
                  </tr>
                }
              </table>
            }
          } @else if (selectedEdge(); as e) {
            <!-- An edge is not decoration: it owns the variables it wired, so this is
                 where you define them (rename the key a consumer expects, override a
                 value, add another one). -->
            <div class="bm-insp-h">
              <mat-icon>arrow_downward</mat-icon>
              <strong>{{ e.from }} → {{ e.to }}</strong>
            </div>
            <p class="bm-dim"><code>{{ e.from }}</code> depends on <code>{{ e.to }}</code>
              (<code>depends_on</code>). The edge writes these variables:</p>

            @for (b of store.bindingsOf(e.from, e.to); track b.key) {
              <div class="bm-bind">
                <input class="bm-bind-k" [ngModel]="b.key"
                       (ngModelChange)="store.renameBinding(e.from, b.key, $event)"
                       title="Variable name the consumer expects" />
                <input class="bm-bind-v" [ngModel]="b.value"
                       (ngModelChange)="store.setBindingValue(e.from, b.key, $event)"
                       title="Value — a service name is resolved to an address" />
                <button mat-button (click)="store.removeBinding(e.from, b.key)" title="Remove variable">×</button>
              </div>
            } @empty {
              <p class="bm-dim">This edge does not write any variable yet.</p>
            }

            <div class="bm-bind">
              <input class="bm-bind-k" [ngModel]="newVarKey()" (ngModelChange)="newVarKey.set($event)"
                     placeholder="NEW_VARIABLE" />
              <button mat-stroked-button (click)="addVar(e)" [disabled]="!newVarKey().trim()">Add</button>
            </div>

            <button mat-stroked-button class="bm-w" (click)="store.disconnect(e.from, e.to); selectedEdge.set(null)">
              <mat-icon>link_off</mat-icon> Disconnect
            </button>
          } @else {
            <p class="bm-dim">Nothing selected. Drag a component from the left onto the canvas — or click an
              edge to define its variables.</p>
          }
        </aside>
      </div>
    </div>
  `,
  styles: [`
    .bm-page { padding: 20px 24px 28px; }
    .bm-head h1 { margin: 0; font-size: 20px; }
    .bm-tag { font-size: 10.5px; padding: 1px 8px; border-radius: 999px; font-family: ui-monospace, monospace;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); vertical-align: middle; }
    .bm-subtitle { display: block; opacity: .62; font-size: 12.5px; margin: 3px 0 14px; max-width: 90ch; }
    .bm-cols { display: grid; grid-template-columns: 190px minmax(0, 1fr) 330px; gap: 16px; align-items: start; }
    @media (max-width: 1200px) { .bm-cols { grid-template-columns: 170px minmax(0,1fr); } .bm-insp { grid-column: 1 / -1; } }
    .bm-pal, .bm-insp { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 12px; }
    .bm-pal-h, .bm-insp-sec { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; opacity: .55; margin: 0 0 6px; }
    .bm-insp-sec { margin-top: 14px; }
    .bm-pal-i { display: flex; align-items: center; gap: 8px; width: 100%; padding: 6px 8px; margin-bottom: 3px;
      border: 1px solid transparent; border-radius: 8px; background: transparent; color: inherit; cursor: pointer; text-align: left; }
    .bm-pal-i:hover { border-color: var(--mat-sys-outline-variant); background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-pal-i img { width: 22px; height: 22px; opacity: .85; }
    .bm-pal-i span { font-size: 12.5px; flex: 1 1 auto; }
    .bm-pal-i small { font-size: 10px; opacity: .45; font-family: ui-monospace, monospace; }
    .bm-mid { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
    .bm-mid app-blueprint-canvas { display: block; min-height: 540px; }
    .bm-doc { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-doc-tabs { display: flex; align-items: center; gap: 2px; padding: 6px 8px 0; }
    .bm-doc-fold { display: flex; align-items: center; padding: 2px !important; opacity: .7; }
    .bm-doc-fold mat-icon { font-size: 18px; width: 18px; height: 18px; }
    .bm-doc-meta { margin-left: auto; font-size: 10.5px; opacity: .45; font-family: ui-monospace, monospace; padding-right: 4px; }
    .bm-doc-tabs button { font-size: 11.5px; padding: 4px 12px; border: 0; border-radius: 7px 7px 0 0;
      background: transparent; color: inherit; opacity: .6; cursor: pointer; font-family: ui-monospace, monospace; }
    .bm-doc-tabs button.on { opacity: 1; background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-doc pre { margin: 0; padding: 12px 14px; max-height: 260px; overflow: auto; font-size: 11.5px; line-height: 1.5;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-insp-h { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .bm-insp-h img { width: 26px; height: 26px; opacity: .85; }
    .bm-fld { display: block; margin-bottom: 9px; }
    .bm-fld span { display: block; font-size: 11px; opacity: .6; margin-bottom: 3px; }
    .bm-fld input, .bm-fld select { width: 100%; box-sizing: border-box; padding: 6px 9px; font-size: 12.5px;
      border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-w { width: 100%; margin-top: 6px; }
    .bm-dep { display: flex; align-items: center; justify-content: space-between; font-size: 12px; }
    .bm-bind { display: flex; align-items: center; gap: 5px; margin-bottom: 5px; }
    .bm-bind input { box-sizing: border-box; padding: 5px 8px; font-size: 12px; font-family: ui-monospace, monospace;
      border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-bind-k { flex: 0 0 44%; }
    .bm-bind-v { flex: 1 1 auto; min-width: 0; }
    .bm-cat { font-style: normal; margin-left: 6px; padding: 0 6px; border-radius: 999px; font-size: 10px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-res { width: 100%; border-collapse: collapse; font-size: 11.5px; }
    .bm-res td { padding: 3px 4px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
    .bm-res tr.un td { color: var(--bm-gold, #b8860b); }
    .bm-from { display: inline-block; margin-left: 5px; font-size: 10px; opacity: .6; }
    .bm-note { display: block; font-size: 10px; opacity: .5; }
    .bm-dim { opacity: .6; font-size: 12px; }
    .bm-warn { color: var(--bm-gold, #b8860b); font-size: 11.5px; margin: 2px 0 8px; }
    .bm-err { color: var(--mat-sys-error, #c62828); font-size: 12.5px; }
    code { font-family: ui-monospace, monospace; }
  `],
})
export class BlueprintComponent implements OnInit {
  store = inject(BlueprintStore);
  private http = inject(HttpClient);
  private catalogSvc = inject(PackageCatalogService);
  private capsSvc = inject(CapabilitiesService);

  /** template → its role-grain contract (capabilities.json), fetched once per template. */
  private contracts = signal<Record<string, RoleContract>>({});
  private requestedContracts = new Set<string>();
  /** capability token → the inventory hosts + candidate roles that provide it (the suggestion list). */
  suggestions = signal<Record<string, ProvidersResponse>>({});
  private requestedSuggestions = new Set<string>();

  palette = PALETTE;
  view = signal<'yaml' | 'json'>('yaml');
  docOpen = signal(true);
  roles = signal<RunbookRow[]>([]);
  /** saved backend blueprints (the fleet picker) + a transient "saved" toast. */
  backendList = signal<BackendBlueprintRow[]>([]);
  savedMsg = signal('');
  selectedEdge = signal<{ from: string; to: string } | null>(null);
  newVarKey = signal('');
  /** the package catalog — supplies each role's `kind` and `category` */
  private catalog = signal<Record<string, CatalogPackage>>({});
  loadingSchema = signal(false);
  /** role name → its typed parameters (lazy: the list endpoint doesn't return them) */
  private schemas = signal<Record<string, ParamSchema>>({});
  /** roles already requested — a plain Set (not a signal) so the effect that calls
   * loadSchema() can write `schemas` without re-triggering itself. */
  private requested = new Set<string>();

  constructor() {
    // A role lives in the DOCUMENT (x-yolo-role) but the schema cache is in memory,
    // so after a reload or a compose import the variables form would be missing
    // until the user re-picked the role. Fetch on demand for whatever is selected.
    effect(() => {
      const svc = this.store.selectedService();
      const haveRoles = this.roles().length;      // re-run once the role list arrives
      if (svc?.role && haveRoles) this.loadSchema(svc.role);
      // Role-grain contract (for backend-aware plausibility) + provider suggestions for open slots.
      // Writes land in async HTTP callbacks, so this stays effect-safe; the requested-sets dedupe.
      if (svc?.template) this.loadContract(svc.template);
      if (svc) this.loadSuggestions(svc.name);
    });
  }

  order = computed(() => startOrder(this.store.blueprint()));

  ngOnInit(): void {
    this.refreshBackendList();
    // The palette of roles = the seeded install-<pkg> wizards, whose `parameters`
    // are a real typed input mask (with enums) — that is where the variables come from.
    this.http.get<{ runbooks: RunbookRow[] }>(`${environment.apiUrl}/runbooks`).subscribe({
      next: (r) => this.roles.set((r.runbooks || [])
        .filter((x) => (x.folder || '').startsWith('wizard'))
        .sort((a, b) => a.name.localeCompare(b.name))),
      error: () => this.store.error.set('Failed to load roles.'),
    });
    // The catalog tells us which of those wizards are actually installable SERVER
    // ROLES (kind==='role') and what category they are — the 14 kind==='config'
    // entries are base-system config files that belong in the Configuration tab,
    // not on a blueprint canvas.
    this.catalogSvc.catalog().subscribe({
      next: (r) => this.catalog.set(r.packages || {}),
      error: () => { /* filtering degrades to "show all roles" */ },
    });
  }

  // ---- fleet persistence (backend blueprints) ----------------------------

  private refreshBackendList(): void {
    this.store.listBackend().subscribe({
      next: (rows) => this.backendList.set(rows || []),
      error: () => { /* offline / empty — picker just stays empty */ },
    });
  }

  /** Load a saved blueprint from the fleet into the editor. */
  loadBackend(id: string): void {
    if (!id) return;
    this.savedMsg.set('');
    void this.store.openBackend(id).then(() => this.savedMsg.set('Loaded from fleet.'));
  }

  /** Promote the current draft to a backend blueprint (create or update). */
  saveToFleet(): void {
    this.savedMsg.set('');
    void this.store.saveToBackend().then((row) => {
      this.savedMsg.set(`Saved “${row.name}” to the fleet — open Manage / compile to deploy it.`);
      this.refreshBackendList();
    }).catch(() => { /* error surfaced via store.error */ });
  }

  /** Roles offered for a component: catalog kind==='role', and — when the palette
   * entry declares categories — only those categories. Placing a database must not
   * offer a firewall role. */
  rolesFor(icon: string): { id: string; name: string; label: string }[] {
    const entry = paletteFor(icon);
    const cats = entry?.categories;
    const cat = this.catalog();
    const known = Object.keys(cat).length > 0;
    return this.roles()
      .map((r) => ({ row: r, pkg: cat[r.name.replace(/^install-/, '')] }))
      .filter(({ pkg }) => !known || (pkg && pkg.kind !== 'config'))
      .filter(({ pkg }) => !cats?.length || !pkg || cats.includes(pkg.category))
      .map(({ row, pkg }) => ({ id: row.id, name: row.name, label: pkg?.label ? `${pkg.label} (${row.name})` : row.name }))
      .sort((a, b) => a.label.localeCompare(b.label));
  }

  categoryHint(icon: string): string | null {
    const cats = paletteFor(icon)?.categories;
    return cats?.length ? cats.join(' / ') : null;
  }

  /** Selecting an edge clears the node selection: the inspector shows one thing at
   * a time, and the node branch would otherwise keep winning in the template. */
  onSelectEdge(e: { from: string; to: string } | null): void {
    this.selectedEdge.set(e);
    if (e) this.store.selected.set(null);
  }

  onDragStart(ev: DragEvent, p: PaletteEntry): void {
    ev.dataTransfer?.setData('text/x-blueprint-icon', p.icon);
    if (ev.dataTransfer) ev.dataTransfer.effectAllowed = 'copy';
  }

  /** Dropped on the canvas at model coordinates — place it exactly there. */
  onDropped(e: { icon: string; x: number; y: number }): void {
    const entry = paletteFor(e.icon);
    if (entry) { this.store.add(entry, e.x, e.y); this.selectedEdge.set(null); }
  }

  addVar(e: { from: string; to: string }): void {
    this.store.addBinding(e.from, e.to, this.newVarKey());
    this.newVarKey.set('');
  }

  /** Place a component at a free-ish spot (simple spiral so nodes don't stack). */
  place(p: PaletteEntry): void {
    const n = this.store.services().length;
    this.store.add(p, 140 + (n % 4) * 190, 130 + Math.floor(n / 4) * 165);
  }

  pickRole(service: string, role: string): void {
    const template = role ? role.replace(/^install-/, '') : undefined;
    this.store.update(service, { role: role || undefined, template, caps: undefined });
    if (role) this.loadSchema(role);
    if (template) this.loadContract(template);
  }

  /** Fetch a role's capability contract (config-templates/<template>/capabilities.json) once and stamp it
   *  onto every node using that template — this is what upgrades plausibility from archetype to role grain
   *  (postgresql ≠ mysql). A template with no contract yet (enrich batch not there) is simply left coarse. */
  private loadContract(template: string): void {
    const cached = this.contracts()[template];
    if (cached) { this.applyContract(template, cached); return; }
    if (this.requestedContracts.has(template)) return;
    this.requestedContracts.add(template);
    this.capsSvc.templateContract(template).subscribe({
      next: (t) => {
        const caps = t.capabilities;
        if (caps && (caps.provides?.length || caps.requires?.length)) {
          this.contracts.update((m) => ({ ...m, [template]: caps }));
          this.applyContract(template, caps);
        }
      },
      error: () => this.requestedContracts.delete(template),   // allow a retry
    });
  }

  private applyContract(template: string, caps: RoleContract): void {
    for (const s of this.store.services()) {
      if (s.template === template && s.caps !== caps) this.store.update(s.name, { caps });
    }
  }

  /** For the selected service's OPEN requirements, ask the backend matcher which inventory hosts (and
   *  which catalog roles, for a brand-new server) provide each — the suggestion list under the role. */
  loadSuggestions(name: string): void {
    for (const req of this.store.openRequirementCaps(name)) {
      const backend = req.backends?.length ? req.backends[0] : '';
      const key = `${req.capability}|${backend}`;
      if (this.requestedSuggestions.has(key)) continue;
      this.requestedSuggestions.add(key);
      this.capsSvc.providers(req.capability, backend || undefined).subscribe({
        next: (resp) => this.suggestions.update((m) => ({ ...m, [req.capability]: resp })),
        error: () => this.requestedSuggestions.delete(key),
      });
    }
  }

  /** The suggestion for one open-requirement capability (for the template). */
  suggestionFor(capability: string): ProvidersResponse | undefined {
    return this.suggestions()[capability];
  }

  /** Fetch a role's parameters once (GET /runbooks lists names only, the detail
   * endpoint carries `parameters`) — mirrors core/services/wizard.service.ts. */
  private loadSchema(role: string): void {
    if (this.requested.has(role)) return;
    const row = this.roles().find((r) => r.name === role);
    if (!row) return;
    this.requested.add(role);
    this.loadingSchema.set(true);
    this.http.get<{ parameters: ParamSchema }>(`${environment.apiUrl}/runbooks/${row.id}`).subscribe({
      next: (full) => {
        this.loadingSchema.set(false);
        this.schemas.update((m) => ({ ...m, [role]: full.parameters || {} }));
      },
      error: () => {
        this.loadingSchema.set(false);
        this.requested.delete(role);   // allow a retry
        this.store.error.set(`Failed to load schema for ${role}.`);
      },
    });
  }

  schemaFor(role: string | undefined): ParamSchema | null {
    if (!role) return null;
    const s = this.schemas()[role];
    return s && Object.keys(s).length ? s : null;
  }

  setPorts(name: string, raw: string): void {
    this.store.update(name, { ports: raw.split(',').map((p) => p.trim()).filter(Boolean) });
  }

  /** Env keys a runtime could not actually apply (POSIX name rule) — shown instead of
   * silently emitting a compose file that fails. */
  badEnvKeys(s: { environment: Record<string, string> }): string | null {
    const bad = Object.keys(s.environment).filter((k) => !isValidEnvName(k));
    return bad.length ? bad.slice(0, 6).join(', ') + (bad.length > 6 ? ` … +${bad.length - 6}` : '') : null;
  }

  resolved(name: string): ResolvedVar[] {
    const svc = this.store.services().find((s) => s.name === name);
    return svc ? resolveService(this.store.blueprint(), svc) : [];
  }

  /**
   * Two exports on purpose, because they are not interchangeable:
   *  - 'json' is the FULL blueprint (Compose + x-yolo-* meta) and is what round-trips;
   *  - 'yaml' is clean Compose for `docker compose`, and therefore DROPS role,
   *    placement and layout. Offering only the YAML would quietly lose that work on
   *    the next import.
   */
  download(kind: 'json' | 'yaml'): void {
    const name = this.store.blueprint().name || 'blueprint';
    const [text, type, file] = kind === 'json'
      ? [this.store.composeJson(), 'application/json', `${name}.blueprint.json`]
      : [this.store.composeYaml(), 'text/yaml', `${name}.compose.yaml`];
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type }));
    a.download = file;
    a.click();
    URL.revokeObjectURL(a.href);
  }

  onFile(ev: Event): void {
    const input = ev.target as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    file.text().then((t) => this.store.importCompose(t));
    input.value = '';
  }
}
