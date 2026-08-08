import { Component, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';

interface Provide { capability: string; backend?: string; default_port?: number | null; }
interface Require { capability: string; backends?: string[]; fields?: Record<string, string>; }
interface BpService { name: string; kind: 'native' | 'docker'; image?: string; role?: string; template?: string; depends_on?: string[]; provides?: Provide[]; requires?: Require[]; environment?: Record<string, unknown>; values?: Record<string, unknown>; ports?: string[]; }
interface BlueprintT { id: string; name: string; description: string; status: string; services: BpService[]; }
interface WireEntry { consumer: string; provider: string; capability: string; backend?: string; set: Record<string, unknown>; }
interface Warning { service: string; kind: string; template?: string; message: string; }
interface Compiled { playbook: { name: string; steps: { name: string; module: string; args: Record<string, unknown> }[] }; order: string[]; wiring: WireEntry[]; unresolved: { consumer: string; capability: string }[]; warnings?: Warning[]; }

/**
 * Blueprint management — browse the drafts, see each service's capability
 * contract (provides/requires) + the resolved wiring, and the typed playbook the
 * blueprint compiles to (what would run to provision + configure the stack).
 */
@Component({
  selector: 'app-blueprint-manager',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-bp">
      <div class="bm-bp-list">
        <div class="bm-bp-hd"><h1>Blueprints</h1>
          <button mat-stroked-button (click)="seed()" [disabled]="busy()"><mat-icon>auto_awesome</mat-icon> Seed samples</button>
        </div>
        @for (b of blueprints(); track b.id) {
          <div class="bm-bp-card" [class.sel]="selected()?.id === b.id" (click)="select(b)">
            <div class="bm-bp-name">{{ b.name }} <span class="bm-bp-status">{{ b.status }}</span></div>
            <div class="bm-bp-desc">{{ b.description }}</div>
            <div class="bm-bp-meta">{{ b.services.length }} services · {{ kinds(b) }}</div>
          </div>
        } @empty { <p class="bm-dim">No blueprints — click “Seed samples”.</p> }
      </div>

      <div class="bm-bp-detail">
        @if (selected(); as b) {
          <h2>{{ b.name }}</h2>
          <p class="bm-dim">{{ b.description }}</p>

          <h3>Services</h3>
          <div class="bm-svc-grid">
            @for (s of b.services; track s.name) {
              <div class="bm-svc">
                <div class="bm-svc-hd">
                  <mat-icon>{{ s.kind === 'docker' ? 'inventory_2' : 'dns' }}</mat-icon>
                  <span class="bm-svc-name">{{ s.name }}</span>
                  <span class="bm-svc-kind">{{ s.kind }}</span>
                </div>
                <div class="bm-svc-ref">{{ s.image || (s.role + ' · ' + (s.template || '')) }}</div>
                @if (s.provides?.length) { <div class="bm-caps">@for (p of s.provides; track p.capability) { <span class="bm-cap bm-prov" title="provides">▲ {{ p.capability }}{{ p.backend ? ':' + p.backend : '' }}</span> }</div> }
                @if (s.requires?.length) { <div class="bm-caps">@for (r of s.requires; track r.capability) { <span class="bm-cap bm-req" title="requires">▼ {{ r.capability }}{{ r.backends?.length ? ' (' + r.backends?.join('/') + ')' : '' }}</span> }</div> }
                @if (s.depends_on?.length) { <div class="bm-dep">depends on: {{ s.depends_on?.join(', ') }}</div> }
              </div>
            }
          </div>

          @if (compiled(); as c) {
            <h3>Capability wiring</h3>
            @if (c.wiring.length) {
              <table class="bm-wire">
                <thead><tr><th>Consumer</th><th></th><th>Provider</th><th>Capability</th><th>Set</th></tr></thead>
                <tbody>
                  @for (w of c.wiring; track w.consumer + w.capability) {
                    <tr>
                      <td>{{ w.consumer }}</td><td class="bm-arrow">←</td><td>{{ w.provider }}</td>
                      <td class="bm-dim">{{ w.capability }}{{ w.backend ? ':' + w.backend : '' }}</td>
                      <td class="bm-mono">{{ setStr(w.set) }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            } @else { <p class="bm-dim">No cross-service wiring.</p> }
            @if (c.unresolved.length) {
              <p class="bm-warn">⚠ Unresolved: @for (u of c.unresolved; track u.consumer + u.capability) { <span>{{ u.consumer }} needs {{ u.capability }}; </span> }</p>
            }
            @if (c.warnings?.length) {
              <p class="bm-warn">⚠ @for (w of c.warnings; track w.service + w.kind) { <span>{{ w.service }}: {{ w.message }}; </span> }</p>
            }

            <div class="bm-bp-cphd">
              <h3>Compiled playbook <span class="bm-dim">({{ c.playbook.name }})</span></h3>
              <button mat-stroked-button (click)="saveAsRunbook()" [disabled]="busy()"><mat-icon>save</mat-icon> Save as runbook</button>
              @if (savedMsg()) { <span class="bm-ok">{{ savedMsg() }}</span> }
            </div>
            <ol class="bm-steps">
              @for (st of c.playbook.steps; track $index) {
                <li>
                  <span class="bm-step-mod">{{ st.module }}</span> {{ st.name }}
                  <pre class="bm-step-args">{{ argStr(st.args) }}</pre>
                </li>
              }
            </ol>
            <p class="bm-dim">This typed playbook is what a PXE-provisioned host (or the docker host) runs to provision + configure the whole stack — steps are ordered by dependency and the requirements are wired automatically.</p>
          } @else { <p class="bm-dim">Compiling…</p> }
        } @else { <p class="bm-dim">Pick a blueprint on the left.</p> }
      </div>
    </div>
  `,
  styles: [`
    .bm-bp { display: flex; gap: 18px; padding: 20px 24px; align-items: flex-start; }
    .bm-bp-list { flex: 0 0 300px; display: flex; flex-direction: column; gap: 8px; }
    .bm-bp-hd { display: flex; align-items: center; justify-content: space-between; }
    .bm-bp-hd h1 { margin: 0; }
    .bm-bp-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 9px 12px; cursor: pointer; }
    .bm-bp-card:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-bp-card.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-bp-name { font-weight: 600; } .bm-bp-status { font-size: 10.5px; opacity: 0.6; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 0 6px; }
    .bm-bp-desc { font-size: 12.5px; opacity: 0.8; margin: 3px 0; } .bm-bp-meta { font-size: 11.5px; opacity: 0.55; }
    .bm-bp-detail { flex: 1; min-width: 0; }
    .bm-svc-grid { display: flex; gap: 12px; flex-wrap: wrap; }
    .bm-svc { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 12px; min-width: 220px; }
    .bm-svc-hd { display: flex; align-items: center; gap: 6px; } .bm-svc-hd mat-icon { font-size: 18px; opacity: 0.8; }
    .bm-svc-name { font-weight: 600; } .bm-svc-kind { margin-left: auto; font-size: 10.5px; opacity: 0.6; text-transform: uppercase; }
    .bm-svc-ref { font-family: ui-monospace, monospace; font-size: 12px; opacity: 0.7; margin: 3px 0 6px; }
    .bm-caps { display: flex; gap: 6px; flex-wrap: wrap; margin: 3px 0; }
    .bm-cap { font-size: 11px; padding: 1px 7px; border-radius: 10px; }
    .bm-prov { background: color-mix(in srgb, var(--bm-green,#2e7d32) 20%, transparent); }
    .bm-req { background: color-mix(in srgb, #f9a825 25%, transparent); }
    .bm-dep { font-size: 11px; opacity: 0.6; margin-top: 4px; }
    .bm-wire { border-collapse: collapse; font-size: 13px; margin: 4px 0 8px; }
    .bm-wire th { text-align: left; font-size: 11px; opacity: 0.7; padding: 4px 10px; }
    .bm-wire td { padding: 4px 10px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-arrow { opacity: 0.6; } .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-steps { padding-left: 18px; } .bm-steps li { margin: 6px 0; }
    .bm-step-mod { font-family: ui-monospace, monospace; font-size: 11px; padding: 1px 6px; border-radius: 4px; background: color-mix(in srgb, var(--mat-sys-primary) 15%, transparent); margin-right: 6px; }
    .bm-step-args { margin: 4px 0 0; padding: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); border-radius: 6px; font-size: 11.5px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .bm-warn { color: #f9a825; font-size: 13px; } .bm-dim { opacity: 0.6; font-size: 13px; }
    .bm-bp-cphd { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; }
  `],
})
export class BlueprintManagerComponent {
  private http = inject(HttpClient);
  blueprints = signal<BlueprintT[]>([]);
  selected = signal<BlueprintT | null>(null);
  compiled = signal<Compiled | null>(null);
  busy = signal(false);
  savedMsg = signal('');

  constructor() { this.reload(); }

  reload(): void {
    this.http.get<BlueprintT[]>(`${environment.apiUrl}/blueprints`).subscribe((b) => this.blueprints.set(b));
  }
  seed(): void {
    this.busy.set(true);
    this.http.post(`${environment.apiUrl}/blueprints/seed-drafts`, {}).subscribe({
      next: () => { this.busy.set(false); this.reload(); }, error: () => this.busy.set(false),
    });
  }
  select(b: BlueprintT): void {
    this.selected.set(b); this.compiled.set(null); this.savedMsg.set('');
    this.http.get<Compiled>(`${environment.apiUrl}/blueprints/${b.id}/compile`).subscribe((c) => this.compiled.set(c));
  }
  saveAsRunbook(): void {
    const b = this.selected();
    if (!b) return;
    this.busy.set(true); this.savedMsg.set('');
    this.http.post<{ runbook: string; steps: number }>(`${environment.apiUrl}/blueprints/${b.id}/save-as-runbook`, {}).subscribe({
      next: (r) => { this.busy.set(false); this.savedMsg.set(`Saved runbook “${r.runbook}” (${r.steps} steps) — run it, bind it to a scope, or deliver at PXE boot.`); this.reload(); },
      error: (e) => { this.busy.set(false); this.savedMsg.set(e?.error?.detail || 'save failed'); },
    });
  }
  kinds(b: BlueprintT): string { return [...new Set(b.services.map((s) => s.kind))].join(' + '); }
  setStr(s: Record<string, unknown>): string { return Object.entries(s).map(([k, v]) => `${k}=${v}`).join(', '); }
  argStr(a: Record<string, unknown>): string {
    if (a['cmd']) return String(a['cmd']);
    return Object.entries(a).map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`).join('\n');
  }
}
