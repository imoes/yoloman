import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { forkJoin } from 'rxjs';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';
import { ParamFormComponent } from '../../../../shared/param-form/param-form.component';
import { ParamSchema } from '../../../../shared/param-form/param-form.types';

const DYNAMIC = '/etc/traefik/dynamic.yml';
const SIDECAR = '/etc/agentic-mcp/websites/traefik/traefik.json';

/**
 * Traefik config snapin — edits the DYNAMIC (file-provider) config
 * /etc/traefik/dynamic.yml as values: HTTP routers (rule -> service) and
 * services (backend URL), rendered as YAML from the traefik Class-B template.
 * Entrypoints + the file provider live in the static traefik.yml (out of scope
 * here). Traefik watches the dynamic file and hot-reloads automatically, so a
 * save just writes it (best-effort systemd reload as a safety net). Values
 * persist as a JSON sidecar; a pre-existing file shows read-only until the
 * operator opts into form management. Single-object editor (like HAProxy/Caddy).
 */
@Component({
  selector: 'app-traefik-config',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-hap">
      @if (loading()) { <p class="bm-dim">Loading Traefik config…</p> }
      @else {
        <div class="bm-hap-head">
          <strong>Traefik</strong> <span class="bm-dim">· {{ cfgPath }} (dynamic)</span>
          <span class="bm-spacer"></span>
          @if (managed()) {
            <label class="bm-tog"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
            <button mat-button (click)="preview()" [disabled]="busy()">Preview (render)</button>
            <button mat-raised-button color="primary" (click)="save()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Save' }}</button>
          }
        </div>
        @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
        @if (err()) { <p class="bm-err">{{ err() }}</p> }

        @if (!managed()) {
          <p class="bm-dim">No form-managed dynamic config yet. Configuring here writes {{ cfgPath }} (routers + services) from values; Traefik watches it and reloads automatically.</p>
          @if (raw()) { <pre class="bm-raw">{{ raw() }}</pre> }
          <button mat-stroked-button (click)="startManaged()"><mat-icon>dataset</mat-icon> Configure with form</button>
        } @else if (schema()) {
          <p class="bm-dim">Edit routers + services — the dynamic config YAML is rendered from them.</p>
          <app-param-form [params]="schema()!" [initial]="values()" [agentId]="agentId()" (valuesChange)="onValues($event)" />
          @if (rendered()) {
            <p class="bm-dim">Rendered {{ cfgPath }} (would be written):</p>
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
export class TraefikConfigComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  readonly cfgPath = DYNAMIC;
  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  managed = signal(false);
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
      tpls: this.agentService.configTemplates(),
      side: this.agentService.callTool(this.agentId(), 'config', { path: SIDECAR, format: 'json' }),
    }).subscribe({
      next: ({ tpls, side }) => {
        const tpl = tpls.templates.find((t) => t.name === 'traefik');
        this.tplBody = tpl?.template || '';
        if (tpl?.schema) this.schema.set(tpl.schema as ParamSchema);
        this.sample = (tpl?.sample as Record<string, unknown>) || {};
        const cfg = (side.result as { data?: { config?: Record<string, unknown> } })?.data?.config;
        if (cfg && Object.keys(cfg).length) {
          this.values.set(cfg); this.managed.set(true);
          this.loading.set(false); this.loaded.set(true);
        } else { this.loadRaw(); }
      },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.err.set(e?.error?.detail || 'Load failed.'); },
    });
  }

  private loadRaw(): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', DYNAMIC] }).subscribe({
      next: (resp) => { this.raw.set((resp.result as { data?: { stdout?: string } })?.data?.stdout || ''); this.managed.set(false); this.loading.set(false); this.loaded.set(true); },
      error: () => { this.raw.set(''); this.managed.set(false); this.loading.set(false); this.loaded.set(true); },
    });
  }

  startManaged(): void {
    this.values.set({ ...this.sample });
    this.managed.set(true);
    this.msg.set('Now form-managed — review routers + services and Save.');
  }

  onValues(v: Record<string, unknown>): void { this.values.set(v); }

  preview(): void {
    if (!this.tplBody) return;
    this.busy.set(true); this.err.set('');
    this.agentService.renderTemplate(this.agentId(), this.tplBody, this.values(), DYNAMIC).subscribe({
      next: (resp) => { this.busy.set(false); this.rendered.set((resp.result as { data?: { rendered?: string } })?.data?.rendered || ''); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Render failed.'); },
    });
  }

  save(): void {
    if (!this.tplBody) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const resources: ConfigResource[] = [
      { type: 'template_render', path: DYNAMIC, template: this.tplBody, values: this.values() },
      { type: 'config', path: SIDECAR, format: 'json', values: this.values() },
    ];
    this.agentService.stateApply(this.agentId(), resources, this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        // Traefik hot-reloads the file provider; a systemd reload is a best-effort safety net.
        this.agentService.callTool(this.agentId(), 'systemd', { name: 'traefik', state: 'reloaded' }).subscribe({
          next: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s); Traefik auto-reloads the dynamic config.`); },
          error: () => { this.busy.set(false); this.msg.set(`Saved ${n} change(s); Traefik watches the file and reloads automatically.`); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }
}
