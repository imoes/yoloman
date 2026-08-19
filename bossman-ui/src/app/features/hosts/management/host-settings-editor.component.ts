import { Component, effect, inject, input, output, signal, untracked } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { Agent, ConfigTemplateIndexEntry, DirectiveSpec, ObservedResource, ObservedState, StateResourceChange } from '../../../core/models/agent.model';
import { AgentService } from '../../../core/services/agent.service';
import { ServiceState } from '../../../core/models/monitoring.model';
import { MonitoringService } from '../../../core/services/monitoring.service';
import { OrchestrationService } from '../../../core/services/orchestration.service';
import { ConfigCategory, categorizeConfigPath, groupByCategory } from '../../../shared/config-categories';
import { ResourceNodeComponent } from '../../../shared/resource-node/resource-node.component';
import { HostConfigScopeService } from '../host-config-scope.service';
import { driftRows as driftRowsOf, scalarText } from './drift-rows';
import { HostConfigGenerationsComponent } from './host-config-generations.component';
import { HostDriftBannerComponent } from './host-drift-banner.component';
import { HostFileEditComponent } from './host-file-edit.component';
import { HostSettingDialogComponent } from './host-setting-dialog.component';
import { HostTemplateEditComponent } from './host-template-edit.component';
import { HostThresholdsComponent } from './host-thresholds.component';

/** The Configuration tab's Settings editor: the host as one document, in a Miller view.
 *
 * gpedit is the model, and the shape follows it — categories, then the files in that category, then the
 * selected file's settings, each with State (Host based / Configured / Removed), Value and Source. The
 * Source column is the point of the whole screen: a value is either the host's own or the verdict of a
 * policy at some scope, and saying which is what separates a configuration tool from a text editor.
 *
 * THE BIGGEST SLICE, and the boundary was measured rather than guessed: every reader of `observed()` and
 * `drift()` in the page was part of this editor, so the DATA came along instead of being threaded through
 * inputs. It fetches the observed state, the drift/desired map, both host-independent catalogs (directives
 * ~1.9 MB, codecs ~0.6 MB — lazily, on first open) and the path→template index itself. `services` stays an
 * input because the Services tab reads it too; one fact, one owner.
 *
 * WHAT WAS DELETED RATHER THAN MOVED, each verified to have exactly one reference in the app — its own
 * definition:
 *   configText/kvText/iniText/yamlText  Block F1b's native-format renderers, orphaned when the raw and
 *                                       key-value editors were replaced by the per-setting dialog.
 *   appliedPlans                        written by loadDesiredMonitoring, read by nobody since the
 *                                       Orchestration category moved to the Management tab.
 *   sourceFor                           per-FILE policy source; the table shows per-KEY sources instead.
 *   varsCount / varsReloadTick / loadVarsCount / onVarsSaved / openProvisionDb
 *                                       leftovers of the Variables category's move to Management. The
 *                                       count was still being fetched on every observed read for a badge
 *                                       that no longer exists.
 * scalarStr became the shared scalarText from ./drift-rows — it existed twice.
 */
