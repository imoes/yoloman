import { Component, computed, inject, input, signal } from '@angular/core';
import { NgTemplateOutlet } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { CdkMenu, CdkMenuItem, CdkContextMenuTrigger } from '@angular/cdk/menu';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../../shared/param-form/param-form.types';
import { WebServerProfile } from './web-server-profiles';

interface Site { name: string; file: string; enabled: boolean; }

/** One flattened tree row. kinds mirror IIS Manager: the server root, the Sites container, a Site, its
 *  Bindings / www root / Locations feature nodes, and a Certificates container with cert files. */
type NodeKind = 'server' | 'sites' | 'site' | 'bindings' | 'wwwroot' | 'locations' | 'certs' | 'cert';
interface Row { id: string; kind: NodeKind; label: string; icon: string; depth: number; expandable: boolean; expanded: boolean; site?: string; cert?: string; }

/**
 * IIS-Manager-style web-server config tree (docs/web-config-tree.md). One component, driven by a
 * WebServerProfile, renders a per-endpoint tree — Server → Sites → Site → (Bindings / www root / Locations),
 * plus a Certificates node — with a right-click context menu (Add Website, Edit Bindings, Add Location, Set
 * www root, Manage, Add Certificate) exactly like the OU/policy tree. Selecting a node shows its Features
 * pane: a schema-driven form (the vhost template's values) filtered to that node's setting group. A site is
 * the vhost template rendered from its values into its own file + a JSON sidecar, applied via state/apply,
 * then validated (e.g. `nginx -t`) and reloaded — the same idiom as the flat nginx-sites panel, reorganised
 * as a tree. Certificates are file-based: cert files found on the host, referenced by a site's TLS binding.
 */
