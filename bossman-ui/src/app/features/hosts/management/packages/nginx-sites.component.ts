import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../../shared/param-form/param-form.types';

interface Site { name: string; file: string; enabled: boolean; }

// Debian layout is primary; conf.d (RedHat/upstream) is the fallback, detected at load.
const SITES_AVAILABLE = '/etc/nginx/sites-available';
const SITES_ENABLED = '/etc/nginx/sites-enabled';
const CONF_D = '/etc/nginx/conf.d';
// Per-site VALUES sidecar, OUTSIDE any include glob, so it never breaks nginx.
const SIDECAR_DIR = '/etc/agentic-mcp/websites/nginx';

/**
 * nginx site (server-block) lifecycle snapin — the "clicky" IIS-style editor.
 * Left: the list of sites under sites-available (Debian) or conf.d (RedHat),
 * with an enabled toggle. Right: a schema-driven form (the nginx-vhost Class-B
 * template's values, incl. TLS termination) — the WHOLE server block is
 * rendered from the values, never hand-edited. A site we author stores its
 * values as a JSON sidecar so re-opening loads the values (no block parsing);
 * a foreign, hand-written site with no sidecar shows a read-only raw view.
 * Apply = template_render + sidecar written atomically through state/apply
 * (dry-run + generation/rollback), then `nginx -t` and reload.
 */