@Component({
  selector: 'app-host-settings-editor',
  standalone: true,
  imports: [
    DatePipe, FormsModule, MatButtonModule, MatIconModule,
    ResourceNodeComponent,
    HostConfigGenerationsComponent, HostDriftBannerComponent, HostFileEditComponent,
    HostSettingDialogComponent, HostTemplateEditComponent, HostThresholdsComponent,
  ],
  template: `
@if (observedLoading()) {
  <p class="bm-empty">Reading the host's configuration…</p>
} @else if (observedError(); as err) {
  <p class="bm-empty">{{ err }}</p>
} @else if (observed(); as obs) {
  <div class="bm-cfg-head">
    <span class="bm-dim">The host as one document — {{ obs.config.length }} config file(s).
      @if (observedCachedAt()) { <em>cached {{ observedCachedAt() | date: 'short' }} — Reload for live.</em> }
    </span>
    <button mat-stroked-button (click)="loadObserved(true)"><mat-icon>refresh</mat-icon> Reload</button>
  </div>
  <app-host-drift-banner [managed]="drift().managed" [drifted]="drift().drift"
                         [busy]="driftBusy()" (resync)="reapplyConfig()"
                         (openFile)="jumpToFile($event)" />
  <input
    class="bm-gpo-search"
    type="search"
    placeholder="Search settings…"
    [ngModel]="gpoSearch()"
    (ngModelChange)="gpoSearch.set($event)"
  />
  <!-- #5: add a config file the host doesn't have on disk yet, from
       the codec catalog, then define it as policy (host/OU/group). -->
  <div class="bm-cfg-addfile">
    <mat-icon class="bm-dim">note_add</mat-icon>
    <input class="bm-kvin bm-addfile-in" list="bm-catalog-files"
           placeholder="Add a config file the host doesn't have yet (e.g. /etc/apt/apt.conf)…"
           [ngModel]="addFilePath()" (ngModelChange)="addFilePath.set($event)"
           (keydown.enter)="addCatalogFile(addFilePath())" />
    <datalist id="bm-catalog-files">
      @for (f of catalogAddOptions(); track f) { <option [value]="f"></option> }
    </datalist>
    <button mat-stroked-button (click)="addCatalogFile(addFilePath())" [disabled]="!addFilePath().trim()">
      <mat-icon>add</mat-icon> Add file
    </button>
  </div>
  <div class="bm-gpo">
    <!-- Miller column 1: categories -->
    <div class="bm-gpo-col">
      @for (c of gpoCategories(obs); track c.key) {
        <div class="bm-gpo-cat" [class.bm-gpo-sel]="gpoActiveCat() === c.key" (click)="selectGpoCat(c.key)">
          <mat-icon class="bm-gpo-cat-ic">{{ c.icon }}</mat-icon>{{ c.label }}
          <span class="bm-gpo-count">{{ c.count }}</span>
        </div>
      }
    </div>
    <!-- Miller column 2: the category's items (thresholds / plans / files) -->
    <div class="bm-gpo-col">
      @for (it of gpoColItems(obs); track it.pane) {
        <div class="bm-gpo-file" [class.bm-gpo-sel]="selectedPane() === it.pane" (click)="selectPane(it.pane)" [title]="it.title">
          {{ it.label }}
          @if (it.drift) { <span class="bm-dot-drift">●</span> }
        </div>
      } @empty {
        <p class="bm-gpo-empty">Pick a category.</p>
      }
    </div>
    <!-- Miller column 3: the selected pane -->
    <div class="bm-gpo-main">
      @if (selectedPane() === '::thresholds') {
        @if (agent(); as a) {
          <app-host-thresholds
            [agent]="a" [services]="services()" [thresholds]="thresholds()"
            (changed)="loadDesiredMonitoring()" />
        } @else {
          <p class="bm-empty">Loading the host…</p>
        }
      } @else if (selRes(obs); as r) {
        <div class="bm-cfg-row">
          <code class="bm-cfg-path">{{ r.path }}</code>
          <span class="bm-tag">{{ r.format || 'raw' }}</span>
          @if (isManaged(r.path)) {
            @if (driftFor(r.path)) { <span class="bm-tag bm-tag-drift">drifted</span> } @else { <span class="bm-tag bm-tag-sync">managed ✓</span> }
          }
          @if (templateFor(r.path); as tpl) {
            @if (tpl.snapin_exclusive) {
              <!-- A snap-in owns this file, so the whole-file editor is NOT offered: named.conf has zones,
                   smb.conf has shares, nginx.conf has server blocks, and rendering one of those from a flat
                   form drops whatever the form has no field for. Saying which snap-in — and linking to it —
                   is the difference between withholding an action and hiding one. -->
              <button mat-button class="bm-snapin-link" (click)="openSnapin.emit(tpl.snapin!)"
                      [title]="'Configured by the ' + tpl.snapin_label + ' snap-in, which understands the structure of this file'">
                <mat-icon>open_in_new</mat-icon> Configured in {{ tpl.snapin_label }}
              </button>
            } @else {
              @if (tpl.template) {
                <button mat-button (click)="startTemplateEdit(r, tpl)"
                        [title]="templateReason(tpl)"><mat-icon>dataset</mat-icon> Edit via template</button>
              }
              @if (tpl.snapin) {
                <!-- Flat file: both doors are safe, so say the other one exists rather than pretending
                     this is the only way in. -->
                <button mat-button class="bm-snapin-link" (click)="openSnapin.emit(tpl.snapin!)"
                        [title]="'Also configurable in the ' + tpl.snapin_label + ' snap-in'">
                  <mat-icon>open_in_new</mat-icon> Also in {{ tpl.snapin_label }}
                </button>
              }
            }
          }
        </div>
        <div class="bm-cfg-viewtoggle">
          <button type="button" class="bm-vt" [class.bm-vt-sel]="configView() === 'editor'" (click)="configView.set('editor')">Settings editor</button>
          <button type="button" class="bm-vt" [class.bm-vt-sel]="configView() === 'resource'" (click)="configView.set('resource')">Resource view</button>
          <span class="bm-dim bm-vt-note">Resource view = the generic config node (host-direct state + generations). The Settings editor keeps scope/policy, source, Removed and restart-after-apply.</span>
        </div>
        @if (configView() === 'resource') {
          <app-resource-node kind="config" [name]="r.path" [agentId]="agentId()" />
        } @else {
        @if (tplEditPath() === r.path) {
          <app-host-template-edit [agentId]="agentId()" [path]="r.path"
                                  [templateName]="tplName()" [ouId]="agent()?.ou_id"
                                  (applied)="loadObserved(true)"
                                  (cancelled)="cancelTemplateEdit()" />
        } @else if (r.values) {
          <table class="bm-gpo-settings">
            <thead><tr><th>Setting</th><th>State</th><th>Value</th><th>Source</th></tr></thead>
            <tbody>
              @for (row of filteredSettingRows(r); track row.key) {
                <tr (click)="openSetting(r, row)" [class.bm-row-sel]="settingKey() === row.key">
                  <td class="bm-gpo-key">{{ row.key }}</td>
                  <td [class.bm-dim]="row.state === 'Host based'">{{ row.state }}</td>
                  <td>
                    @if (row.state === 'Configured') { {{ row.desired }} }
                    @else if (row.state === 'Removed') { <s>{{ row.live || '—' }}</s> }
                    @else { <span class="bm-dim">{{ row.live }}</span> }
                  </td>
                  <td>@if (row.source) { <span class="bm-tag" [class.bm-tag--baseline]="row.state === 'Host based'">{{ row.source }}</span> }</td>
                </tr>
              }
            </tbody>
          </table>
          <div class="bm-cfg-addkey">
            <input class="bm-kvin" placeholder="Add a setting key…"
                   [ngModel]="newSettingKey()" (ngModelChange)="newSettingKey.set($event)"
                   (keydown.enter)="addSettingKey(r)" />
            <button mat-stroked-button (click)="addSettingKey(r)" [disabled]="!newSettingKey().trim()">Add</button>
          </div>
          @if (settingRow(); as row) {
            <app-host-setting-dialog [agentId]="agentId()" [resource]="r" [row]="row"
                                     [spec]="specFor(r.path, row.key)"
                                     [service]="settingService(r.path)" [ouId]="agent()?.ou_id"
                                     (applied)="loadObserved(true)" (closed)="closeSetting()" />
          }
          @if (driftRows(r.path).length) {
            <p class="bm-dim bm-drift-h">Drift — live vs desired:</p>
            <table class="bm-diff">
              <thead><tr><th>Key</th><th>Live</th><th>Desired</th></tr></thead>
              <tbody>
                @for (d of driftRows(r.path); track d.key) {
                  <tr><td>{{ d.key }}</td><td>{{ d.live }}</td><td>{{ d.desired }}</td></tr>
                }
              </tbody>
            </table>
          }
        } @else if (r.raw) {
          <app-host-file-edit [agentId]="agentId()" [path]="r.path" [raw]="r.raw"
                              (changed)="loadObserved(true)" />
        } @else if (r.sha256) {
          <p class="bm-dim">opaque — sha256 {{ r.sha256.slice(0, 12) }}… ({{ r.size }} bytes)</p>
        }
        }
      }
    </div>
  </div>
  @if (!obs.config.length) { <p class="bm-empty">No config files discovered on this host.</p> }

  @if (agent(); as a) {
    <app-host-config-generations [agent]="a" [reloadTick]="observedReloadTick()"
                                 (changed)="loadObserved(true)" />
  }
} @else {
  <p class="bm-empty">Open this tab to read the host's configuration.</p>
}
  `,
  /* COPIED VERBATIM from host-detail's stylesheet. The first draft of this component invented its own
     rules and would have quietly redesigned the screen — the original .bm-gpo is a FLEX row with a
     fixed 210px column and its own scroll, not a grid; .bm-vt is a pill; .bm-gpo-sel marks the
     selection with a left border. Same mistake as the drift banner's palette, caught the same way.
     Styles do not cross a component boundary, so these are copied, not cut: the page still uses many
     of the same class names in other tabs. */
  styles: [`
    .bm-cfg-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
    .bm-cfg-row { display: flex; align-items: center; gap: 10px; }
    .bm-cfg-path { font-weight: 600; word-break: break-all; }
    .bm-cfg-viewtoggle { display: flex; align-items: center; gap: 6px; margin: 8px 0 12px; flex-wrap: wrap; }
    .bm-vt { font-size: 12px; padding: 3px 12px; border-radius: 999px; border: 1px solid var(--mat-sys-outline-variant); background: transparent; color: inherit; cursor: pointer; }
    .bm-vt-sel { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); border-color: var(--mat-sys-primary); }
    .bm-vt-note { flex: 1 1 220px; }
    .bm-kvin { width: 100%; box-sizing: border-box; padding: 5px 8px; font-family: ui-monospace, monospace; font-size: 12px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-tpl-field label .bm-dim { font-weight: 400; }
    .bm-tag-drift { background: color-mix(in srgb, var(--bm-warn, #ef6c00) 30%, transparent); }
    .bm-tag-sync { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .bm-tag--baseline { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); opacity: 0.7; font-weight: 400; }
    .bm-drift-h { margin: 8px 0 2px; }
    /* Reads as a way OUT of this pane rather than another action inside it. */
    .bm-snapin-link { color: var(--mat-sys-primary); }
    .bm-gpo { display: flex; gap: 10px; align-items: stretch; }
    .bm-gpo-col { flex: 0 0 210px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 5px 0; font-size: 13px; max-height: 560px; overflow-y: auto; }
    .bm-gpo-search { display: block; width: 100%; max-width: 440px; margin: 2px 0 10px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 13px; box-sizing: border-box; }
    .bm-cfg-addfile { display: flex; align-items: center; gap: 8px; margin: 0 0 12px; max-width: 640px; }
    .bm-cfg-addfile .bm-addfile-in { flex: 1 1 auto; min-width: 0; }
    .bm-cfg-addkey { display: flex; gap: 8px; margin: 10px 0 0; }
    .bm-gpo-cat { padding: 7px 10px; cursor: pointer; display: flex; align-items: center; gap: 6px; border-left: 3px solid transparent; }
    .bm-gpo-cat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-gpo-cat .bm-gpo-count { margin-left: auto; font-size: 11px; opacity: 0.5; }
    .bm-gpo-cat-ic { font-size: 16px; width: 16px; height: 16px; opacity: 0.8; }
    .bm-gpo-file { padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; display: flex; align-items: center; gap: 6px; }
    .bm-gpo-file:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-gpo-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-gpo-empty { opacity: 0.55; font-size: 12px; padding: 8px 10px; }
    .bm-gpo-main { flex: 1 1 auto; min-width: 0; }
    .bm-gpo-settings { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-gpo-settings th, .bm-gpo-settings td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-gpo-settings tbody tr { cursor: pointer; }
    .bm-gpo-settings tbody tr:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-gpo-key { font-family: ui-monospace, monospace; }
    .bm-row-sel { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-dot-drift { color: var(--bm-warn, #ef6c00); margin-left: 6px; }
    .bm-cfg-gen, .bm-diff { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-cfg-gen th, .bm-cfg-gen td, .bm-diff th, .bm-diff td { text-align: left; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-ebpf-h .bm-dim { opacity: 0.6; font-weight: 400; font-size: 12px; }
  `],
})
export class HostSettingsEditorComponent {
  private agentService = inject(AgentService);
  private orchestration = inject(OrchestrationService);
  private monitoring = inject(MonitoringService);
  private scope = inject(HostConfigScopeService);

