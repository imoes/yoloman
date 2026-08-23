import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../../shared/param-form/param-form.types';

interface VHost { name: string; file: string; enabled: boolean; }

// Debian (apache2) is primary; RedHat (httpd, conf.d) is the fallback, detected at load.
const DEB_AVAIL = '/etc/apache2/sites-available';
const DEB_ENABLED = '/etc/apache2/sites-enabled';
const RH_CONFD = '/etc/httpd/conf.d';
const SIDECAR_DIR = '/etc/agentic-mcp/websites/apache';

/**
 * Apache virtual-host lifecycle snapin — the "clicky" IIS-style editor, sibling
 * of the nginx one. Distro-aware: Debian keeps vhosts in sites-available and
 * enables them with a2ensite (symlink into sites-enabled); RedHat drops
 * <name>.conf into conf.d (always enabled). The whole <VirtualHost> is rendered
 * from values via the apache-vhost Class-B template (incl. TLS termination) —
 * never hand-edited. Values persist as a JSON sidecar so re-opening loads them;
 * a foreign hand-written vhost shows a read-only raw view. Apply writes the
 * vhost file (template_render) + sidecar (json) atomically through state/apply
 * (dry-run + generation/rollback), enables mod_ssl/headers when TLS is on,
 * then `apachectl configtest` and a graceful reload.
 */
