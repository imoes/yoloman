import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../../shared/param-form/param-form.types';

const HAPROXY_CFG = '/etc/haproxy/haproxy.cfg';
const SIDECAR = '/etc/agentic-mcp/websites/haproxy/haproxy.json';

/**
 * HAProxy config snapin — a SINGLE-object editor (unlike nginx/apache, HAProxy
 * is one file with global/defaults/frontend/backend sections). The whole
 * haproxy.cfg is rendered from values via the haproxy Class-B template (incl.
 * TLS termination: bind :443 ssl crt, HTTP->HTTPS redirect, HSTS, and the
 * backend-server pool as a list). Values persist as a JSON sidecar; a
 * pre-existing hand-written haproxy.cfg (no sidecar) shows read-only until the
 * operator opts into form management (which then owns the file). Apply writes
 * the cfg (template_render) + sidecar (json) through state/apply (dry-run +
 * generation/rollback), then `haproxy -c` and reload.
 */
@Component({
  selector: 'app-haproxy-config',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-hap">
      @if (loading()) { <p class="bm-dim">Loading HAProxy config…</p> }
      @else {
        <div class="bm-hap-head">
          <strong>HAProxy</strong> <span class="bm-dim">· {{ cfgPath }}</span>
          <span class="bm-spacer"></span>
          @if (managed()) {
            <label class="bm-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
            <button mat-button (click)="preview()" [disabled]="busy()">Preview (render)</button>
            <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview + validate' : 'Save + reload' }}</button>
          }
        </div>
        @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
        @if (err()) { <p class="bm-err">{{ err() }}</p> }

        @if (!managed()) {
          <p class="bm-dim">This haproxy.cfg was not created here. Editing it as values would replace the whole file with a template render — review the current file first.</p>
          <pre class="bm-raw">{{ raw() }}</pre>
          <button mat-stroked-button (click)="startManaged()"><mat-icon>dataset</mat-icon> Configure with form (replaces file on save)</button>
        } @else if (schema()) {
          <p class="bm-dim">Edit the values — the whole haproxy.cfg (incl. TLS termination) is rendered from them.</p>
          <app-param-form [params]="schema()!" [initial]="values()" [agentId]="agentId()" (valuesChange)="onValues($event)" />
          @if (rendered()) {
            <p class="bm-dim">Rendered haproxy.cfg (would be written):</p>
            <pre class="bm-raw">{{ rendered() }}</pre>
          }
        }
      }
    </div>
  `,
  styles: [`
    .bm-hap-head { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
    .bm-spacer { flex: 1; }
    .bm-tog { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-raw { max-height: 340px; overflow: auto; background: var(--mat-sys-surface-container, #1a1a1a); padding: 10px 12px;
      border-radius: 8px; font-family: ui-monospace, monospace; font-size: 12px; white-space: pre; margin: 8px 0; }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class HaproxyConfigComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  readonly cfgPath = HAPROXY_CFG;
  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  managed = signal(false);          // true once values drive the file
  schema = signal<ParamSchema | null>(null);
  values = signal<Record<string, unknown>>({});
  private sample: Record<string, unknown> = {};
  rendered = signal<string>('');
  raw = signal<string>('');
  private tplBody = '';

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set(''); this.rendered.set('');
    forkJoin({
      tpl: this.agentService.configTemplate('haproxy'),
      side: this.agentService.callTool(this.agentId(), 'config', { path: SIDECAR, format: 'json' }),
    }).subscribe({
      next: ({ tpl: { tpl, missing }, side }) => {
        if (missing) this.err.set(missing);
        this.tplBody = tpl?.template || '';
        if (tpl?.schema) this.schema.set(tpl.schema as ParamSchema);
        this.sample = (tpl?.sample as Record<string, unknown>) || {};
        const cfg = (side.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        if (cfg && Object.keys(cfg).length) {
          this.values.set(cfg); this.managed.set(true);
          this.loading.set(false); this.loaded.set(true);
        } else {
          this.loadRaw();
        }
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
  }

  private loadRaw(): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', HAPROXY_CFG] }).subscribe({
      next: (resp) => {
        this.raw.set((resp.result as { data?: { stdout?: string } })?.data?.stdout || '(empty)');
        this.managed.set(false); this.loading.set(false); this.loaded.set(true);
      },
      error: () => { this.raw.set('(could not read file)'); this.managed.set(false); this.loading.set(false); this.loaded.set(true); },
    });
  }

  /** Opt into form management, seeding from the template's sample values. */
  startManaged(): void {
    this.values.set({ ...this.sample });
    this.managed.set(true);
    this.msg.set('Now form-managed — review the values and Save to render the file.');
  }

  onValues(v: Record<string, unknown>): void { this.values.set(v); }

  preview(): void {
    if (!this.tplBody) return;
    this.busy.set(true); this.err.set('');
    this.agentService.renderTemplate(this.agentId(), this.tplBody, this.values(), HAPROXY_CFG).subscribe({
      next: (resp) => { this.busy.set(false); this.rendered.set((resp.result as { data?: { rendered?: string } })?.data?.rendered || ''); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Render failed.'); },
    });
  }

  save(): void {
    if (!this.tplBody) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const resources: ConfigResource[] = [
      { type: 'template_render', path: HAPROXY_CFG, template: this.tplBody, values: this.values() },
      { type: 'config', path: SIDECAR, format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        this.validateAndReload((ok, detail) => {
          this.busy.set(false);
          if (this.dryRun()) { this.msg.set(`Preview: ${n} change(s), haproxy -c ${ok ? 'OK' : 'FAILED'} — nothing written.`); if (!ok) this.err.set(detail); return; }
          if (!ok) { this.err.set(`Written but haproxy -c FAILED: ${detail}`); return; }
          this.msg.set(`Saved ${n} change(s), HAProxy reloaded.`);
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  private validateAndReload(done: (ok: boolean, detail: string) => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['haproxy', '-c', '-f', HAPROXY_CFG] }).subscribe({
      next: (resp) => {
        const r = resp.result as { data?: { rc?: number; stderr?: string } };
        const ok = (r?.data?.rc ?? 1) === 0;
        if (this.dryRun() || !ok) { done(ok, r?.data?.stderr || ''); return; }
        this.agentService.callTool(this.agentId(), 'systemd', { name: 'haproxy', state: 'reloaded' }).subscribe({
          next: () => done(true, ''), error: () => done(true, ''),
        });
      },
      error: () => done(false, 'haproxy -c could not run'),
    });
  }
}