  /** The host, by id — the same contract every other Management snap-in has.
   *
   * It used to take the whole Agent plus the services list as inputs, which tied it to a caller that
   * already had both. Fetching them here makes it mountable anywhere an id is known, which is exactly
   * what folding this editor into the Management console required. Sibling snap-ins (host-services,
   * host-storage, …) work the same way; the cost is two small requests the page was making anyway. */
  agentId = input.required<string>();
  /** A file this editor may not write is owned by a snap-in; asking the console to open that snap-in is
   * the page's job, not this pane's. Emitted with the snap-in id (pkg-bind, cron, …). */
  openSnapin = output<string>();

  /** Fetched, not passed: the thresholds pane needs the Agent (for ou_id), and settingService() needs the
   * services to name the unit that owns a config file. */
  agent = signal<Agent | null>(null);
  services = signal<ServiceState[]>([]);

  constructor() {
    // IN AN EFFECT, NOT THE CONSTRUCTOR. A required input is not bound yet in the constructor, so
    // loadObserved()'s `this.agent()` threw NG0950 and the whole editor failed to render — I had written
    // exactly that warning into host-template-edit two slices earlier and then repeated the mistake here.
    // Only the browser catches it; the build is green either way.
    //
    // Keying the effect on agent() also means a re-fetch if the page is ever pointed at another host,
    // instead of showing one machine's configuration under another's name.
    //
    // No "is the Configuration tab open?" guard: this component exists only inside matTabContent, so the
    // boundary IS the guard. The page used to carry that check plus a null test plus a deep-link special
    // case; all three are gone.
    // EVERYTHING INSIDE untracked(), and this is not decoration — without it the effect ran 883 times.
    //
    // An effect depends on every signal it READS. These loads read `agent()` (loadObserved does, to get an
    // id) and `templateIndex()` (the once-only guard), and they also WRITE both. So the first pass set
    // `agent`, which re-triggered the effect, which set it again: a loop that fired 1764 desired-state
    // requests, 883 agent reads and 882 observed-state reads at the server before the browser tooling
    // noticed the DOM never holding still. The build was green and the screen looked fine.
    //
    // untracked() says exactly what is meant: react to the AGENT ID changing, not to what the loads
    // produce. It is the same trap the parent page never had, because there these loads sat in a plain
    // method that nothing re-ran.
    effect(() => {
      const id = this.agentId();
      untracked(() => {
        this.agentService.get(id).subscribe((a) => this.agent.set(a));
        this.monitoring.agentServices(id).subscribe({
          next: (svcs) => this.services.set(svcs),
          error: () => this.services.set([]),
        });
        this.loadConfigCatalogs();
        this.loadObserved(false, id);
        this.loadDesiredMonitoring(id);
        if (!Object.keys(this.templateIndex()).length) {
          // FOR THIS HOST: /etc/caddy/Caddyfile is that path on Debian and on RedHat with different content,
          // so the index must be asked on the host's behalf or it answers with the authoring default (Debian)
          // and would render another distribution's file here.
          this.agentService.configTemplateIndex(id).subscribe({
                next: (res) => {
              this.templateIndex.set(res.paths ?? {});
              this.snapinOwned.set(res.snapins ?? {});
            },
            error: () => { this.templateIndex.set({}); this.snapinOwned.set({}); },
          });
        }
        this.scope.loadGroups();
      });
    });
  }