@Component({
  selector: 'app-web-config-tree',
  standalone: true,
  imports: [NgTemplateOutlet, FormsModule, CdkMenu, CdkMenuItem, CdkContextMenuTrigger, MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="wt">
      @if (loading()) { <p class="bm-dim">Loading {{ profile().label }} configuration…</p> }
      @else {
        <div class="wt-cols">
          <!-- ── Connections tree (left), right-click for the Actions menu ── -->
          <aside class="wt-tree">
            @for (row of rows(); track row.id) {
              <div class="wt-node" [class.sel]="selectedId() === row.id" [style.paddingLeft.px]="6 + row.depth * 16"
                   (click)="select(row)"
                   [cdkContextMenuTriggerFor]="nodeMenu" (contextmenu)="ctx.set(row)">
                <span class="wt-twisty" (click)="toggle(row); $event.stopPropagation()">{{ row.expandable ? (row.expanded ? '▾' : '▸') : '·' }}</span>
                <mat-icon class="wt-ic">{{ row.icon }}</mat-icon>
                <span class="wt-label">{{ row.label }}</span>
              </div>
            }
          </aside>

          <!-- ── Features / detail pane (right) ── -->
          <section class="wt-main">
            @switch (selected()?.kind) {
              @case ('server') { <ng-container *ngTemplateOutlet="serverPane"></ng-container> }
              @case ('sites')  { <ng-container *ngTemplateOutlet="serverPane"></ng-container> }
              @case ('certs')  { <ng-container *ngTemplateOutlet="certsPane"></ng-container> }
              @case ('cert')   { <ng-container *ngTemplateOutlet="certPane"></ng-container> }
              @default {
                @if (currentSite(); as s) { <ng-container *ngTemplateOutlet="sitePane; context: { $implicit: s }"></ng-container> }
                @else { <p class="bm-dim">Select a node. Right-click <strong>Sites</strong> to add a website.</p> }
              }
            }
          </section>
        </div>
      }
      @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }
    </div>

    <!-- ── Feature panes ─────────────────────────────────────────────── -->
    <ng-template #serverPane>
      <h3>{{ profile().label }} <span class="bm-dim">· {{ agentId() }}</span></h3>
      <p class="bm-dim">{{ sites().length }} site(s), {{ certs().length }} certificate(s). Right-click
        <strong>Sites</strong> → <em>Add Website</em> to create one.</p>
      <button mat-stroked-button (click)="openAddSite()"><mat-icon>add</mat-icon> Add Website</button>
      <div class="wt-features">
        @for (s of sites(); track s.file) {
          <button class="wt-feat" (click)="selectSiteByName(s.name)"><mat-icon>{{ s.enabled ? 'public' : 'public_off' }}</mat-icon> {{ s.name }}</button>
        }
      </div>
    </ng-template>

    <ng-template #sitePane let-s>
      <h3>{{ s.name }} <span class="bm-dim">· {{ s.file }} · {{ paneTitle() }}</span></h3>
      @if (raw() !== null) {
        <p class="bm-dim">Hand-written site (no stored values) — read-only.</p>
        <pre class="wt-raw">{{ raw() }}</pre>
      } @else if (paneSchema(); as sch) {
        <app-param-form [params]="sch" [initial]="values()" [agentId]="agentId()" (valuesChange)="onValues($event)" />
        <div class="wt-actions">
          <label class="wt-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-button (click)="testConfig()" [disabled]="busy()">Test config</button>
          <button mat-raised-button color="primary" (click)="save(s)" [disabled]="busy()">{{ dryRun() ? 'Preview + validate' : 'Save + reload' }}</button>
        </div>
      }
    </ng-template>

    <ng-template #certsPane>
      <h3>Certificates <span class="bm-dim">· {{ agentId() }}</span></h3>
      <p class="bm-dim">Certificate files found on this host. Right-click <strong>Certificates</strong> →
        <em>Add Certificate</em> to register a path for use in a site's HTTPS binding.</p>
      <button mat-stroked-button (click)="openAddCert()"><mat-icon>add</mat-icon> Add Certificate</button>
      <div class="wt-features">
        @for (c of certs(); track c) { <div class="wt-feat"><mat-icon>verified_user</mat-icon> {{ c }}</div> }
        @if (!certs().length) { <p class="bm-dim">None found under {{ profile().certSearchDirs.join(', ') }}.</p> }
      </div>
    </ng-template>

    <ng-template #certPane>
      <h3>{{ selected()?.cert }}</h3>
      <p class="bm-dim">Certificate file on this host. Select a site's <strong>Bindings</strong> and enable
        HTTPS to reference it as the SSL certificate.</p>
    </ng-template>

    <!-- ── Context menu (Actions), IIS-faithful — one menu, items chosen by the right-clicked node kind ── -->
    <ng-template #nodeMenu><div class="wt-menu" cdkMenu>
      @switch (ctx()?.kind) {
        @case ('server') { <button class="wt-mi" cdkMenuItem (click)="openAddSite()">Add Website…</button> }
        @case ('sites')  { <button class="wt-mi" cdkMenuItem (click)="openAddSite()">Add Website…</button> }
        @case ('site') {
          <button class="wt-mi" cdkMenuItem (click)="selectChild('bindings')">Edit Bindings…</button>
          <button class="wt-mi" cdkMenuItem (click)="selectChild('wwwroot')">Set www root…</button>
          @if (profile().locationsList) {
            <button class="wt-mi" cdkMenuItem (click)="addLocation()">Add Location / Virtual Directory…</button>
          }
          <div class="wt-sep"></div>
          <button class="wt-mi" cdkMenuItem (click)="testConfig()">Test config</button>
          <button class="wt-mi" cdkMenuItem (click)="reloadServer()">Reload {{ profile().service }}</button>
          <div class="wt-sep"></div>
          <button class="wt-mi wt-danger" cdkMenuItem (click)="removeSite()">Remove</button>
        }
        @case ('certs') { <button class="wt-mi" cdkMenuItem (click)="openAddCert()">Add Certificate…</button> }
        @default { <button class="wt-mi" cdkMenuItem disabled>(no actions)</button> }
      }
    </div></ng-template>

    <!-- ── Add Website dialog (name / www root / binding / certificate) ── -->
    @if (adding()) {
      <div class="wt-modal" (click)="adding.set(false)">
        <div class="wt-dialog" (click)="$event.stopPropagation()">
          <h3>Add Website</h3>
          <label class="wt-fld"><span>Site name (host)</span><input class="bm-in" [(ngModel)]="newSite.name" placeholder="example.com" /></label>
          <label class="wt-fld"><span>Physical path (www root)</span><input class="bm-in" [(ngModel)]="newSite.root" placeholder="/var/www/example.com" /></label>
          <div class="wt-row">
            <label class="wt-fld"><span>Binding</span>
              <select class="bm-in" [(ngModel)]="newSite.https">
                <option [ngValue]="false">http</option>
                <option [ngValue]="true">https</option>
              </select></label>
            <label class="wt-fld"><span>Port</span><input class="bm-in" type="number" [(ngModel)]="newSite.port" /></label>
          </div>
          @if (newSite.https) {
            <label class="wt-fld"><span>SSL certificate</span>
              <select class="bm-in" [(ngModel)]="newSite.cert">
                <option value="">— none —</option>
                @for (c of certs(); track c) { <option [value]="c">{{ c }}</option> }
              </select></label>
            <label class="wt-fld"><span>SSL certificate key</span><input class="bm-in" [(ngModel)]="newSite.certKey" placeholder="/etc/ssl/private/example.key" /></label>
          }
          <div class="wt-actions">
            <button mat-button (click)="adding.set(false)">Cancel</button>
            <button mat-raised-button color="primary" (click)="createSite()" [disabled]="!newSite.name.trim()">Create</button>
          </div>
        </div>
      </div>
    }

    <!-- ── Add Certificate dialog (register a found path) ── -->
    @if (addingCert()) {
      <div class="wt-modal" (click)="addingCert.set(false)">
        <div class="wt-dialog" (click)="$event.stopPropagation()">
          <h3>Add Certificate</h3>
          <p class="bm-dim">Register a certificate file path on this host so a site's HTTPS binding can use it.</p>
          <label class="wt-fld"><span>Certificate path</span><input class="bm-in" [(ngModel)]="newCertPath" placeholder="/etc/letsencrypt/live/example.com/fullchain.pem" /></label>
          <div class="wt-actions">
            <button mat-button (click)="addingCert.set(false)">Cancel</button>
            <button mat-raised-button color="primary" (click)="addCert()" [disabled]="!newCertPath.trim()">Add</button>
          </div>
        </div>
      </div>
    }
  `,
  styles: [`
    .wt-cols { display: grid; grid-template-columns: 300px 1fr; gap: 16px; align-items: start; }
    .wt-tree { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; max-height: 560px; overflow: auto; }
    .wt-node { display: flex; align-items: center; gap: 6px; padding: 4px 6px; border-radius: 6px; cursor: pointer; font-size: 13px; white-space: nowrap; }
    .wt-node:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .wt-node.sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); font-weight: 600; }
    .wt-twisty { width: 12px; display: inline-flex; justify-content: center; opacity: 0.7; }
    .wt-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.8; }
    .wt-label { overflow: hidden; text-overflow: ellipsis; }
    .wt-main h3 { margin: 0 0 6px; font-size: 15px; }
    .wt-features { display: flex; flex-direction: column; gap: 2px; margin-top: 10px; }
    .wt-feat { display: flex; align-items: center; gap: 8px; border: 0; background: transparent; color: inherit; cursor: pointer; padding: 5px 7px; border-radius: 6px; font-size: 13px; text-align: left; }
    .wt-feat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .wt-feat mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.75; }
    .wt-actions { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
    .wt-tog { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .wt-raw { max-height: 320px; overflow: auto; background: var(--mat-sys-surface-container, #1a1a1a); padding: 10px 12px; border-radius: 8px; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre; }
    .wt-menu { background: var(--mat-sys-surface-container, #262626); border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; min-width: 210px; box-shadow: 0 6px 24px rgba(0,0,0,.35); }
    .wt-mi { display: block; width: 100%; text-align: left; border: 0; background: transparent; color: inherit; cursor: pointer; padding: 7px 10px; border-radius: 6px; font-size: 13px; }
    .wt-mi:hover { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .wt-danger { color: var(--mat-sys-error, #c62828); }
    .wt-sep { height: 1px; background: var(--mat-sys-outline-variant); margin: 4px 6px; }
    .wt-modal { position: fixed; inset: 0; background: rgba(0,0,0,.4); display: flex; align-items: center; justify-content: center; z-index: 1000; }
    .wt-dialog { background: var(--mat-sys-surface, #1e1e1e); border-radius: 12px; padding: 18px 20px; width: min(460px, 92vw); box-shadow: 0 10px 40px rgba(0,0,0,.5); }
    .wt-dialog h3 { margin: 0 0 12px; }
    .wt-fld { display: flex; flex-direction: column; gap: 3px; margin-bottom: 10px; font-size: 13px; }
    .wt-row { display: flex; gap: 10px; } .wt-row .wt-fld { flex: 1; }
    .bm-in { width: 100%; box-sizing: border-box; padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class WebConfigTreeComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  profile = input.required<WebServerProfile>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  confdLayout = signal(false);

  sites = signal<Site[]>([]);
  certs = signal<string[]>([]);
  expanded = signal<Set<string>>(new Set(['server', 'sites', 'certs']));
  selectedId = signal<string>('server');
  ctx = signal<Row | null>(null);

  // current site editing state
  schema = signal<ParamSchema | null>(null);
  values = signal<Record<string, unknown>>({});
  raw = signal<string | null>(null);
  private tplBody = '';

  // dialogs
  adding = signal(false);
  addingCert = signal(false);
  newSite = { name: '', root: '', https: false, port: 80, cert: '', certKey: '' };
  newCertPath = '';

  // ── tree model ──────────────────────────────────────────────────────
  rows = computed<Row[]>(() => {
    const exp = this.expanded();
    const out: Row[] = [];
    out.push({ id: 'server', kind: 'server', label: this.profile().label, icon: 'dns', depth: 0, expandable: true, expanded: exp.has('server') });
    if (!exp.has('server')) return out;
    out.push({ id: 'sites', kind: 'sites', label: 'Sites', icon: 'folder', depth: 1, expandable: this.sites().length > 0, expanded: exp.has('sites') });
    if (exp.has('sites')) {
      for (const s of this.sites()) {
        const sid = 'site:' + s.name;
        out.push({ id: sid, kind: 'site', label: s.name, icon: s.enabled ? 'public' : 'public_off', depth: 2, expandable: true, expanded: exp.has(sid), site: s.name });
        if (exp.has(sid)) {
          out.push({ id: sid + '/bindings', kind: 'bindings', label: 'Bindings', icon: 'lan', depth: 3, expandable: false, expanded: false, site: s.name });
          out.push({ id: sid + '/wwwroot', kind: 'wwwroot', label: 'www root', icon: 'home', depth: 3, expandable: false, expanded: false, site: s.name });
          out.push({ id: sid + '/locations', kind: 'locations', label: 'Locations', icon: 'account_tree', depth: 3, expandable: false, expanded: false, site: s.name });
        }
      }
    }
    out.push({ id: 'certs', kind: 'certs', label: 'Certificates', icon: 'verified_user', depth: 1, expandable: this.certs().length > 0, expanded: exp.has('certs') });
    if (exp.has('certs')) {
      for (const c of this.certs()) out.push({ id: 'cert:' + c, kind: 'cert', label: c.split('/').pop() || c, icon: 'lock', depth: 2, expandable: false, expanded: false, cert: c });
    }
    return out;
  });

  selected = computed<Row | null>(() => this.rows().find((r) => r.id === this.selectedId()) ?? null);
  currentSite = computed<Site | null>(() => {
    const name = this.selected()?.site;
    return name ? (this.sites().find((s) => s.name === name) ?? null) : null;
  });
  /** The schema shown in the current pane — filtered to the node's feature group, or the whole schema. */
  paneSchema = computed<ParamSchema | null>(() => {
    const full = this.schema(); const kind = this.selected()?.kind;
    if (!full) return null;
    const group = kind && this.profile().featureGroups[kind];
    if (!group) return full;   // 'site' node → all settings
    return Object.fromEntries(Object.entries(full).filter(([k]) => group.includes(k))) as ParamSchema;
  });
  paneTitle = computed(() => {
    switch (this.selected()?.kind) {
      case 'bindings': return 'Bindings';
      case 'wwwroot': return 'www root';
      case 'locations': return 'Locations';
      default: return 'All settings';
    }
  });

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  private dir(): string { return this.confdLayout() ? this.profile().confdDir : this.profile().sitesDir; }
  private base(p: string): string { return p.replace(/\/+$/, '').split('/').pop() || p; }
  /** display/site name = file basename with the profile's suffix stripped ('' nginx, '.conf' apache). */
  private siteName(file: string): string {
    const b = this.base(file); const suf = this.profile().fileSuffix;
    return suf && b.endsWith(suf) ? b.slice(0, -suf.length) : b;
  }
  private sidecar(name: string): string { return `${this.profile().sidecarDir}/${name}.json`; }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    const p = this.profile();
    // Critical path ONLY: the vhost template (→ schema/tplBody) + the site list. Certificate discovery is
    // best-effort and runs separately, so a missing cert dir can never abort the whole load.
    forkJoin({
      tpl: this.agentService.configTemplate(p.vhostTemplate),
      avail: this.agentService.callTool(this.agentId(), 'find',
        p.sitesPattern ? { paths: [p.sitesDir], file_type: 'file', pattern: p.sitesPattern } : { paths: [p.sitesDir], file_type: 'file' }),
    }).subscribe({
      next: ({ tpl: { tpl, missing }, avail }) => {
        if (missing) this.err.set(missing);
        this.tplBody = tpl?.template || '';
        if (tpl?.schema) this.schema.set(tpl.schema as ParamSchema);
        const availList = ((avail.result as { data?: { path: string }[] })?.data) || [];
        if (availList.length) { this.confdLayout.set(false); this.finishReload(availList.map((e) => e.path)); }
        else { this.detectConfd(); }
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
    this.loadCerts();
  }

  /** Best-effort certificate discovery (file-based). Tolerant: a missing search dir yields no error. */
  private loadCerts(): void {
    const p = this.profile();
    const paths = (resp: unknown) => ((resp as { result?: { data?: { path: string }[] } })?.result?.data || []).map((e) => e.path);
    this.agentService.callTool(this.agentId(), 'find', { paths: p.certSearchDirs, file_type: 'file', pattern: '*.pem' }).subscribe({
      next: (pem) => this.agentService.callTool(this.agentId(), 'find', { paths: p.certSearchDirs, file_type: 'file', pattern: '*.crt' }).subscribe({
        next: (crt) => this.certs.set([...new Set([...paths(pem), ...paths(crt)])].sort()),
        error: () => this.certs.set([...new Set(paths(pem))].sort()),
      }),
      error: () => this.certs.set([]),
    });
  }

  private detectConfd(): void {
    this.agentService.callTool(this.agentId(), 'find', { paths: [this.profile().confdDir], file_type: 'file', pattern: '*.conf' }).subscribe({
      next: (resp) => {
        this.confdLayout.set(true);
        const list = ((resp.result as { data?: { path: string }[] })?.data) || [];
        this.finishReload(list.map((e) => e.path));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.sites.set([]); },
    });
  }

  private finishReload(files: string[]): void {
    const p = this.profile();
    const build = (enabled: Set<string>) => {
      this.loading.set(false); this.loaded.set(true);
      this.sites.set(files.map((f) => ({ name: this.siteName(f), file: f, enabled: this.confdLayout() ? true : enabled.has(this.base(f)) }))
        .sort((a, b) => a.name.localeCompare(b.name)));
    };
    if (this.confdLayout() || !p.sitesEnabledDir) { build(new Set()); return; }
    this.agentService.callTool(this.agentId(), 'find', { paths: [p.sitesEnabledDir], file_type: 'any' }).subscribe({
      next: (resp) => build(new Set(((resp.result as { data?: { path: string }[] })?.data || []).map((e) => this.base(e.path)))),
      error: () => build(new Set()),
    });
  }

  // ── selection / expansion ───────────────────────────────────────────
  toggle(row: Row): void {
    if (!row.expandable) return;
    const s = new Set(this.expanded());
    s.has(row.id) ? s.delete(row.id) : s.add(row.id);
    this.expanded.set(s);
  }

  select(row: Row): void {
    this.selectedId.set(row.id);
    this.msg.set(''); this.err.set('');
    if (row.site) this.loadSiteValues(row.site);
  }

  selectSiteByName(name: string): void {
    const s = new Set(this.expanded()); s.add('sites'); s.add('site:' + name); this.expanded.set(s);
    this.selectedId.set('site:' + name); this.loadSiteValues(name);
  }

  selectChild(kind: 'bindings' | 'wwwroot' | 'locations'): void {
    const site = this.ctx()?.site || this.selected()?.site; if (!site) return;
    const s = new Set(this.expanded()); s.add('site:' + site); this.expanded.set(s);
    this.selectedId.set('site:' + site + '/' + kind); this.loadSiteValues(site);
  }

  private loadSiteValues(name: string): void {
    this.raw.set(null);
    this.agentService.callTool(this.agentId(), 'config', { path: this.sidecar(name), format: 'json' }).subscribe({
      next: (resp) => {
        const cfg = (resp.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        if (cfg && Object.keys(cfg).length) { this.values.set(cfg); this.raw.set(null); }
        else this.loadRaw(name);
      },
      error: () => this.loadRaw(name),
    });
  }

  private loadRaw(name: string): void {
    const s = this.sites().find((x) => x.name === name); if (!s) { this.raw.set('(not found)'); return; }
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', s.file] }).subscribe({
      next: (resp) => this.raw.set((resp.result as { data?: { stdout?: string } })?.data?.stdout || ''),
      error: () => this.raw.set('(could not read file)'),
    });
  }

  // MERGE, never replace: a filtered Features pane (Bindings / www root / Locations) emits only ITS fields,
  // so replacing would drop every setting outside that pane. Merging keeps the rest of the site's values.
  onValues(v: Record<string, unknown>): void { this.values.update((cur) => ({ ...cur, ...v })); }

  // ── Add Website ─────────────────────────────────────────────────────
  openAddSite(): void {
    this.newSite = { name: '', root: '', https: false, port: 80, cert: '', certKey: '' };
    this.adding.set(true);
  }
  createSite(): void {
    const f = this.profile().fields;
    const name = this.newSite.name.trim(); if (!name) return;
    if (this.sites().some((s) => s.name === name)) { this.err.set(`Site ${name} already exists.`); this.adding.set(false); return; }
    const file = `${this.dir()}/${name}${this.profile().fileSuffix}`;
    const s: Site = { name, file, enabled: false };
    const values: Record<string, unknown> = {
      [f.serverName]: name,
      [f.root]: this.newSite.root.trim() || `/var/www/${name}`,
      [f.port]: this.newSite.https ? 443 : Number(this.newSite.port) || 80,
      [f.tlsEnabled]: this.newSite.https,
    };
    if (this.newSite.https) {
      if (this.newSite.cert) values[f.cert] = this.newSite.cert;
      if (this.newSite.certKey.trim()) values[f.certKey] = this.newSite.certKey.trim();
    }
    this.sites.update((list) => [...list, s].sort((a, b) => a.name.localeCompare(b.name)));
    this.values.set(values);
    this.adding.set(false);
    // Select + expand the new node WITHOUT loading from the host — nothing is on disk yet, so we keep the
    // freshly-seeded values instead of falling through to the read-only raw view.
    const exp = new Set(this.expanded()); exp.add('sites'); exp.add('site:' + name); this.expanded.set(exp);
    this.raw.set(null);
    this.selectedId.set('site:' + name);
    this.msg.set(`New site ${name} — review the settings and Save.`);
  }

  addLocation(): void {
    if (!this.profile().locationsList) return;   // server has no location-list concept (e.g. apache)
    const site = this.ctx()?.site; if (!site) return;
    const f = this.profile().fields;
    this.selectChild('locations');
    const cur = { ...this.values() };
    const list = Array.isArray(cur[f.locations]) ? [...(cur[f.locations] as unknown[])] : [];
    list.push({ path: '/', proxy_pass: '', try_files: '', extra: '' });
    cur[f.locations] = list; this.values.set(cur);
  }

  // ── Save / validate / reload (the shared apply idiom) ───────────────
  save(s: Site): void {
    if (!this.tplBody) { this.err.set('No vhost template loaded.'); return; }
    this.busy.set(true); this.msg.set(''); this.err.set('');
    // The JSON sidecar dir may not exist yet and the config writer does not create parents — mkdir -p first,
    // otherwise the apply fails with "no such file or directory". Best-effort (apply surfaces real errors).
    this.agentService.callTool(this.agentId(), 'command', { argv: ['mkdir', '-p', this.profile().sidecarDir] })
      .subscribe({ next: () => this.applySite(s), error: () => this.applySite(s) });
  }

  private applySite(s: Site): void {
    const resources: ConfigResource[] = [
      { type: 'template_render', path: s.file, template: this.tplBody, values: this.values() },
      { type: 'config', path: this.sidecar(s.name), format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        this.validate((ok, detail) => {
          if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s), config test ${ok ? 'OK' : 'FAILED'} — nothing written.`); if (!ok) this.err.set(detail); return; }
          if (!ok) { this.busy.set(false); this.err.set(`Written but config test FAILED: ${detail}`); this.reload(); return; }
          this.ensureEnabled(s, () => this.reloadServer(() => { this.busy.set(false); this.msg.set(`Saved ${n} change(s), ${this.profile().service} reloaded.`); this.reload(); }));
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  testConfig(): void {
    this.busy.set(true); this.err.set(''); this.msg.set('');
    this.validate((ok, detail) => { this.busy.set(false); if (ok) this.msg.set('Config test OK.'); else this.err.set(`Config test FAILED: ${detail}`); });
  }

  private validate(done: (ok: boolean, detail: string) => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: this.profile().validateArgv }).subscribe({
      next: (resp) => { const r = resp.result as { data?: { rc?: number; stderr?: string } }; done((r?.data?.rc ?? 1) === 0, r?.data?.stderr || ''); },
      error: () => done(false, 'validate command could not run'),
    });
  }

  private ensureEnabled(s: Site, done: () => void): void {
    const p = this.profile();
    if (this.confdLayout() || !p.sitesEnabledDir || s.enabled) { done(); return; }
    // Link name = the file basename (keeps apache's `.conf`), matching what a2ensite would create.
    this.agentService.callTool(this.agentId(), 'command', { argv: ['ln', '-sf', s.file, `${p.sitesEnabledDir}/${this.base(s.file)}`] })
      .subscribe({ next: () => done(), error: () => done() });
  }

  reloadServer(done?: () => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: this.profile().reloadArgv })
      .subscribe({ next: () => done?.(), error: () => done?.() });
  }

  removeSite(): void {
    const site = this.ctx()?.site || this.selected()?.site; if (!site) return;
    const s = this.sites().find((x) => x.name === site); if (!s) return;
    const p = this.profile();
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const enabledLink = p.sitesEnabledDir ? `'${p.sitesEnabledDir}/${this.base(s.file)}'` : '';
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', `rm -f '${s.file}' ${enabledLink} '${this.sidecar(s.name)}'`] }).subscribe({
      next: () => this.reloadServer(() => { this.busy.set(false); this.selectedId.set('sites'); this.msg.set(`Removed ${site}.`); this.reload(); }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Remove failed.'); },
    });
  }

  // ── Add Certificate (file-based) ────────────────────────────────────
  openAddCert(): void { this.newCertPath = ''; this.addingCert.set(true); }
  addCert(): void {
    const path = this.newCertPath.trim(); if (!path) return;
    this.certs.update((list) => [...new Set([...list, path])].sort());
    this.addingCert.set(false);
    const s = new Set(this.expanded()); s.add('certs'); this.expanded.set(s);
    this.selectedId.set('cert:' + path);
    this.msg.set(`Registered ${path} — select a site's Bindings to use it.`);
  }
}