@Component({
  selector: 'app-nginx-sites',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-nx">
      @if (loading()) { <p class="bm-dim">Loading nginx sites…</p> }
      @else {
        <div class="bm-nx-cols">
          <aside class="bm-nx-list">
            <div class="bm-nx-h">Sites ({{ sites().length }})</div>
            @for (s of sites(); track s.file) {
              <button class="bm-nx-site" [class.sel]="selected()?.file === s.file" (click)="selectSite(s)">
                <mat-icon>{{ s.enabled ? 'public' : 'public_off' }}</mat-icon>
                <span>{{ s.name }}</span>
                @if (!s.enabled) { <span class="bm-nx-off">disabled</span> }
              </button>
            }
            @if (!sites().length) { <p class="bm-dim bm-nx-none">No sites yet.</p> }
            <div class="bm-nx-create">
              <input class="bm-in" #sn placeholder="new site e.g. example.com" [disabled]="busy()" />
              <button mat-stroked-button (click)="createSite(sn.value); sn.value=''" [disabled]="busy()"><mat-icon>add</mat-icon> New site</button>
            </div>
            @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
            @if (err()) { <p class="bm-err">{{ err() }}</p> }
          </aside>

          <section class="bm-nx-edit">
            @if (!selected()) { <p class="bm-dim">Select a site to edit, or create one.</p> }
            @else {
              <div class="bm-nx-h2">
                <strong>{{ selected()!.name }}</strong> <span class="bm-dim">· {{ selected()!.file }}</span>
                <span class="bm-spacer"></span>
                <label class="bm-tog"><input type="checkbox" [checked]="selected()!.enabled" (change)="toggleEnabled(selected()!)" [disabled]="busy() || confdLayout()" /> enabled</label>
                <button class="bm-x2" (click)="deleteSite(selected()!)" [disabled]="busy()" title="Delete site">✕</button>
              </div>

              @if (raw() !== null) {
                <p class="bm-dim">This site was not created here (no stored values) — read-only. Editing it as values would require parsing its block syntax.</p>
                <pre class="bm-raw">{{ raw() }}</pre>
              } @else if (schema()) {
                <p class="bm-dim">Edit the values — the whole server block (incl. TLS) is rendered from them.</p>
                <app-param-form [params]="schema()!" [initial]="values()" [agentId]="agentId()" (valuesChange)="onValues($event)" />
                @if (rendered()) {
                  <p class="bm-dim">Rendered {{ selected()!.name }} (would be written):</p>
                  <pre class="bm-raw">{{ rendered() }}</pre>
                }
                <div class="bm-nx-actions">
                  <label class="bm-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
                  <button mat-button (click)="preview()" [disabled]="busy()">Preview (render)</button>
                  <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview + validate' : 'Save + reload' }}</button>
                </div>
              }
            }
          </section>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-nx-cols { display: grid; grid-template-columns: 260px 1fr; gap: 16px; align-items: start; }
    .bm-nx-h, .bm-nx-h2 { font-weight: 600; margin-bottom: 10px; }
    .bm-nx-h2 { display: flex; align-items: center; gap: 8px; }
    .bm-spacer { flex: 1; }
    .bm-nx-site { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; border: 0; background: transparent;
      cursor: pointer; padding: 6px 8px; border-radius: 6px; color: inherit; font-size: 13.5px; }
    .bm-nx-site:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-nx-site.sel { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); font-weight: 600; }
    .bm-nx-site mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-nx-off { font-size: 11px; opacity: 0.6; margin-left: auto; }
    .bm-nx-create { margin-top: 12px; display: flex; flex-direction: column; gap: 6px; }
    .bm-nx-none { padding: 4px 8px; }
    .bm-nx-actions { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
    .bm-tog { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-in { width: 100%; box-sizing: border-box; padding: 6px 9px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-raw { max-height: 320px; overflow: auto; background: var(--mat-sys-surface-container, #1a1a1a); padding: 10px 12px;
      border-radius: 8px; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre; }
    .bm-x2 { border: 0; background: transparent; cursor: pointer; color: var(--mat-sys-error,#c62828); }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class NginxSitesComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  confdLayout = signal(false);      // RedHat/upstream conf.d layout (no symlink enable)

  sites = signal<Site[]>([]);
  selected = signal<Site | null>(null);
  schema = signal<ParamSchema | null>(null);
  values = signal<Record<string, unknown>>({});
  rendered = signal<string>('');
  raw = signal<string | null>(null);   // non-null = foreign site, read-only
  private tplBody = '';

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  private dir(): string { return this.confdLayout() ? CONF_D : SITES_AVAILABLE; }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    // Fetch the nginx-vhost template body + schema once, and enumerate sites.
    forkJoin({
      tpls: this.agentService.configTemplates(),
      avail: this.agentService.callTool(this.agentId(), 'find', { paths: [SITES_AVAILABLE], file_type: 'file' }),
    }).subscribe({
      next: ({ tpls, avail }) => {
        const tpl = tpls.templates.find((t) => t.name === 'nginx-vhost');
        this.tplBody = tpl?.template || '';
        if (tpl?.schema) this.schema.set(tpl.schema as ParamSchema);
        const availList = ((avail.result as { data?: { path: string }[] })?.data) || [];
        if (availList.length) { this.confdLayout.set(false); this.finishReload(availList.map((e) => e.path)); }
        else { this.detectConfd(); }
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
  }

  private detectConfd(): void {
    this.agentService.callTool(this.agentId(), 'find', { paths: [CONF_D], file_type: 'file', pattern: '*.conf' }).subscribe({
      next: (resp) => {
        this.confdLayout.set(true);
        const list = ((resp.result as { data?: { path: string }[] })?.data) || [];
        this.finishReload(list.map((e) => e.path));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.sites.set([]); },
    });
  }

  private finishReload(files: string[]): void {
    // Debian: enabled = a symlink of the same basename exists in sites-enabled.
    if (this.confdLayout()) {
      this.loading.set(false); this.loaded.set(true);
      this.sites.set(files.map((f) => ({ name: this.base(f), file: f, enabled: true })).sort((a, b) => a.name.localeCompare(b.name)));
      return;
    }
    this.agentService.callTool(this.agentId(), 'find', { paths: [SITES_ENABLED], file_type: 'any' }).subscribe({
      next: (resp) => {
        const enabled = new Set(((resp.result as { data?: { path: string }[] })?.data || []).map((e) => this.base(e.path)));
        this.loading.set(false); this.loaded.set(true);
        this.sites.set(files.map((f) => ({ name: this.base(f), file: f, enabled: enabled.has(this.base(f)) })).sort((a, b) => a.name.localeCompare(b.name)));
      },
      error: () => {
        this.loading.set(false); this.loaded.set(true);
        this.sites.set(files.map((f) => ({ name: this.base(f), file: f, enabled: false })));
      },
    });
  }

  private base(p: string): string { return p.replace(/\/+$/, '').split('/').pop() || p; }
  private sidecar(name: string): string { return `${SIDECAR_DIR}/${name}.json`; }

  selectSite(s: Site): void {
    this.selected.set(s); this.msg.set(''); this.err.set(''); this.rendered.set(''); this.raw.set(null);
    // Try the values sidecar first; if present the site is value-managed.
    this.agentService.callTool(this.agentId(), 'config', { path: this.sidecar(s.name), format: 'json' }).subscribe({
      next: (resp) => {
        const cfg = (resp.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        if (cfg && Object.keys(cfg).length) { this.values.set(cfg); this.raw.set(null); }
        else this.loadRaw(s);
      },
      error: () => this.loadRaw(s),
    });
  }

  /** Foreign site (no stored values) — read the file raw, read-only. */
  private loadRaw(s: Site): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', s.file] }).subscribe({
      next: (resp) => this.raw.set((resp.result as { data?: { stdout?: string } })?.data?.stdout || ''),
      error: () => this.raw.set('(could not read file)'),
    });
  }

  createSite(name: string): void {
    name = (name || '').trim();
    if (!name) return;
    if (this.sites().some((s) => s.name === name)) { this.err.set(`Site ${name} already exists.`); return; }
    const file = `${this.dir()}/${name}`;
    const s: Site = { name, file, enabled: false };
    this.sites.update((list) => [...list, s].sort((a, b) => a.name.localeCompare(b.name)));
    // Seed from the schema defaults with server_name/root prefilled to the name.
    this.selected.set(s); this.raw.set(null); this.rendered.set('');
    this.values.set({ server_name: name, root: `/var/www/${name}` });
    this.msg.set(`New site ${name} — set the values and Save.`);
  }

  onValues(v: Record<string, unknown>): void { this.values.set(v); }

  preview(): void {
    const s = this.selected(); if (!s || !this.tplBody) return;
    this.busy.set(true); this.err.set('');
    this.agentService.renderTemplate(this.agentId(), this.tplBody, this.values(), s.file).subscribe({
      next: (resp) => { this.busy.set(false); this.rendered.set((resp.result as { data?: { rendered?: string } })?.data?.rendered || ''); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Render failed.'); },
    });
  }

  save(): void {
    const s = this.selected(); if (!s || !this.tplBody) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const resources: ConfigResource[] = [
      { type: 'template_render', path: s.file, template: this.tplBody, values: this.values() },
      { type: 'config', path: this.sidecar(s.name), format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        // Always validate the config (nginx -t) before reloading.
        this.validateAndReload(s, (ok, detail) => {
          this.busy.set(false);
          if (this.dryRun()) { this.msg.set(`Preview: ${n} change(s), config test ${ok ? 'OK' : 'FAILED'} — nothing written.`); if (!ok) this.err.set(detail); return; }
          if (!ok) { this.err.set(`Written but nginx -t FAILED: ${detail}`); this.reload(); return; }
          this.msg.set(`Saved ${n} change(s), nginx reloaded.`); this.reload();
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  private validateAndReload(s: Site, done: (ok: boolean, detail: string) => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['nginx', '-t'] }).subscribe({
      next: (resp) => {
        const r = resp.result as { data?: { rc?: number; stderr?: string } };
        const ok = (r?.data?.rc ?? 1) === 0;
        if (this.dryRun() || !ok) { done(ok, r?.data?.stderr || ''); return; }
        // Ensure enabled on first save (Debian symlink), then reload.
        this.ensureEnabled(s, () => this.reloadNginx(() => done(true, '')));
      },
      error: () => done(false, 'nginx -t could not run'),
    });
  }

  private ensureEnabled(s: Site, done: () => void): void {
    if (this.confdLayout() || s.enabled) { done(); return; }
    const link = `${SITES_ENABLED}/${s.name}`;
    this.agentService.callTool(this.agentId(), 'command', { argv: ['ln', '-sf', s.file, link] }).subscribe({ next: () => done(), error: () => done() });
  }

  private reloadNginx(done: () => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['nginx', '-s', 'reload'] }).subscribe({ next: () => done(), error: () => done() });
  }

  toggleEnabled(s: Site): void {
    if (this.confdLayout()) return;
    this.busy.set(true);
    const link = `${SITES_ENABLED}/${s.name}`;
    const argv = s.enabled ? ['rm', '-f', link] : ['ln', '-sf', s.file, link];
    this.agentService.callTool(this.agentId(), 'command', { argv }).subscribe({
      next: () => this.reloadNginx(() => { this.busy.set(false); this.reload(); }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Toggle failed.'); },
    });
  }

  deleteSite(s: Site): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const argv = ['sh', '-c', `rm -f '${s.file}' '${SITES_ENABLED}/${s.name}' '${this.sidecar(s.name)}'`];
    this.agentService.callTool(this.agentId(), 'command', { argv }).subscribe({
      next: () => this.reloadNginx(() => { this.busy.set(false); this.selected.set(null); this.msg.set(`Deleted ${s.name}.`); this.reload(); }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Delete failed.'); },
    });
  }
}