  observed = signal<ObservedState | null>(null);
  observedLoading = signal(false);
  observedError = signal<string | null>(null);
  observedCachedAt = signal<string | null>(null); // when the served cache was captured (null = just fetched live)
  observedReloadTick = signal(0);   // bumped on every observed read, watched by the generations pane

  // Block K3: drift = the recorded desired config re-planned against the host.
  drift = signal<{
    managed: string[]; drift: StateResourceChange[]; sources?: Record<string, string>;
    desired?: Record<string, Record<string, unknown>>; key_sources?: Record<string, Record<string, string>>;
  }>({ managed: [], drift: [], sources: {} });
  driftBusy = signal(false);

  /** The two host-independent config catalogs (directives ~1.9 MB, codecs ~0.6 MB)
   * are ONLY needed by the Configuration tab's editors, so they are loaded lazily
   * on first open rather than on every host page load — the single biggest chunk
   * of the Host Overview's initial payload. Guarded so it fetches at most once. */
  private configCatalogsLoaded = false;
  private loadConfigCatalogs(): void {
    if (this.configCatalogsLoaded) return;
    this.configCatalogsLoaded = true;
    // ADMX: the per-directive value catalog, so a config setting's editor can
    // offer the real allowed values (enum) instead of guessing a yes/no family.
    this.agentService.configDirectives().subscribe({
      next: (r) => this.directiveCatalog.set(r.directives || {}),
      error: () => { this.configCatalogsLoaded = false; },
    });
    // Host-independent codec catalog: every config file we know how to parse.
    // Lets the operator add a file this host doesn't have yet (e.g. apt.conf)
    // and define it as policy — parity with the OU policy editor (#5).
    this.agentService.configCodecs().subscribe({
      next: (r) => {
        const seen = new Set<string>();
        const files: { path: string; format: string; separator: string }[] = [];
        for (const e of r.entries ?? []) {
          const path = (e.paths ?? []).find((p) => p && !p.includes('*')) ?? e.pattern;
          if (!path || path.includes('*') || seen.has(path)) continue;
          seen.add(path);
          files.push({ path, format: e.codec === 'none' ? 'keyvalue' : e.codec, separator: e.separator ?? '' });
        }
        this.codecCatalog.set(files);
      },
      error: () => {},
    });
  }

