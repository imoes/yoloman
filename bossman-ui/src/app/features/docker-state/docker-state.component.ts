import { Component, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';

interface HostRow { id: string; name: string; }
interface ContainerSpec {
  name: string; image: string; restart: string;
  ports?: { host: string; container: string }[];
  env?: Record<string, string>; volumes?: string[];
  compose_project?: string | null; compose_service?: string | null;
}
interface GenRow { generation: number; count: number; config_hash: string; source: string; note: string | null; created_by: string | null; created_at: string; }
interface StateDoc { generation: number | null; spec: { containers: ContainerSpec[]; compose_files?: string[] }; source?: string; created_at?: string; }
interface DiffRes { from: number; to: number; added: string[]; removed: string[]; changed: { name: string; fields: string[] }[]; }
interface ConvergePlan { target_generation: number; create: string[]; remove: string[]; recreate: string[]; actions: number; }

/**
 * Docker → desired state (project-docker-desired-state): discover a host's
 * containers as a portable, versioned desired state — every snapshot a
 * GENERATION — then diff two generations, roll back, and preview convergence.
 * The container fleet gets the same time-machine as config.
 */
@Component({
  selector: 'app-docker-state',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule],
  template: `
    <div class="ds">
      <div class="ds-hd">
        <h1>Docker desired state</h1>
        <div class="ds-tools">
          <select [ngModel]="hostId()" (ngModelChange)="selectHost($event)">
            <option value="" disabled selected>Choose host…</option>
            @for (h of hosts(); track h.id) { <option [value]="h.id">{{ h.name }}</option> }
          </select>
          <button mat-flat-button color="primary" (click)="discover()" [disabled]="!hostId() || busy()">
            <mat-icon>cameraswitch</mat-icon> {{ busy() ? 'Discovering…' : 'Discover / snapshot' }}
          </button>
        </div>
      </div>
      <p class="ds-dim">Discovering recovers every container via <code>docker inspect</code> as a re-appliable spec and stores it as a new generation only when the set changed. Roll back to any earlier snapshot; convergence to it is a separate, explicit apply.</p>
      @if (msg()) { <p class="ds-ok">{{ msg() }}</p> }

      @if (hostId()) {
        <div class="ds-body">
          <div class="ds-gens">
            <h3>Generations</h3>
            @for (g of gens(); track g.generation) {
              <div class="ds-gen" [class.sel]="viewGen() === g.generation" (click)="viewGeneration(g.generation)">
                <span class="ds-gnum">gen {{ g.generation }}</span>
                <span class="ds-gsrc" [class.rb]="g.source === 'rollback'">{{ g.source }}</span>
                <span class="ds-gcount">{{ g.count }} container{{ g.count === 1 ? '' : 's' }}</span>
                <span class="ds-gwhen">{{ when(g.created_at) }}</span>
                <button mat-icon-button class="ds-rb" title="Roll back to this generation"
                        (click)="rollback(g.generation, $event)" [disabled]="busy()"><mat-icon>history</mat-icon></button>
              </div>
            } @empty { <p class="ds-dim">No snapshots yet — click “Discover / snapshot”.</p> }

            @if (gens().length >= 2) {
              <div class="ds-diffbar">
                <span>Diff</span>
                <select [ngModel]="diffFrom()" (ngModelChange)="diffFrom.set(+$event)">
                  @for (g of gens(); track g.generation) { <option [value]="g.generation">gen {{ g.generation }}</option> }
                </select>
                <span>→</span>
                <select [ngModel]="diffTo()" (ngModelChange)="diffTo.set(+$event)">
                  @for (g of gens(); track g.generation) { <option [value]="g.generation">gen {{ g.generation }}</option> }
                </select>
                <button mat-stroked-button (click)="runDiff()" [disabled]="busy()">Compare</button>
              </div>
              @if (diff(); as d) {
                <div class="ds-diff">
                  @if (d.added.length) { <p><span class="ds-add">+ {{ d.added.join(', ') }}</span></p> }
                  @if (d.removed.length) { <p><span class="ds-rem">− {{ d.removed.join(', ') }}</span></p> }
                  @for (c of d.changed; track c.name) { <p><span class="ds-chg">~ {{ c.name }}</span> <span class="ds-dim">({{ c.fields.join(', ') }})</span></p> }
                  @if (!d.added.length && !d.removed.length && !d.changed.length) { <p class="ds-dim">Identical.</p> }
                </div>
              }
            }
          </div>

          <div class="ds-detail">
            @if (doc(); as s) {
              <div class="ds-dhd">
                <h3>{{ s.generation !== null ? 'Generation ' + s.generation : 'No snapshot' }}</h3>
                @if (viewGen() !== null) {
                  <button mat-stroked-button (click)="convergePlan()" [disabled]="busy()"><mat-icon>bolt</mat-icon> Converge plan</button>
                }
              </div>
              @if (plan(); as p) {
                <div class="ds-plan">
                  <b>Converge to gen {{ p.target_generation }}:</b>
                  @if (p.actions === 0) { <span class="ds-ok"> host already matches ✓</span> }
                  @else {
                    @if (p.create.length) { <span class="ds-add"> create {{ p.create.join(', ') }};</span> }
                    @if (p.recreate.length) { <span class="ds-chg"> recreate {{ p.recreate.join(', ') }};</span> }
                    @if (p.remove.length) { <span class="ds-rem"> remove {{ p.remove.join(', ') }};</span> }
                  }
                </div>
              }
              <table class="ds-tbl">
                <thead><tr><th>Container</th><th>Image</th><th>Ports</th><th>Restart</th><th>Compose</th></tr></thead>
                <tbody>
                  @for (c of s.spec.containers; track c.name) {
                    <tr>
                      <td class="ds-mono">{{ c.name }}</td>
                      <td class="ds-mono">{{ c.image }}</td>
                      <td class="ds-mono">{{ portStr(c) }}</td>
                      <td>{{ c.restart }}</td>
                      <td class="ds-dim">{{ c.compose_project ? c.compose_project + '/' + c.compose_service : '—' }}</td>
                    </tr>
                  } @empty { <tr><td colspan="5" class="ds-dim">No containers in this generation.</td></tr> }
                </tbody>
              </table>
            } @else { <p class="ds-dim">Pick a generation.</p> }
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    .ds { padding: 18px 22px; }
    .ds-hd { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
    .ds-hd h1 { margin: 0; }
    .ds-tools { display: flex; align-items: center; gap: 10px; }
    .ds-tools select { padding: 7px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; background: transparent; color: inherit; min-width: 200px; }
    .ds-dim { opacity: 0.62; font-size: 13px; } .ds-dim code { font-family: ui-monospace, monospace; }
    .ds-ok { color: var(--bm-green,#2e7d32); font-size: 13px; }
    .ds-body { display: flex; gap: 18px; align-items: flex-start; }
    .ds-gens { flex: 0 0 380px; }
    .ds-gen { display: flex; align-items: center; gap: 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 6px 10px; margin-bottom: 6px; cursor: pointer; font-size: 12.5px; }
    .ds-gen:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .ds-gen.sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .ds-gnum { font-weight: 600; } .ds-gcount { opacity: 0.8; } .ds-gwhen { margin-left: auto; opacity: 0.55; }
    .ds-gsrc { font-size: 10px; text-transform: uppercase; padding: 1px 6px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .ds-gsrc.rb { background: color-mix(in srgb, #f9a825 30%, transparent); color: #7a5300; }
    .ds-rb { transform: scale(0.8); }
    .ds-diffbar { display: flex; align-items: center; gap: 8px; margin: 10px 0 6px; font-size: 12.5px; }
    .ds-diffbar select { padding: 3px 6px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: transparent; color: inherit; }
    .ds-diff { font-size: 12.5px; } .ds-diff p { margin: 2px 0; }
    .ds-add { color: #2e7d32; } .ds-rem { color: #c62828; } .ds-chg { color: #b57a00; }
    .ds-detail { flex: 1; min-width: 0; }
    .ds-dhd { display: flex; align-items: center; gap: 12px; } .ds-dhd h3 { margin: 0; }
    .ds-plan { margin: 8px 0; font-size: 13px; padding: 8px 10px; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .ds-tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; margin-top: 8px; }
    .ds-tbl th { text-align: left; font-size: 11px; opacity: 0.7; padding: 4px 10px; }
    .ds-tbl td { padding: 4px 10px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .ds-mono { font-family: ui-monospace, monospace; }
  `],
})
export class DockerStateComponent {
  private http = inject(HttpClient);
  hosts = signal<HostRow[]>([]);
  hostId = signal('');
  gens = signal<GenRow[]>([]);
  doc = signal<StateDoc | null>(null);
  viewGen = signal<number | null>(null);
  diff = signal<DiffRes | null>(null);
  diffFrom = signal(1);
  diffTo = signal(1);
  plan = signal<ConvergePlan | null>(null);
  busy = signal(false);
  msg = signal('');

