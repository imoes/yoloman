import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';
import { ParamSchema } from '../../shared/param-form/param-form.types';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { BlueprintCanvasComponent } from './blueprint-canvas.component';
import { BlueprintStore } from './blueprint-store';
import { PALETTE, PaletteEntry } from './compose-model';
import { ResolvedVar, resolveService, startOrder } from './compose-resolver';

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
  imports: [FormsModule, MatIconModule, MatButtonModule, ParamFormComponent, BlueprintCanvasComponent],
  template: `
    <div class="bm-page">
      <div class="bm-head">
        <h1>Blueprint <span class="bm-tag">Prototyp</span></h1>
        <span class="bm-subtitle">
          Infrastruktur als Docker-Compose-Dokument: Dienst platzieren → Rolle wählen → Variablen füllen →
          verbinden. Die Kante schreibt die Wiring-Variablen. Nichts wird ausgeführt.
        </span>
      </div>

      @if (store.error(); as e) { <p class="bm-err">{{ e }}</p> }

      <div class="bm-cols">
        <!-- Palette -->
        <aside class="bm-pal">
          <div class="bm-pal-h">Komponenten</div>
          @for (p of palette; track p.icon) {
            <button type="button" class="bm-pal-i" (click)="place(p)" [title]="p.kind">
              <img [src]="'assets/blueprint/' + p.icon + '.svg'" [alt]="p.label" />
              <span>{{ p.label }}</span>
              <small>{{ p.kind }}</small>
            </button>
          }
          <div class="bm-pal-h" style="margin-top:14px">Dokument</div>
          <label class="bm-fld"><span>Stack-Name</span>
            <input [ngModel]="store.blueprint().name" (ngModelChange)="store.setName($event)" />
          </label>
          <button mat-stroked-button class="bm-w" (click)="download()"><mat-icon>download</mat-icon> Export</button>
          <button mat-stroked-button class="bm-w" (click)="fileInput.click()"><mat-icon>upload</mat-icon> Import</button>
          <input #fileInput type="file" accept=".yml,.yaml,.json" hidden (change)="onFile($event)" />
          <button mat-stroked-button class="bm-w" (click)="store.reset()"><mat-icon>delete_sweep</mat-icon> Leeren</button>
        </aside>

        <!-- Canvas + document -->
        <section class="bm-mid">
          <app-blueprint-canvas
            [blueprint]="store.blueprint()" [selected]="store.selected()"
            (select)="store.selected.set($event)"
            (connectPair)="store.connect($event.from, $event.to)"
            (moved)="store.move($event.name, $event.x, $event.y)"
            (removeNode)="store.remove($event)" />

          @if (order().cycle.length) {
            <p class="bm-err">Zyklus in depends_on: {{ order().cycle.join(' → ') }}</p>
          } @else if (order().order.length > 1) {
            <p class="bm-dim">Startreihenfolge (depends_on, topologisch): <code>{{ order().order.join(' → ') }}</code></p>
          }

          <div class="bm-doc">
            <div class="bm-doc-tabs">
              <button type="button" [class.on]="view() === 'yaml'" (click)="view.set('yaml')">compose.yaml</button>
              <button type="button" [class.on]="view() === 'json'" (click)="view.set('json')">JSON</button>
            </div>
            <pre>{{ view() === 'yaml' ? store.composeYaml() : store.composeJson() }}</pre>
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

            <label class="bm-fld"><span>Servicename (= Adresse für andere Dienste)</span>
              <input [ngModel]="s.name" (ngModelChange)="store.rename(s.name, $event)" />
            </label>

            @if (s.kind === 'native') {
              <label class="bm-fld"><span>Rolle</span>
                <select [ngModel]="s.role ?? ''" (ngModelChange)="pickRole(s.name, $event)">
                  <option value="">— keine —</option>
                  @for (r of roles(); track r.id) { <option [value]="r.name">{{ r.name }}</option> }
                </select>
              </label>
              <label class="bm-fld"><span>Host (x-yolo-host)</span>
                <input [ngModel]="s.host ?? ''" (ngModelChange)="store.update(s.name, { host: $event })"
                       placeholder="z.B. docker-test" />
              </label>
              <label class="bm-fld"><span>Geplante Adresse (IP/FQDN)</span>
                <input [ngModel]="s.address ?? ''" (ngModelChange)="store.update(s.name, { address: $event })"
                       placeholder="z.B. 192.0.2.60" />
              </label>
              @if (!s.address && !s.host) {
                <p class="bm-warn">Adresse noch offen — Compose-DNS greift für native Dienste nicht. Die IP wird
                  vorab im IPAM (NetBox) vergeben; den DNS-Namen legt das verwaltete BIND an.</p>
              }
            } @else {
              <label class="bm-fld"><span>Image</span>
                <input [ngModel]="s.image ?? ''" (ngModelChange)="store.update(s.name, { image: $event })"
                       placeholder="z.B. redis:7" />
              </label>
            }

            <label class="bm-fld"><span>Ports (Komma-getrennt, host:container)</span>
              <input [ngModel]="s.ports.join(', ')" (ngModelChange)="setPorts(s.name, $event)" placeholder="8080:80" />
            </label>

            @if (s.dependsOn.length) {
              <div class="bm-insp-sec">Abhängig von</div>
              @for (d of s.dependsOn; track d) {
                <div class="bm-dep">
                  <code>{{ d }}</code>
                  <button mat-button (click)="store.disconnect(s.name, d)">Trennen</button>
                </div>
              }
            }

            <div class="bm-insp-sec">Variablen
              @if (loadingSchema()) { <span class="bm-dim">· lade Schema…</span> }
            </div>
            @if (schemaFor(s.role); as sch) {
              <app-param-form [params]="sch" [initial]="s.environment" (valuesChange)="store.setValues(s.name, $event)" />
            } @else if (s.kind === 'native' && !s.role) {
              <p class="bm-dim">Wähle eine Rolle — ihr Schema liefert die typisierten Variablen.</p>
            } @else if (!s.role) {
              <p class="bm-dim">Für Container-Dienste kommen die Variablen aus den Kanten und dem Image.</p>
            }

            @if (resolved(s.name).length) {
              <div class="bm-insp-sec">Auflösung (Vorschau)</div>
              <table class="bm-res">
                @for (v of resolved(s.name); track v.key) {
                  <tr [class.un]="v.state === 'unresolved'">
                    <td><code>{{ v.key }}</code></td>
                    <td>
                      @if (v.state === 'unresolved') { <em>nicht auflösbar</em> } @else { {{ v.value }} }
                      @if (v.from) { <span class="bm-from">von {{ v.from }}</span> }
                      @if (v.note) { <span class="bm-note">{{ v.note }}</span> }
                    </td>
                  </tr>
                }
              </table>
            }
          } @else {
            <p class="bm-dim">Kein Dienst ausgewählt. Links eine Komponente anklicken, um sie zu platzieren.</p>
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
    .bm-doc { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-doc-tabs { display: flex; gap: 2px; padding: 6px 8px 0; }
    .bm-doc-tabs button { font-size: 11.5px; padding: 4px 12px; border: 0; border-radius: 7px 7px 0 0;
      background: transparent; color: inherit; opacity: .6; cursor: pointer; font-family: ui-monospace, monospace; }
    .bm-doc-tabs button.on { opacity: 1; background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-doc pre { margin: 0; padding: 12px 14px; max-height: 300px; overflow: auto; font-size: 11.5px; line-height: 1.5;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-insp-h { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .bm-insp-h img { width: 26px; height: 26px; opacity: .85; }
    .bm-fld { display: block; margin-bottom: 9px; }
    .bm-fld span { display: block; font-size: 11px; opacity: .6; margin-bottom: 3px; }
    .bm-fld input, .bm-fld select { width: 100%; box-sizing: border-box; padding: 6px 9px; font-size: 12.5px;
      border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-w { width: 100%; margin-top: 6px; }
    .bm-dep { display: flex; align-items: center; justify-content: space-between; font-size: 12px; }
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

  palette = PALETTE;
  view = signal<'yaml' | 'json'>('yaml');
  roles = signal<RunbookRow[]>([]);
  loadingSchema = signal(false);
  /** role name → its typed parameters (lazy: the list endpoint doesn't return them) */
  private schemas = signal<Record<string, ParamSchema>>({});

  order = computed(() => startOrder(this.store.blueprint()));

  ngOnInit(): void {
    // The palette of roles = the seeded install-<pkg> wizards, whose `parameters`
    // are a real typed input mask (with enums) — that is where the variables come from.
    this.http.get<{ runbooks: RunbookRow[] }>(`${environment.apiUrl}/runbooks`).subscribe({
      next: (r) => this.roles.set((r.runbooks || [])
        .filter((x) => (x.folder || '').startsWith('wizard'))
        .sort((a, b) => a.name.localeCompare(b.name))),
      error: () => this.store.error.set('Rollen konnten nicht geladen werden.'),
    });
  }

  /** Place a component at a free-ish spot (simple spiral so nodes don't stack). */
  place(p: PaletteEntry): void {
    const n = this.store.services().length;
    this.store.add(p, 140 + (n % 4) * 190, 130 + Math.floor(n / 4) * 165);
  }

  pickRole(service: string, role: string): void {
    this.store.update(service, { role: role || undefined, template: role ? role.replace(/^install-/, '') : undefined });
    if (role) this.loadSchema(role);
  }

  /** Fetch a role's parameters once (GET /runbooks lists names only, the detail
   * endpoint carries `parameters`) — mirrors core/services/wizard.service.ts. */
  private loadSchema(role: string): void {
    if (this.schemas()[role]) return;
    const row = this.roles().find((r) => r.name === role);
    if (!row) return;
    this.loadingSchema.set(true);
    this.http.get<{ parameters: ParamSchema }>(`${environment.apiUrl}/runbooks/${row.id}`).subscribe({
      next: (full) => {
        this.loadingSchema.set(false);
        this.schemas.update((m) => ({ ...m, [role]: full.parameters || {} }));
      },
      error: () => { this.loadingSchema.set(false); this.store.error.set(`Schema für ${role} nicht ladbar.`); },
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

  resolved(name: string): ResolvedVar[] {
    const svc = this.store.services().find((s) => s.name === name);
    return svc ? resolveService(this.store.blueprint(), svc) : [];
  }

  download(): void {
    const blob = new Blob([this.store.composeYaml()], { type: 'text/yaml' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `${this.store.blueprint().name || 'blueprint'}.compose.yaml`;
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