  /** Block F1 — the server-as-a-document read. Live agent pull (slow-ish), so
   * loaded lazily when the Configuration tab is first opened. */
  /** `agentId` is passed in by the constructor's effect and defaults to the input otherwise.
   *
   * It used to read the fetched `agent()` signal for its id — which made every caller a dependency of a
   * signal this component also writes, and that is what turned the load into an 883-iteration loop. An id
   * is all this needs, and taking it as an argument also means the first read does not wait for the
   * agent fetch to land. */
  loadObserved(refresh = false, agentId?: string): void {
    const id = agentId ?? this.agentId();
    if (!id) return;
    const agent = { id };
    this.observedLoading.set(true);
    this.observedError.set(null);
    // The generations pane discards its rollback preview on this tick: a dry-run diff computed against
    // the PREVIOUS observed read must not stay on screen looking authoritative.
    this.observedReloadTick.update((n) => n + 1);
    // Default open = the Postgres cache (instant); Reload = live re-fetch.
    //
    // EVERY CALLER THAT JUST WROTE PASSES refresh=true. Caught by testing this for real: applying
    // PermitRootLogin and then un-managing it left the row reading `prohibit-password` while the file on
    // the host said `yes` — the post-write reload had re-read a cache older than the write. A view that
    // contradicts the machine it describes is worse than a slow one, and the extra live pull is paid
    // exactly once, at the moment something changed.
    this.agentService.observedState(agent.id, refresh).subscribe({
      next: (res) => {
        this.observed.set(res.observed);
        this.observedCachedAt.set((res as { cached_at?: string }).cached_at ?? null);
        this.observedLoading.set(false);
      },
      error: (e) => {
        this.observedError.set(e?.error?.detail ?? 'could not read observed state');
        this.observedLoading.set(false);
      },
    });
    // Generation history now belongs to app-host-config-generations, which fetches it itself — this
    // call's own comment already said it was independent of the observed read.
    // path→template index (Block K2). Was configTemplates(), which downloads every template BODY —
    // 33.7 MB across 5460 dirs — to answer "does this path have a template". This is 229 kB of pairs,
    // and the body is fetched only when an editor is opened.
    if (!Object.keys(this.templateIndex()).length) {
      // Same reason as the other call site: on a host, the index must be asked FOR that host, or a path that
      // exists on both families resolves to the authoring default.
      this.agentService.configTemplateIndex(agent.id).subscribe({
        next: (res) => this.templateIndex.set(res.paths ?? {}),
        error: () => this.templateIndex.set({}),
      });
    }
    // Drift: desired (Bossman DB) vs observed (Block K3).
    this.agentService.configDrift(agent.id).subscribe({
      next: (res) => this.drift.set(res),
      error: () => this.drift.set({ managed: [], drift: [] }),
    });
    // Thresholds + applied plans for the GPO categories (Block G).
    this.loadDesiredMonitoring();
    // Host groups for the apply-to-group scope (Block K4). All groups are
    // offered — targeting a group the host isn't in still creates the policy +
    // converges that group's members (agents.groups can lag the membership
    // table, so we don't filter by it).
    this.scope.loadGroups();
  }

  // ---- Block G: GPO-style settings editor (gpedit model: category tree left,
  // settings list right, per-setting Not configured / Configured / Removed) ----
  selectedPane = signal<string>('::thresholds');
  selectPane(p: string): void {
    this.selectedPane.set(p);
    this.closeSetting();
    // No cancelEdit() here any more: the raw editor is app-host-file-edit, which sits inside the pane
    // and is DESTROYED when the pane changes — its open/dirty state goes with it. Same reasoning as the
    // thresholds note below; a parent reaching in to reset a child's state was only necessary while
    // they shared a class.
    this.cancelTemplateEdit();
    // No threshold reset here any more: the pane lives behind @if (selectedPane() === '::thresholds'),
    // so switching pane DESTROYS it and its state goes with it. Resetting a child's signal from the
    // parent was only ever necessary while they shared a class.
    this.configView.set('editor');   // each file opens in the scope-aware editor
  }

  // Per config file: the scope-aware Settings editor (default) or the generic
  // config ResourceNode ("Resource view", host-direct state + generations). The
  // node COMPLEMENTS the editor — it doesn't replace scope/policy/removed/restart.
  configView = signal<'editor' | 'resource'>('editor');

  // gpedit Miller columns: category (col 1) → its items (col 2) → pane (col 3).
  // Monitoring + Policies are pseudo-categories; the rest are config-file
  // categories from categoryGroups().
  gpoActiveCat = signal<string>('::mon');
  selectGpoCat(key: string): void { this.gpoActiveCat.set(key); }