  constructor() {
    this.http.get<HostRow[] | { hosts: HostRow[] }>(`${environment.apiUrl}/fleet/hosts`).subscribe((r) => {
      const list = Array.isArray(r) ? r : r.hosts;
      this.hosts.set((list || []).map((h) => ({ id: h.id, name: h.name })));
    });
  }

  selectHost(id: string): void {
    this.hostId.set(id); this.doc.set(null); this.diff.set(null); this.plan.set(null); this.viewGen.set(null); this.msg.set('');
    this.reloadGens();
  }
  private reloadGens(): void {
    if (!this.hostId()) return;
    this.http.get<{ generations: GenRow[] }>(`${environment.apiUrl}/agents/${this.hostId()}/docker-state/generations`)
      .subscribe((r) => {
        this.gens.set(r.generations || []);
        if (r.generations?.length) {
          this.diffTo.set(r.generations[0].generation);
          this.diffFrom.set(r.generations[Math.min(1, r.generations.length - 1)].generation);
          this.viewGeneration(r.generations[0].generation);
        }
      });
  }
  discover(): void {
    this.busy.set(true); this.msg.set('');
    this.http.post<{ changed: boolean; generation: number; count: number }>(
      `${environment.apiUrl}/agents/${this.hostId()}/docker-state/discover`, {}).subscribe({
      next: (r) => {
        this.busy.set(false);
        this.msg.set(r.changed ? `Snapshot gen ${r.generation} — ${r.count} container(s).` : `No change (still gen ${r.generation}, ${r.count} container(s)).`);
        this.reloadGens();
      },
      error: (e) => { this.busy.set(false); this.msg.set(e?.error?.detail || 'discover failed'); },
    });
  }
  viewGeneration(gen: number): void {
    this.viewGen.set(gen); this.plan.set(null);
    this.http.get<StateDoc>(`${environment.apiUrl}/agents/${this.hostId()}/docker-state?generation=${gen}`)
      .subscribe((s) => this.doc.set(s));
  }
  runDiff(): void {
    this.http.get<DiffRes>(`${environment.apiUrl}/agents/${this.hostId()}/docker-state/diff?from=${this.diffFrom()}&to=${this.diffTo()}`)
      .subscribe((d) => this.diff.set(d));
  }
  rollback(gen: number, ev: Event): void {
    ev.stopPropagation();
    if (!confirm(`Roll back desired state to generation ${gen}? (writes it forward as a new generation)`)) return;
    this.busy.set(true);
    this.http.post<{ generation: number }>(`${environment.apiUrl}/agents/${this.hostId()}/docker-state/rollback`, { generation: gen })
      .subscribe({
        next: (r) => { this.busy.set(false); this.msg.set(`Rolled back — new gen ${r.generation}.`); this.reloadGens(); },
        error: (e) => { this.busy.set(false); this.msg.set(e?.error?.detail || 'rollback failed'); },
      });
  }
  convergePlan(): void {
    this.busy.set(true);
    this.http.get<ConvergePlan>(`${environment.apiUrl}/agents/${this.hostId()}/docker-state/converge-plan?generation=${this.viewGen()}`)
      .subscribe({ next: (p) => { this.busy.set(false); this.plan.set(p); }, error: () => this.busy.set(false) });
  }

  portStr(c: ContainerSpec): string { return (c.ports || []).map((p) => `${p.host}:${p.container}`).join(', ') || '—'; }
  when(iso: string): string { try { return new Date(iso).toLocaleString(); } catch { return iso; } }
}