@Component({
  selector: 'app-apache-vhosts',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-nx">
      @if (loading()) { <p class="bm-dim">Loading Apache vhosts…</p> }
      @else {
        <div class="bm-nx-cols">
          <aside class="bm-nx-list">
            <div class="bm-nx-h">Virtual hosts ({{ vhosts().length }}) <span class="bm-dim">· {{ redhat() ? 'httpd' : 'apache2' }}</span></div>
            @for (v of vhosts(); track v.file) {
              <button class="bm-nx-site" [class.sel]="selected()?.file === v.file" (click)="selectVhost(v)">
                <mat-icon>{{ v.enabled ? 'public' : 'public_off' }}</mat-icon>
                <span>{{ v.name }}</span>
                @if (!v.enabled) { <span class="bm-nx-off">disabled</span> }
              </button>
            }
            @if (!vhosts().length) { <p class="bm-dim bm-nx-none">No vhosts yet.</p> }
            <div class="bm-nx-create">
              <input class="bm-in" #vn placeholder="new vhost e.g. example.com" [disabled]="busy()" />
              <button mat-stroked-button (click)="createVhost(vn.value); vn.value=''" [disabled]="busy()"><mat-icon>add</mat-icon> New vhost</button>
            </div>
            @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
            @if (err()) { <p class="bm-err">{{ err() }}</p> }
          </aside>

          <section class="bm-nx-edit">
            @if (!selected()) { <p class="bm-dim">Select a vhost to edit, or create one.</p> }
            @else {
              <div class="bm-nx-h2">
                <strong>{{ selected()!.name }}</strong> <span class="bm-dim">· {{ selected()!.file }}</span>
                <span class="bm-spacer"></span>
                <label class="bm-tog"><input type="checkbox" [checked]="selected()!.enabled" (change)="toggleEnabled(selected()!)" [disabled]="busy() || redhat()" /> enabled</label>
                <button class="bm-x2" (click)="deleteVhost(selected()!)" [disabled]="busy()" title="Delete vhost">✕</button>
              </div>

              @if (raw() !== null) {
                <p class="bm-dim">This vhost was not created here (no stored values) — read-only.</p>
                <pre class="bm-raw">{{ raw() }}</pre>
              } @else if (schema()) {
                <p class="bm-dim">Edit the values — the whole &lt;VirtualHost&gt; (incl. TLS) is rendered from them.</p>
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
export class ApacheVhostsComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  redhat = signal(false);   // httpd/conf.d layout (no a2ensite symlink enable)

  vhosts = signal<VHost[]>([]);
  selected = signal<VHost | null>(null);
  schema = signal<ParamSchema | null>(null);
  values = signal<Record<string, unknown>>({});
  rendered = signal<string>('');
  raw = signal<string | null>(null);
  private tplBody = '';

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  private dir(): string { return this.redhat() ? RH_CONFD : DEB_AVAIL; }
  private bin(): string { return this.redhat() ? 'apachectl' : 'apache2ctl'; }
  private base(p: string): string { return p.replace(/\/+$/, '').split('/').pop() || p; }
  private siteName(file: string): string { return this.base(file).replace(/\.conf$/, ''); }
  private sidecar(name: string): string { return `${SIDECAR_DIR}/${name}.json`; }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    forkJoin({
      tpl: this.agentService.configTemplate('apache-vhost'),
      avail: this.agentService.callTool(this.agentId(), 'find', { paths: [DEB_AVAIL], file_type: 'file', pattern: '*.conf' }),
    }).subscribe({
      next: ({ tpl: { tpl, missing }, avail }) => {
        if (missing) this.err.set(missing);
        this.tplBody = tpl?.template || '';
        if (tpl?.schema) this.schema.set(tpl.schema as ParamSchema);
        const list = ((avail.result as { data?: { path: string }[] })?.data) || [];
        if (list.length) { this.redhat.set(false); this.finishReload(list.map((e) => e.path)); }
        else { this.detectRedhat(); }
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
  }

  private detectRedhat(): void {
    this.agentService.callTool(this.agentId(), 'find', { paths: [RH_CONFD], file_type: 'file', pattern: '*.conf' }).subscribe({
      next: (resp) => {
        this.redhat.set(true);
        const list = ((resp.result as { data?: { path: string }[] })?.data) || [];
        this.finishReload(list.map((e) => e.path));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.vhosts.set([]); },
    });
  }

  private finishReload(files: string[]): void {
    if (this.redhat()) {
      this.loading.set(false); this.loaded.set(true);
      this.vhosts.set(files.map((f) => ({ name: this.siteName(f), file: f, enabled: true })).sort((a, b) => a.name.localeCompare(b.name)));
      return;
    }
    this.agentService.callTool(this.agentId(), 'find', { paths: [DEB_ENABLED], file_type: 'any' }).subscribe({
      next: (resp) => {
        const enabled = new Set(((resp.result as { data?: { path: string }[] })?.data || []).map((e) => this.base(e.path)));
        this.loading.set(false); this.loaded.set(true);
        this.vhosts.set(files.map((f) => ({ name: this.siteName(f), file: f, enabled: enabled.has(this.base(f)) })).sort((a, b) => a.name.localeCompare(b.name)));
      },
      error: () => {
        this.loading.set(false); this.loaded.set(true);
        this.vhosts.set(files.map((f) => ({ name: this.siteName(f), file: f, enabled: false })));
      },
    });
  }

  selectVhost(v: VHost): void {
    this.selected.set(v); this.msg.set(''); this.err.set(''); this.rendered.set(''); this.raw.set(null);
    this.agentService.callTool(this.agentId(), 'config', { path: this.sidecar(v.name), format: 'json' }).subscribe({
      next: (resp) => {
        const cfg = (resp.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        if (cfg && Object.keys(cfg).length) { this.values.set(cfg); this.raw.set(null); }
        else this.loadRaw(v);
      },
      error: () => this.loadRaw(v),
    });
  }

  private loadRaw(v: VHost): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', v.file] }).subscribe({
      next: (resp) => this.raw.set((resp.result as { data?: { stdout?: string } })?.data?.stdout || ''),
      error: () => this.raw.set('(could not read file)'),
    });
  }

  createVhost(name: string): void {
    name = (name || '').trim().replace(/\.conf$/, '');
    if (!name) return;
    if (this.vhosts().some((v) => v.name === name)) { this.err.set(`Vhost ${name} already exists.`); return; }
    const file = `${this.dir()}/${name}.conf`;
    const v: VHost = { name, file, enabled: false };
    this.vhosts.update((list) => [...list, v].sort((a, b) => a.name.localeCompare(b.name)));
    this.selected.set(v); this.raw.set(null); this.rendered.set('');
    this.values.set({ server_name: name, document_root: `/var/www/${name}` });
    this.msg.set(`New vhost ${name} — set the values and Save.`);
  }

  onValues(v: Record<string, unknown>): void { this.values.set(v); }

  preview(): void {
    const v = this.selected(); if (!v || !this.tplBody) return;
    this.busy.set(true); this.err.set('');
    this.agentService.renderTemplate(this.agentId(), this.tplBody, this.values(), v.file).subscribe({
      next: (resp) => { this.busy.set(false); this.rendered.set((resp.result as { data?: { rendered?: string } })?.data?.rendered || ''); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Render failed.'); },
    });
  }

  save(): void {
    const v = this.selected(); if (!v || !this.tplBody) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const resources: ConfigResource[] = [
      { type: 'template_render', path: v.file, template: this.tplBody, values: this.values() },
      { type: 'config', path: this.sidecar(v.name), format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        this.ensureModulesThen(v, () => this.validateAndReload(v, (ok, detail) => {
          this.busy.set(false);
          if (this.dryRun()) { this.msg.set(`Preview: ${n} change(s), config test ${ok ? 'OK' : 'FAILED'} — nothing written.`); if (!ok) this.err.set(detail); return; }
          if (!ok) { this.err.set(`Written but configtest FAILED: ${detail}`); this.reload(); return; }
          this.msg.set(`Saved ${n} change(s), Apache reloaded.`); this.reload();
        }));
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  /** Enable mod_ssl + mod_headers on Debian when the vhost terminates TLS. */
  private ensureModulesThen(v: VHost, done: () => void): void {
    if (this.dryRun() || this.redhat() || !this.values()['tls_enabled']) { done(); return; }
    this.agentService.callTool(this.agentId(), 'command', { argv: ['a2enmod', '-q', 'ssl', 'headers'] }).subscribe({ next: () => done(), error: () => done() });
  }

  private validateAndReload(v: VHost, done: (ok: boolean, detail: string) => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: [this.bin(), 'configtest'] }).subscribe({
      next: (resp) => {
        const r = resp.result as { data?: { rc?: number; stderr?: string } };
        const ok = (r?.data?.rc ?? 1) === 0;
        if (this.dryRun() || !ok) { done(ok, r?.data?.stderr || ''); return; }
        this.ensureEnabled(v, () => this.reloadApache(() => done(true, '')));
      },
      error: () => done(false, 'configtest could not run'),
    });
  }

  private ensureEnabled(v: VHost, done: () => void): void {
    if (this.redhat() || v.enabled) { done(); return; }
    this.agentService.callTool(this.agentId(), 'command', { argv: ['a2ensite', '-q', v.name] }).subscribe({ next: () => done(), error: () => done() });
  }

  private reloadApache(done: () => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: [this.bin(), 'graceful'] }).subscribe({ next: () => done(), error: () => done() });
  }

  toggleEnabled(v: VHost): void {
    if (this.redhat()) return;
    this.busy.set(true);
    const argv = v.enabled ? ['a2dissite', '-q', v.name] : ['a2ensite', '-q', v.name];
    this.agentService.callTool(this.agentId(), 'command', { argv }).subscribe({
      next: () => this.reloadApache(() => { this.busy.set(false); this.reload(); }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Toggle failed.'); },
    });
  }

  deleteVhost(v: VHost): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const pre = this.redhat() ? 'true' : `a2dissite -q '${v.name}' 2>/dev/null; true`;
    const argv = ['sh', '-c', `${pre}; rm -f '${v.file}' '${this.sidecar(v.name)}'`];
    this.agentService.callTool(this.agentId(), 'command', { argv }).subscribe({
      next: () => this.reloadApache(() => { this.busy.set(false); this.selected.set(null); this.msg.set(`Deleted ${v.name}.`); this.reload(); }),
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Delete failed.'); },
    });
  }
}