  // Drift diff: the banner can expand to show every drifted file + its
  // key-level live→desired changes, and jump to a file in the Miller view.
  jumpToFile(path: string): void {
    this.gpoSearch.set('');
    this.gpoActiveCat.set(categorizeConfigPath(path).key);
    this.selectPane(path);
  }

  gpoCategories(obs: ObservedState): { key: string; label: string; icon: string; count: number }[] {
    const cats: { key: string; label: string; icon: string; count: number }[] = [
      // Policies and Variables MOVED to the Management tab's Miller list (management/host-policies,
      // management/host-variables). They are not config files, and this list's categories are
      // config-file categories — keeping them here made "category" mean two things. Removed rather
      // than left in place: a second copy in the same product is how one of the two starts to rot.
      { key: '::mon', label: 'Monitoring', icon: 'speed', count: this.thresholds().length },
    ];
    for (const g of this.categoryGroups(obs)) {
      cats.push({ key: g.cat.key, label: g.cat.label, icon: g.cat.icon, count: g.files.length });
    }
    return cats;
  }

  gpoColItems(obs: ObservedState): { pane: string; label: string; title: string; drift: boolean }[] {
    const cat = this.gpoActiveCat();
    if (cat === '::mon') return [{ pane: '::thresholds', label: 'Thresholds', title: 'Monitoring thresholds', drift: false }];

    const grp = this.categoryGroups(obs).find((g) => g.cat.key === cat);
    return (grp?.files ?? []).map((f) => ({ pane: f.path, label: this.baseName(f.path), title: f.path, drift: !!this.driftFor(f.path) }));
  }
  baseName(p: string): string {
    return p.split('/').pop() || p;
  }
  /** gpedit live search: filters the category tree by file path OR any
   * setting key inside the file (searching "PermitRoot" surfaces sshd_config
   * under Security even though the filename doesn't match). */
  gpoSearch = signal('');
  categoryGroups(obs: ObservedState): { cat: ConfigCategory; files: ObservedResource[] }[] {
    const q = this.gpoSearch().trim().toLowerCase();
    const all = this.allConfig(obs);
    const files = !q
      ? all
      : all.filter(
          (r) =>
            r.path.toLowerCase().includes(q) ||
            this.flatKeys(r).some((k) => k.toLowerCase().includes(q)),
        );
    return groupByCategory(files);
  }
  private flatKeys(r: ObservedResource): string[] {
    const flat = r.format === 'keyvalue' ? Object.entries(r.values ?? {}) : this.flatten(r.values ?? {});
    return flat.map(([k]) => k);
  }
  selRes(obs: ObservedState): ObservedResource | null {
    return this.allConfig(obs).find((r) => r.path === this.selectedPane()) ?? null;
  }

  /** The settings list narrowed by the live search: when the query matched
   * the file by a KEY (not its path), only the matching keys are shown, so
   * searching "PermitRoot" jumps straight to the setting. */
  filteredSettingRows(r: ObservedResource): { key: string; state: string; desired: string; live: string; source: string | null }[] {
    const rows = this.settingRows(r);
    const q = this.gpoSearch().trim().toLowerCase();
    if (!q || r.path.toLowerCase().includes(q)) return rows;
    const hit = rows.filter((row) => row.key.toLowerCase().includes(q));
    return hit.length ? hit : rows;
  }

  /** Setting rows for a codec'd file: the union of live keys and desired keys.
   * State per key: Configured (managed with a value), Removed (managed null =
   * enforced absent), Not configured (live only, unmanaged). */
  settingRows(r: ObservedResource): { key: string; state: string; desired: string; live: string; source: string | null }[] {
    const desired = this.drift().desired?.[r.path] ?? {};
    const srcs = this.drift().key_sources?.[r.path] ?? {};
    const flat = (v: Record<string, unknown> | undefined) =>
      r.format === 'keyvalue' ? Object.entries(v ?? {}) : this.flatten(v ?? {});
    const live = new Map(flat(r.values));
    const des = new Map(flat(desired));
    // Union in the file's known ADMX directives so every settable key shows as
    // a row (configured or not) — like the Group Policy Editor lists all known
    // settings, not just the ones already present in the file.
    const specs = this.specsForPath(r.path);
    const keys = [...new Set([...live.keys(), ...des.keys(), ...Object.keys(specs)])].sort();
    return keys.map((key) => {
      const managed = des.has(key);
      const dv = des.get(key);
      return {
        key,
        state: managed ? (dv === null ? 'Removed' : 'Configured') : 'Host based',
        desired: dv === null || dv === undefined ? '' : scalarText(dv),
        // Unmanaged key: the host's live value, or the directive default as a hint.
        live: live.has(key) ? scalarText(live.get(key)) : scalarText(specs[key]?.default ?? ''),
        // A managed key is sourced from the GPO scope it won at (Host/Group/OU/
        // Default *policy*); an unmanaged key is just the host's own baseline
        // value → "Host". So policy-set settings read as a policy, and the
        // host's own values read as "Host".
        source: managed ? this.sourceLabel(srcs[key]) : 'Host',
      };
    });
  }

