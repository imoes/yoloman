import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { ParamFormComponent } from '../../shared/param-form/param-form.component';
import { ParamSchema, ParamSpec } from '../../shared/param-form/param-form.types';

interface DockerVar { name: string; type: string; default?: unknown; required?: boolean; secret?: boolean; choices?: string[]; description?: string; }
interface DockerTemplate { image: string; name: string; description: string; variables: DockerVar[]; ports: string[]; volumes: string[]; popularity: number; }

/**
 * Docker app catalog — deploy a container from the store with its README-extracted
 * variables rendered as a typed directive form (the same ParamForm the config
 * templates use). Pick a host, fill the env knobs, deploy (dry-run first).
 */
@Component({
  selector: 'app-docker-apps',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ParamFormComponent],
  template: `
    <div class="bm-da">
      <div class="bm-da-list">
        <div class="bm-da-hd">
          <h1>Docker apps</h1>
          <input class="bm-da-search" type="search" placeholder="Filter…" [ngModel]="q()" (ngModelChange)="q.set($event)" />
        </div>
        @for (t of filtered(); track t.image) {
          <div class="bm-da-card" [class.sel]="selected()?.image === t.image" (click)="select(t)">
            <div class="bm-da-name">{{ t.name }}</div>
            <div class="bm-da-img">{{ t.image }}</div>
            <div class="bm-da-desc">{{ t.description }}</div>
            <div class="bm-da-meta">{{ t.variables.length }} vars · {{ t.ports.length }} ports</div>
          </div>
        } @empty { <p class="bm-dim">No docker templates yet — run the extract-batch to populate the catalog.</p> }
      </div>

      <div class="bm-da-detail">
        @if (selected(); as t) {
          <h2>{{ t.name }} <span class="bm-da-img">{{ t.image }}</span></h2>
          <p class="bm-dim">{{ t.description }}</p>
          <div class="bm-da-row">
            <label>Host
              <select [ngModel]="host()" (ngModelChange)="host.set($event)">
                <option value="" disabled>— pick a host —</option>
                @for (h of hosts(); track h.id) { <option [value]="h.id">{{ h.name }}</option> }
              </select>
            </label>
            <label>Container name<input [ngModel]="cname()" (ngModelChange)="cname.set($event)" [placeholder]="t.name" /></label>
            <label class="bm-chk"><input type="checkbox" [ngModel]="dryRun()" (ngModelChange)="dryRun.set($event)" /> dry-run</label>
          </div>

          @if (schemaKeys().length) {
            <h3>Configuration</h3>
            <app-param-form [params]="schema()" [initial]="values()" (valuesChange)="values.set($event)" />
          } @else { <p class="bm-dim">This image documents no configurable variables.</p> }

          @if (t.ports.length || t.volumes.length) {
            <p class="bm-dim">Ports {{ t.ports.join(', ') || '—' }} · Volumes {{ t.volumes.join(', ') || '—' }}</p>
          }

          <div class="bm-da-actions">
            <button mat-flat-button color="primary" [disabled]="!host() || busy()" (click)="deploy()">
              <mat-icon>rocket_launch</mat-icon> {{ busy() ? 'Deploying…' : (dryRun() ? 'Preview' : 'Deploy') }}
            </button>
            @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
            @if (err()) { <span class="bm-err">{{ err() }}</span> }
          </div>
          @if (out()) { <pre class="bm-da-out">{{ out() }}</pre> }
        } @else { <p class="bm-dim">Pick a container on the left.</p> }
      </div>
    </div>
  `,
  styles: [`
    .bm-da { display: flex; gap: 18px; padding: 20px 24px; align-items: flex-start; }
    .bm-da-list { flex: 0 0 320px; max-height: 82vh; overflow-y: auto; display: flex; flex-direction: column; gap: 8px; }
    .bm-da-hd h1 { margin: 0 0 8px; }
    .bm-da-search { width: 100%; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; margin-bottom: 6px; }
    .bm-da-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 9px 12px; cursor: pointer; }
    .bm-da-card:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-da-card.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-da-name { font-weight: 600; }
    .bm-da-img { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.7; }
    .bm-da-desc { font-size: 12.5px; opacity: 0.8; margin: 3px 0; }
    .bm-da-meta { font-size: 11.5px; opacity: 0.55; }
    .bm-da-detail { flex: 1; min-width: 0; }
    .bm-da-row { display: flex; gap: 16px; flex-wrap: wrap; align-items: flex-end; margin: 10px 0; }
    .bm-da-row label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; }
    .bm-da-row select, .bm-da-row input { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-chk { flex-direction: row !important; align-items: center; gap: 6px; }
    .bm-da-actions { display: flex; align-items: center; gap: 12px; margin-top: 14px; }
    .bm-da-out { margin-top: 12px; padding: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 6px; font-size: 12px; white-space: pre-wrap; max-height: 300px; overflow: auto; }
    .bm-dim { opacity: 0.6; font-size: 13px; }
    .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class DockerAppsComponent {
  private http = inject(HttpClient);
  private agentService = inject(AgentService);

  templates = signal<DockerTemplate[]>([]);
  hosts = signal<Agent[]>([]);
  q = signal('');
  selected = signal<DockerTemplate | null>(null);
  values = signal<Record<string, unknown>>({});
  host = signal(''); cname = signal(''); dryRun = signal(true);
  busy = signal(false); msg = signal(''); err = signal(''); out = signal('');

  filtered = computed(() => {
    const ql = this.q().trim().toLowerCase();
    const all = this.templates();
    return ql ? all.filter((t) => t.image.toLowerCase().includes(ql) || t.description.toLowerCase().includes(ql)) : all;
  });
  schema = signal<ParamSchema>({});
  schemaKeys = computed(() => Object.keys(this.schema()));

  constructor() {
    this.http.get<DockerTemplate[]>(`${environment.apiUrl}/docker/app-templates`).subscribe((t) => this.templates.set(t));
    this.agentService.list().subscribe((a) => this.hosts.set(a.filter((h) => h.address)));
  }

  private specOf(v: DockerVar): ParamSpec {
    const type: ParamSpec['type'] = v.type === 'int' || v.type === 'port' ? 'number' : v.type === 'bool' ? 'bool' : 'string';
    const spec: ParamSpec = { type, description: v.description, required: v.required, secret: v.secret };
    if (v.type === 'enum' && v.choices?.length) spec.enum = v.choices;
    if (v.default !== undefined && v.default !== '') spec.default = v.default;
    return spec;
  }

  select(t: DockerTemplate): void {
    this.selected.set(t);
    this.cname.set(t.name);
    this.msg.set(''); this.err.set(''); this.out.set('');
    const schema: ParamSchema = {};
    const init: Record<string, unknown> = {};
    for (const v of t.variables) {
      schema[v.name] = this.specOf(v);
      if (v.default !== undefined && v.default !== '') init[v.name] = v.default;
    }
    this.schema.set(schema);
    this.values.set(init);
  }

  deploy(): void {
    const t = this.selected();
    if (!t || !this.host()) return;
    const env: Record<string, string> = {};
    for (const [k, val] of Object.entries(this.values())) {
      if (val !== '' && val !== null && val !== undefined) env[k] = String(val);
    }
    const ports = t.ports.map((p) => ({ host: p, container: p }));
    this.busy.set(true); this.msg.set(''); this.err.set(''); this.out.set('');
    this.agentService.dockerDeploy(this.host(), {
      name: this.cname().trim() || t.name, image: t.image, env, ports, volumes: t.volumes, dry_run: this.dryRun(),
    }).subscribe({
      next: (r) => {
        this.busy.set(false);
        this.msg.set(this.dryRun() ? 'Preview OK' : 'Deployed.');
        this.out.set(r.command || [r.stdout, r.stderr].filter(Boolean).join('\n') || JSON.stringify(r, null, 2));
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'deploy failed'); },
    });
  }
}
