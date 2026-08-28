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
import { SingleConfigProfile, WebSectionSpec } from './web-server-profiles';

type NodeKind = 'server' | 'group' | 'list' | 'item' | 'certs' | 'cert';
interface Row { id: string; kind: NodeKind; label: string; icon: string; depth: number; expandable: boolean; expanded: boolean; section?: string; index?: number; cert?: string; }

/**
 * IIS-Manager-style config tree for SINGLE-CONFIG web servers (HAProxy, Caddy) — the sibling of
 * web-config-tree, which handles the one-file-per-site servers (nginx, apache). Here the whole config is one
 * file rendered from one values document, so the tree's nodes are declared feature SECTIONS of that document
 * (see SingleConfigProfile.sections): fixed groups (Global / Frontend / Backend) plus list sections whose
 * entries (backend servers, Caddy sites) are child leaf nodes you add/remove via the right-click menu, and a
 * file-based Certificates node. Selecting a node shows its Features pane (a schema-driven form); Save renders
 * the whole template to the config file + a JSON sidecar via state/apply, validates (e.g. `haproxy -c`,
 * `caddy validate`) and reloads the service.
 */
@Component({
  selector: 'app-web-single-config-tree',
  standalone: true,
  imports: [NgTemplateOutlet, FormsModule, CdkMenu, CdkMenuItem, CdkContextMenuTrigger, MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="wt">
      @if (loading()) { <p class="bm-dim">Loading {{ profile().label }} configuration…</p> }
      @else {
        <div class="wt-cols">
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

          <section class="wt-main">
            @switch (selected()?.kind) {
              @case ('server') { <ng-container *ngTemplateOutlet="serverPane"></ng-container> }
              @case ('group')  { <ng-container *ngTemplateOutlet="editPane; context: { $implicit: paneSchema(), values: values() }"></ng-container> }
              @case ('list')   { <ng-container *ngTemplateOutlet="listPane"></ng-container> }
              @case ('item')   { <ng-container *ngTemplateOutlet="editPane; context: { $implicit: itemSchema(), values: itemValues() }"></ng-container> }
              @case ('certs')  { <ng-container *ngTemplateOutlet="certsPane"></ng-container> }
              @case ('cert')   { <ng-container *ngTemplateOutlet="certPane"></ng-container> }
              @default { <p class="bm-dim">Select a node.</p> }
            }
          </section>
        </div>
      }
      @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }
    </div>

    <!-- ── Panes ─────────────────────────────────────────────────────── -->
    <ng-template #serverPane>
      <h3>{{ profile().label }} <span class="bm-dim">· {{ agentId() }}</span></h3>
      <p class="bm-dim">Single configuration file <code>{{ profile().configPath }}</code>. Select a section on
        the left to edit it; right-click a list section to add an entry. Certificates are file-based.</p>
      <div class="wt-actions">
        <label class="wt-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
        <button mat-button (click)="testConfig()" [disabled]="busy()">Test config</button>
        <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview + validate' : 'Save + reload' }}</button>
      </div>
    </ng-template>

    <ng-template #editPane let-sch let-vals="values">
      <h3>{{ paneTitle() }} <span class="bm-dim">· {{ profile().label }}</span></h3>
      @if (sch) {
        <app-param-form [params]="sch" [initial]="vals" [agentId]="agentId()" (valuesChange)="onPaneValues($event)" />
        <div class="wt-actions">
          <label class="wt-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
          <button mat-button (click)="testConfig()" [disabled]="busy()">Test config</button>
          <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview + validate' : 'Save + reload' }}</button>
        </div>
      }
    </ng-template>

    <ng-template #listPane>
      @if (currentSection(); as sec) {
        <h3>{{ sec.label }} <span class="bm-dim">· {{ listItems(sec).length }} {{ listItems(sec).length === 1 ? 'entry' : 'entries' }}</span></h3>
        <button mat-stroked-button (click)="addItem(sec)"><mat-icon>add</mat-icon> {{ sec.itemActionLabel }}</button>
        <div class="wt-features">
          @for (it of listItems(sec); track $index) {
            <button class="wt-feat" (click)="selectItem(sec.key, $index)"><mat-icon>public</mat-icon> {{ itemLabel(sec, it, $index) }}</button>
          }
          @if (!listItems(sec).length) { <p class="bm-dim">No entries yet — {{ sec.itemActionLabel }}.</p> }
        </div>
      }
    </ng-template>

    <ng-template #certsPane>
      <h3>Certificates <span class="bm-dim">· {{ agentId() }}</span></h3>
      <p class="bm-dim">Certificate files found on this host. Right-click <strong>Certificates</strong> →
        <em>Add Certificate</em> to register a path for use in a TLS binding.</p>
      <button mat-stroked-button (click)="openAddCert()"><mat-icon>add</mat-icon> Add Certificate</button>
      <div class="wt-features">
        @for (c of certs(); track c) { <div class="wt-feat"><mat-icon>verified_user</mat-icon> {{ c }}</div> }
        @if (!certs().length) { <p class="bm-dim">None found under {{ profile().certSearchDirs.join(', ') }}.</p> }
      </div>
    </ng-template>

    <ng-template #certPane>
      <h3>{{ selected()?.cert }}</h3>
      <p class="bm-dim">Certificate file on this host. Reference it from the Frontend / a site's TLS setting.</p>
    </ng-template>

    <!-- ── Context menu ──────────────────────────────────────────────── -->
    <ng-template #nodeMenu><div class="wt-menu" cdkMenu>
      @switch (ctx()?.kind) {
        @case ('list') { <button class="wt-mi" cdkMenuItem (click)="addItemFromCtx()">{{ ctxSection()?.itemActionLabel }}…</button> }
        @case ('item') { <button class="wt-mi wt-danger" cdkMenuItem (click)="removeItemFromCtx()">Remove</button> }
        @case ('certs') { <button class="wt-mi" cdkMenuItem (click)="openAddCert()">Add Certificate…</button> }
        @case ('cert') { <button class="wt-mi" cdkMenuItem disabled>(file-based)</button> }
        @default {
          <button class="wt-mi" cdkMenuItem (click)="testConfig()">Test config</button>
          <button class="wt-mi" cdkMenuItem (click)="reloadServer()">Reload {{ profile().service }}</button>
        }
      }
    </div></ng-template>

    <!-- ── Add Certificate dialog ─────────────────────────────────────── -->
    @if (addingCert()) {
      <div class="wt-modal" (click)="addingCert.set(false)">
        <div class="wt-dialog" (click)="$event.stopPropagation()">
          <h3>Add Certificate</h3>
          <p class="bm-dim">Register a certificate file path on this host so a TLS binding can reference it.</p>
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
    .wt-main code { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.85; }
    .wt-features { display: flex; flex-direction: column; gap: 2px; margin-top: 10px; }
    .wt-feat { display: flex; align-items: center; gap: 8px; border: 0; background: transparent; color: inherit; cursor: pointer; padding: 5px 7px; border-radius: 6px; font-size: 13px; text-align: left; }
    .wt-feat:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .wt-feat mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.75; }
    .wt-actions { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
    .wt-tog { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .wt-menu { background: var(--mat-sys-surface-container, #262626); border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 4px; min-width: 200px; box-shadow: 0 6px 24px rgba(0,0,0,.35); }
    .wt-mi { display: block; width: 100%; text-align: left; border: 0; background: transparent; color: inherit; cursor: pointer; padding: 7px 10px; border-radius: 6px; font-size: 13px; }
    .wt-mi:hover { background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .wt-danger { color: var(--mat-sys-error, #c62828); }
    .wt-modal { position: fixed; inset: 0; background: rgba(0,0,0,.4); display: flex; align-items: center; justify-content: center; z-index: 1000; }
    .wt-dialog { background: var(--mat-sys-surface, #1e1e1e); border-radius: 12px; padding: 18px 20px; width: min(460px, 92vw); box-shadow: 0 10px 40px rgba(0,0,0,.5); }
    .wt-dialog h3 { margin: 0 0 12px; }
    .wt-fld { display: flex; flex-direction: column; gap: 3px; margin-bottom: 10px; font-size: 13px; }
    .bm-in { width: 100%; box-sizing: border-box; padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class WebSingleConfigTreeComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  profile = input.required<SingleConfigProfile>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);

  values = signal<Record<string, unknown>>({});   // the WHOLE config document
  schema = signal<ParamSchema | null>(null);
  certs = signal<string[]>([]);
  private tplBody = '';

  expanded = signal<Set<string>>(new Set(['server', 'certs']));
  selectedId = signal<string>('server');
  ctx = signal<Row | null>(null);

  addingCert = signal(false);
  newCertPath = '';

  // ── tree model ──────────────────────────────────────────────────────
  rows = computed<Row[]>(() => {
    const exp = this.expanded();
    const out: Row[] = [];
    out.push({ id: 'server', kind: 'server', label: this.profile().label, icon: 'dns', depth: 0, expandable: true, expanded: exp.has('server') });
    if (exp.has('server')) {
      for (const sec of this.profile().sections) {
        const id = 'sec:' + sec.key;
        if (sec.kind === 'group') {
          out.push({ id, kind: 'group', label: sec.label, icon: sec.icon, depth: 1, expandable: false, expanded: false, section: sec.key });
        } else {
          const items = this.listItems(sec);
          out.push({ id, kind: 'list', label: sec.label, icon: sec.icon, depth: 1, expandable: items.length > 0, expanded: exp.has(id), section: sec.key });
          if (exp.has(id)) {
            items.forEach((it, i) =>
              out.push({ id: `item:${sec.key}:${i}`, kind: 'item', label: this.itemLabel(sec, it, i), icon: 'public', depth: 2, expandable: false, expanded: false, section: sec.key, index: i }));
          }
        }
      }
    }
    out.push({ id: 'certs', kind: 'certs', label: 'Certificates', icon: 'verified_user', depth: 0, expandable: this.certs().length > 0, expanded: exp.has('certs') });
    if (exp.has('certs')) {
      for (const c of this.certs()) out.push({ id: 'cert:' + c, kind: 'cert', label: c.split('/').pop() || c, icon: 'lock', depth: 1, expandable: false, expanded: false, cert: c });
    }
    return out;
  });

  selected = computed<Row | null>(() => this.rows().find((r) => r.id === this.selectedId()) ?? null);
  currentSection = computed<WebSectionSpec | null>(() => {
    const key = this.selected()?.section;
    return key ? (this.profile().sections.find((s) => s.key === key) ?? null) : null;
  });
  ctxSection = computed<WebSectionSpec | null>(() => {
    const key = this.ctx()?.section;
    return key ? (this.profile().sections.find((s) => s.key === key) ?? null) : null;
  });

  /** Group pane: the whole schema filtered to the section's fields. */
  paneSchema = computed<ParamSchema | null>(() => {
    const full = this.schema(); const sec = this.currentSection();
    if (!full || !sec || sec.kind !== 'group' || !sec.fields) return full;
    return Object.fromEntries(Object.entries(full).filter(([k]) => sec.fields!.includes(k))) as ParamSchema;
  });
  /** Item pane: the list field's item sub-schema. */
  itemSchema = computed<ParamSchema | null>(() => {
    const sel = this.selected(); const full = this.schema();
    if (!sel || sel.kind !== 'item' || !full) return null;
    const sec = this.profile().sections.find((s) => s.key === sel.section);
    if (!sec?.listField) return null;
    return (full[sec.listField]?.items as ParamSchema) ?? null;
  });
  itemValues = computed<Record<string, unknown>>(() => {
    const sel = this.selected();
    if (!sel || sel.kind !== 'item') return {};
    const sec = this.profile().sections.find((s) => s.key === sel.section);
    const list = sec?.listField ? (this.values()[sec.listField] as Record<string, unknown>[] | undefined) : undefined;
    return (list && sel.index != null && list[sel.index]) || {};
  });
  paneTitle = computed(() => {
    const sel = this.selected();
    if (sel?.kind === 'item') { const sec = this.currentSection(); return `${sec?.label ?? ''} · ${sel.label}`; }
    return this.currentSection()?.label ?? 'Settings';
  });

  listItems(sec: WebSectionSpec): Record<string, unknown>[] {
    const v = sec.listField ? this.values()[sec.listField] : undefined;
    return Array.isArray(v) ? (v as Record<string, unknown>[]) : [];
  }
  itemLabel(sec: WebSectionSpec, it: Record<string, unknown>, i: number): string {
    const n = sec.itemNameField ? it[sec.itemNameField] : undefined;
    return (n != null && String(n).trim()) ? String(n) : `(entry ${i + 1})`;
  }

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  private dirOf(p: string): string { return p.replace(/\/[^/]*$/, '') || '/'; }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    const p = this.profile();
    forkJoin({
      tpl: this.agentService.configTemplate(p.template),
      cfg: this.agentService.callTool(this.agentId(), 'config', { path: p.sidecarPath, format: 'json' }),
    }).subscribe({
      next: ({ tpl: { tpl, missing }, cfg }) => {
        if (missing) this.err.set(missing);
        this.tplBody = tpl?.template || '';
        const sch = (tpl?.schema as ParamSchema) || null;
        if (sch) this.schema.set(sch);
        const stored = (cfg.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        // Seed from schema defaults so a first render (no sidecar yet) still produces a valid whole config,
        // then overlay whatever the sidecar stored.
        this.values.set({ ...this.defaults(sch), ...(stored && Object.keys(stored).length ? stored : {}) });
        this.loading.set(false); this.loaded.set(true);
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
    this.loadCerts();
  }

  private defaults(sch: ParamSchema | null): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    if (!sch) return out;
    for (const [k, spec] of Object.entries(sch)) {
      if (spec.default !== undefined) out[k] = spec.default;
      else if (spec.type === 'list') out[k] = [];
    }
    return out;
  }

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

  // ── selection / expansion ───────────────────────────────────────────
  toggle(row: Row): void {
    if (!row.expandable) return;
    const s = new Set(this.expanded());
    s.has(row.id) ? s.delete(row.id) : s.add(row.id);
    this.expanded.set(s);
  }
  select(row: Row): void { this.selectedId.set(row.id); this.msg.set(''); this.err.set(''); }
  selectItem(section: string, index: number): void {
    const s = new Set(this.expanded()); s.add('server'); s.add('sec:' + section); this.expanded.set(s);
    this.selectedId.set(`item:${section}:${index}`);
  }

  // ── value edits (MERGE — a filtered pane emits only its own fields) ──
  onPaneValues(v: Record<string, unknown>): void {
    const sel = this.selected();
    if (sel?.kind === 'item') {
      const sec = this.profile().sections.find((s) => s.key === sel.section);
      if (!sec?.listField || sel.index == null) return;
      this.values.update((cur) => {
        const list = Array.isArray(cur[sec.listField!]) ? [...(cur[sec.listField!] as Record<string, unknown>[])] : [];
        list[sel.index!] = { ...(list[sel.index!] || {}), ...v };
        return { ...cur, [sec.listField!]: list };
      });
    } else {
      this.values.update((cur) => ({ ...cur, ...v }));
    }
  }

  addItem(sec: WebSectionSpec): void {
    if (!sec.listField) return;
    let newIdx = 0;
    this.values.update((cur) => {
      const list = Array.isArray(cur[sec.listField!]) ? [...(cur[sec.listField!] as Record<string, unknown>[])] : [];
      newIdx = list.length;
      list.push({ ...(sec.itemDefault || {}) });
      return { ...cur, [sec.listField!]: list };
    });
    this.selectItem(sec.key, newIdx);
    this.msg.set(`New ${sec.label} entry — fill it in and Save.`);
  }
  addItemFromCtx(): void { const sec = this.ctxSection(); if (sec) this.addItem(sec); }

  removeItemFromCtx(): void {
    const row = this.ctx(); if (!row || row.kind !== 'item' || row.index == null) return;
    const sec = this.profile().sections.find((s) => s.key === row.section); if (!sec?.listField) return;
    this.values.update((cur) => {
      const list = Array.isArray(cur[sec.listField!]) ? [...(cur[sec.listField!] as Record<string, unknown>[])] : [];
      list.splice(row.index!, 1);
      return { ...cur, [sec.listField!]: list };
    });
    this.selectedId.set('sec:' + sec.key);
    this.msg.set(`Removed entry — Save to apply.`);
  }

  // ── Save / validate / reload (whole config) ─────────────────────────
  save(): void {
    if (!this.tplBody) { this.err.set('No template loaded.'); return; }
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const p = this.profile();
    // The sidecar dir may not exist yet and the config writer does not create parents — mkdir -p first.
    this.agentService.callTool(this.agentId(), 'command', { argv: ['mkdir', '-p', this.dirOf(p.sidecarPath)] })
      .subscribe({ next: () => this.applyConfig(), error: () => this.applyConfig() });
  }

  private applyConfig(): void {
    const p = this.profile();
    const resources: ConfigResource[] = [
      { type: 'template_render', path: p.configPath, template: this.tplBody, values: this.values() },
      { type: 'config', path: p.sidecarPath, format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        this.validate((ok, detail) => {
          if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s), config test ${ok ? 'OK' : 'FAILED'} — nothing written.`); if (!ok) this.err.set(detail); return; }
          if (!ok) { this.busy.set(false); this.err.set(`Written but config test FAILED: ${detail}`); return; }
          this.reloadServer(() => { this.busy.set(false); this.msg.set(`Saved ${n} change(s), ${p.service} reloaded.`); });
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

  reloadServer(done?: () => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: this.profile().reloadArgv })
      .subscribe({ next: () => done?.(), error: () => done?.() });
  }

  // ── Add Certificate (file-based) ────────────────────────────────────
  openAddCert(): void { this.newCertPath = ''; this.addingCert.set(true); }
  addCert(): void {
    const path = this.newCertPath.trim(); if (!path) return;
    this.certs.update((list) => [...new Set([...list, path])].sort());
    this.addingCert.set(false);
    const s = new Set(this.expanded()); s.add('certs'); this.expanded.set(s);
    this.selectedId.set('cert:' + path);
    this.msg.set(`Registered ${path} — reference it from a TLS setting.`);
  }
}