  /** Human GPO-scope label for a config key's winning source. */
  sourceLabel(scope: string | null | undefined): string {
    switch (scope) {
      case 'host': return 'Host policy';
      case 'group': return 'Group policy';
      case 'ou': return 'OU policy';
      case 'global': return 'Default policy';
      default: return scope || 'Policy';
    }
  }
  private flatten(v: Record<string, unknown>, prefix = ''): [string, unknown][] {
    const out: [string, unknown][] = [];
    for (const [k, val] of Object.entries(v)) {
      const key = prefix ? `${prefix}.${k}` : k;
      if (val !== null && typeof val === 'object' && !Array.isArray(val)) out.push(...this.flatten(val as Record<string, unknown>, key));
      else out.push([key, val]);
    }
    return out;
  }

  /** The row whose policy dialog is open, or null. The MODE, value, busy and error state live in
   * app-host-setting-dialog with the write itself — the page's only stake is which row is open, because
   * that decides whether the dialog renders and which row is highlighted. */
  settingRow = signal<{ key: string; state: string; desired: string; live: string } | null>(null);
  /** For the row highlight in the settings table. */
  settingKey(): string | null {
    return this.settingRow()?.key ?? null;
  }
  openSetting(_r: ObservedResource, row: { key: string; state: string; desired: string; live: string }): void {
    this.settingRow.set(row);
  }
  closeSetting(): void {
    this.settingRow.set(null);
  }

  /** ADMX per-directive value catalog ({file: {directive: spec}}), loaded once. */
  directiveCatalog = signal<Record<string, Record<string, DirectiveSpec>>>({});

  /** ADMX directive specs for a file. config_directives.json is keyed by FULL
   * path (e.g. /etc/apt/apt.conf.d/…); basename is a legacy fallback. Keying by
   * basename alone (the old bug) missed every full-path entry, so settings fell
   * back to a generic text input instead of the enum/bool/int field the catalog
   * defines — the same bug that was fixed in the OU policy editor. */
  private specsForPath(path: string): Record<string, DirectiveSpec> {
    const cat = this.directiveCatalog();
    const base = (path || '').split('/').pop() || '';
    return cat[path] ?? cat[base] ?? {};
  }

  /** The mined spec for one key of one file, or null when the catalog does not know it.
   *
   * Was directiveSpec(r), which took the resource and read the open key off the component — a function
   * whose answer depended on hidden state. Now both arguments are named, which is also what let the
   * dialog take its spec as an input. */
  specFor(path: string, key: string): DirectiveSpec | null {
    return this.specsForPath(path)[key] ?? null;
  }

  /** The systemd service that owns a config path, from the observed-state
   * discovery (service -> config_paths). Lets the Apply button also restart the
   * right unit so the change takes effect. Null when no service claims it. */
  settingService(path: string): string | null {
    const svcs = (this.observed()?.services as { service: string; config_paths?: string[] }[] | undefined) ?? [];
    const hit = svcs.find((s) => (s.config_paths ?? []).includes(path));
    return hit ? hit.service.replace(/@$/, '') : null; // strip template unit suffix (getty@)
  }

  // #5 — reach a config file the host doesn't have yet. The codec catalog lists
  // every known file; picking one injects a synthetic (empty) resource so the
  // existing settings editor + Apply path can define it as desired config at
  // host/OU/group scope (stateApply doesn't require the file to pre-exist).
  codecCatalog = signal<{ path: string; format: string; separator: string }[]>([]);
  extraConfigFiles = signal<ObservedResource[]>([]);
  addFilePath = signal('');

  /** Observed files ∪ catalog files the operator added (dedup by path). */
  private allConfig(obs: ObservedState): ObservedResource[] {
    const extra = this.extraConfigFiles().filter((e) => !obs.config.some((c) => c.path === e.path));
    return [...obs.config, ...extra];
  }

  /** Catalog paths not already shown, for the "add a file" datalist. */
  catalogAddOptions(): string[] {
    const have = new Set<string>([
      ...(this.observed()?.config ?? []).map((c) => c.path),
      ...this.extraConfigFiles().map((c) => c.path),
    ]);
    return this.codecCatalog().map((e) => e.path).filter((p) => !have.has(p));
  }

  addCatalogFile(path: string): void {
    const p = (path || '').trim();
    if (!p) return;
    this.addFilePath.set('');
    const obs = this.observed();
    const present = (obs?.config ?? []).some((c) => c.path === p) || this.extraConfigFiles().some((c) => c.path === p);
    if (!present) {
      const cat = this.codecCatalog().find((e) => e.path === p);
      const res = { path: p, format: cat?.format || 'keyvalue', separator: cat?.separator || '=', values: {} } as ObservedResource;
      this.extraConfigFiles.update((xs) => [...xs, res]);
    }
    if (obs) {
      const grp = this.categoryGroups(obs).find((g) => g.files.some((f) => f.path === p));
      if (grp) this.gpoActiveCat.set(grp.cat.key);
    }
    this.selectPane(p);
  }

  // Add an arbitrary setting key to the selected file (for files with no mined
  // directives, or a key the catalog doesn't list) — mirrors the OU editor.
  newSettingKey = signal('');
  addSettingKey(r: ObservedResource): void {
    const k = this.newSettingKey().trim();
    if (!k) return;
    this.newSettingKey.set('');
    this.openSetting(r, { key: k, state: 'Host based', desired: '', live: '' });
  }

  // Thresholds category (check_rules as GPO settings) + applied plans.
  thresholds = signal<{ metric: string; service_name?: string; warn?: number | null; crit?: number | null; comparison?: string; source?: string }[]>([]);
  // The desired-state sub-tab moved to management/host-desired-state.component, which fetches its own
  // document — and took the lazy-load handler with it: matTabContent does not construct a component
  // until its tab is opened, so the boundary already says "not until someone looks".

  loadDesiredMonitoring(agentId?: string): void {
    const id = agentId ?? this.agentId();
    if (!id) return;
    const agent = { id };
    this.orchestration.desiredState(agent.id).subscribe({
      next: (d) => {
        const t = (d.state.monitoring.thresholds ?? {}) as Record<string, { service_name?: string; warn?: number; crit?: number; comparison?: string; source?: string }>;
        this.thresholds.set(Object.entries(t).map(([metric, v]) => ({ metric, ...v })));
      },
      error: () => this.thresholds.set([]),
    });
  }


  isManaged(path: string): boolean {
    return this.drift().managed.includes(path);
  }
  driftFor(path: string): StateResourceChange | null {
    return this.drift().drift.find((c) => c.path === path) ?? null;
  }
  /** Per-key drift rows for a managed file that has drifted — the same derivation the drift banner uses,
   * from management/drift-rows.ts. It was a method here that both the banner and the per-file table
   * called; the direction (live vs desired, which a plan diff records the other way round) is easy to
   * invert, so it exists once. */
  driftRows(path: string): { key: string; desired: string; live: string }[] {
    // ALIASED IMPORT on purpose: a bare `driftRows(...)` here resolves to the import, but the method has
    // the same name, so anyone "tidying" it to this.driftRows() would get silent infinite recursion that
    // compiles. Same shape as the cache-key shadowing found earlier this session.
    return driftRowsOf(this.driftFor(path));
  }

  /** Re-sync the whole host to its recorded desired config (converge drift). */
  reapplyConfig(): void {
    const agent = this.agent();
    if (!agent) return;
    this.driftBusy.set(true);
    this.agentService.reapplyConfig(agent.id).subscribe({
      next: () => {
        this.driftBusy.set(false);
        this.loadObserved(true);   // we just rewrote the host; the cached read predates it
      },
      error: () => this.driftBusy.set(false),
    });
  }

  // --- Block K2: bind a discovered file to a Class-B template + edit via a
  // schema-driven form (opt-in; a file with neither codec nor template falls back
  // to the raw whole-file editor in app-host-file-edit) ---

  /** path → template, from GET /config-templates/index. */
  templateIndex = signal<Record<string, ConfigTemplateIndexEntry>>({});
  /** Files a snap-in owns. Consulted for paths that have NO template, so a file the interface module fills
   * (/etc/network/interfaces) still names its owner instead of showing nothing. */
  snapinOwned = signal<Record<string, { snapin: string; snapin_label: string; snapin_exclusive: boolean }>>({});

  /** Which template renders THIS file — an index lookup, not a name guess.
   *
   * It used to take the basename minus .conf and look for a template of that name. That is inference
   * from name similarity, and it was wrong on real data: /etc/aardvark-dns/aardvark-dns.conf resolved
   * to the template dir `aardvark-dns`, which renders /etc/aardvark-dns/forward.conf — a different
   * file of the same package. Configure writes the WHOLE file with no merge, so the button would have
   * written one file's content over another.
   *
   * null now means "no template claims this path", and the button is simply absent. That is the right
   * direction: an editor that cannot be correct is not offered, rather than offered and regretted. */
  templateFor(path: string): ConfigTemplateIndexEntry | null {
    const hit = this.templateIndex()[path];
    if (hit) return hit;
    // No template renders it, but a snap-in may still own it — /etc/network/interfaces is filled by the
    // agent's interface module. Returning a template-less entry lets the row say who is in charge with
    // one code path instead of two.
    const owned = this.snapinOwned()[path];
    return owned ? { template: null, source: 'snapin', ...owned } : null;
  }

  /** Why this file has a template editor, in the button's tooltip. A claim the user cannot trace is a
   * claim they have to take on faith. */
  templateReason(e: ConfigTemplateIndexEntry): string {
    return e.source === 'catalog'
      ? `rendered by template "${e.template}" — declared as the config file of role ${e.role}`
      : `rendered by template "${e.template}" — this path is listed in the codec registry`;
  }

  /** Which file's template editor is open, and under which template name.
   *
   * That is ALL the page keeps. The schema, sample, rendered text, busy and error state moved into
   * app-host-template-edit together with the fetch — the page's only remaining stake is "is the editor
   * open, and for what", because that decides which branch of the pane renders.
   */
  tplEditPath = signal<string | null>(null);
  tplName = signal('');

  /** Open the template editor for this file.
   *
   * It no longer FETCHES here. The child fetches its own template and shows "Loading template X…" while
   * it does, so a slow or failing fetch is reported where the editor would be rather than as an error
   * beside a button that appears to have done nothing. The earlier version deliberately delayed opening
   * until the fetch succeeded, to avoid showing an empty form; a pane that says what it is waiting for
   * achieves that without the page having to own the request.
   */
  startTemplateEdit(r: { path: string }, entry: ConfigTemplateIndexEntry): void {
    // An index entry may name NO template: a path owned by a snap-in is carried so the UI can point at the
    // snap-in, and there is nothing to render from. The button is already hidden in that case; refusing
    // here too means a future caller cannot open an editor with no template behind it.
    if (!entry.template) return;
    this.tplName.set(entry.template);
    this.tplEditPath.set(r.path);
  }

  cancelTemplateEdit(): void {
    this.tplEditPath.set(null);
  }
}
