import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';
import { ResourceInspectorComponent } from '../../shared/resource-inspector/resource-inspector.component';
import { ResourceKind, ResourceRef } from '../../core/services/resource.service';

/**
 * The host's Resources — the ONE generic surface over everything on this machine
 * that answers the Resource protocol (docs/resource-protocol.md), in the same
 * three-column Miller shape as Configuration/Management:
 *
 *   kind (Config / Containers / Helm / …)  →  instances (+ live search + drift)  →  the generic inspector
 *
 * The inspector is kind-agnostic: its tabs ARE the protocol verbs (Values/schema,
 * State/observe, Preview/plan, Generations/apply+rollback). Kinds that already
 * have a rich domain tab (config → Configuration, docker → Docker state) deep-link
 * there for editing; kinds without one (Helm, and future package/service/user/cron)
 * are edited fully in the generic inspector. Adding a kind = one KINDS entry + a
 * backend resource adapter.
 */
interface KindSource {
  kind: ResourceKind;
  label: string;
  icon: string;
  description: string;
  /** Path under /agents/{id} that lists this kind. */
  list: string;
  /** Pull the instance names out of that endpoint's body (shapes differ per kind). */
  names: (body: unknown) => { name: string; namespace?: string }[];
  /** If the kind has a rich domain tab/page, where "Open editor" jumps to. */
  deepLink?: (agentId: string) => { path: string; query?: Record<string, string>; label: string };
}

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const pick = (body: unknown, key: string): unknown[] => {
  if (Array.isArray(body)) return body;
  const o = (body ?? {}) as Record<string, unknown>;
  return asArray(o[key]);
};
const nameOf = (item: unknown, field = 'name'): string => {
  if (typeof item === 'string') return item;
  const o = (item ?? {}) as Record<string, unknown>;
  return String(o[field] ?? '');
};

const KINDS: KindSource[] = [
  {
    kind: 'config', label: 'Config files', icon: 'description',
    description: 'Managed config files on this host — the same set the Configuration tab edits, here as Resource-protocol objects (observe/plan/apply/rollback). Edit richly in Configuration.',
    list: 'config-desired',
    names: (b) => pick(b, 'resources').map((r) => ({ name: nameOf(r, 'path') })).filter((r) => r.name),
    deepLink: (id) => ({ path: `/hosts/${id}`, query: { tab: 'configuration' }, label: 'Open in Configuration' }),
  },
  {
    kind: 'docker', label: 'Containers', icon: 'inventory_2',
    description: 'Docker containers recovered as portable, versioned specs (image/env/ports/volumes). Full generation history + rollback lives in the Docker state page.',
    list: 'docker/containers',
    names: (b) => pick(b, 'containers').map((c) => ({ name: nameOf(c) })).filter((r) => r.name),
    deepLink: () => ({ path: '/docker-state', label: 'Open in Docker state' }),
  },
  {
    kind: 'helm', label: 'Helm releases', icon: 'deployed_code',
    description: 'Helm releases on this host. No dedicated tab — this generic inspector is their home: see the values (schema), what is deployed (observe), a diff before upgrade (plan), and the release history (generations/rollback).',
    list: 'helm/releases',
    names: (b) => pick(b, 'releases').map((r) => {
      const o = (r ?? {}) as Record<string, unknown>;
      return { name: nameOf(r), namespace: o['namespace'] ? String(o['namespace']) : undefined };
    }).filter((r) => r.name),
  },
];

interface Row { kind: ResourceKind; label: string; name: string; namespace?: string }

@Component({
  selector: 'app-host-resources',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ResourceInspectorComponent],
  template: `
    <p class="bm-hr-lead">Everything on this host that answers the <strong>Resource protocol</strong> — one uniform place, one inspector whose tabs are the verbs. Pick a kind, then an instance.</p>
    <div class="bm-hr">
      <!-- Column 1: resource kind -->
      <aside class="bm-hr-kinds">
        @for (k of kinds; track k.kind) {
          <div class="bm-hr-kind" [class.on]="activeKind() === k.kind" (click)="activeKind.set(k.kind)">
            <mat-icon class="bm-hr-kind-ic">{{ k.icon }}</mat-icon>
            <span class="bm-hr-kind-lbl">{{ k.label }}</span>
            <span class="bm-hr-kind-n">{{ rowsOf(k.kind).length }}</span>
          </div>
        }
      </aside>

      <!-- Column 2: instances of the active kind + live search + drift status -->
      <aside class="bm-hr-list">
        <input class="bm-hr-search" type="search" placeholder="filter…" [ngModel]="search()" (ngModelChange)="search.set($event)" />
        @for (row of visibleRows(); track row.kind + row.name + (row.namespace || '')) {
          <button type="button" class="bm-hr-item" [class.on]="isSelected(row)" (click)="select(row)">
            <span class="bm-hr-dot" [class.drift]="isDrifted(row)" [title]="isDrifted(row) ? 'drifted from desired' : 'in sync'"></span>
            <span class="bm-hr-name">{{ row.name }}</span>
            @if (row.namespace) { <span class="bm-hr-ns">{{ row.namespace }}</span> }
          </button>
        } @empty {
          <p class="bm-hr-empty">{{ loading() ? 'loading…' : 'no ' + activeLabel().toLowerCase() }}</p>
        }
      </aside>

      <!-- Column 3: the generic inspector (+ deep-link to the rich tab when one exists) -->
      <section class="bm-hr-insp">
        <div class="bm-hr-kind-desc">{{ activeDescription() }}</div>
        @if (selectedRef(); as ref) {
          @if (activeDeepLink(); as dl) {
            <div class="bm-hr-deeplink">
              <span>This kind has a dedicated editor.</span>
              <button mat-stroked-button (click)="openDeepLink()"><mat-icon>open_in_new</mat-icon> {{ dl.label }}</button>
            </div>
          }
          <app-resource-inspector [ref]="ref" />
        } @else {
          <p class="bm-hr-empty">Pick an instance on the left. Every kind opens in the same inspector — its tabs are the protocol verbs: Values (schema), State (observe), Preview (plan), Generations (apply/rollback).</p>
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-hr-lead { opacity: 0.72; font-size: 13px; margin: 0 0 12px; max-width: 820px; }
    .bm-hr { display: grid; grid-template-columns: 190px 260px minmax(0, 1fr); gap: 14px; align-items: start; }
    @media (max-width: 1100px) { .bm-hr { grid-template-columns: 160px 1fr; } .bm-hr-insp { grid-column: 1 / -1; } }
    .bm-hr-kinds, .bm-hr-list { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 6px; max-height: 520px; overflow: auto; }
    .bm-hr-kind { display: flex; align-items: center; gap: 8px; padding: 8px 9px; border-radius: 7px; cursor: pointer; }
    .bm-hr-kind:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-hr-kind.on { background: color-mix(in srgb, var(--mat-sys-primary) 13%, transparent); }
    .bm-hr-kind-ic { font-size: 18px; height: 18px; width: 18px; opacity: 0.8; }
    .bm-hr-kind-lbl { flex: 1; font-size: 13px; }
    .bm-hr-kind-n { font-size: 11px; opacity: 0.55; }
    .bm-hr-search { width: 100%; box-sizing: border-box; padding: 6px 9px; margin-bottom: 6px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: transparent; color: inherit; }
    .bm-hr-item { display: flex; align-items: center; gap: 7px; width: 100%; text-align: left; background: none; border: 0; border-radius: 6px; padding: 5px 8px; color: inherit; cursor: pointer; font: inherit; }
    .bm-hr-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-hr-item.on { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-hr-dot { width: 8px; height: 8px; border-radius: 50%; flex: 0 0 auto; background: #66bb6a; }
    .bm-hr-dot.drift { background: #f9a825; }
    .bm-hr-name { flex: 1; min-width: 0; font-size: 12.5px; font-family: ui-monospace, monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-hr-ns { font-size: 10.5px; opacity: 0.5; }
    .bm-hr-empty { opacity: .6; font-size: 12.5px; padding: 4px 8px; }
    .bm-hr-insp { min-width: 0; }
    .bm-hr-kind-desc { font-size: 12px; opacity: 0.72; margin-bottom: 10px; line-height: 1.45; }
    .bm-hr-deeplink { display: flex; align-items: center; gap: 10px; font-size: 12.5px; padding: 8px 10px; margin-bottom: 10px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
  `],
})
export class HostResourcesComponent {
  private http = inject(HttpClient);
  private router = inject(Router);
  agentId = input.required<string>();

  kinds = KINDS;
  activeKind = signal<ResourceKind>('config');
  search = signal('');
  private rows = signal<Row[]>([]);
  loading = signal(false);
  private selected = signal<Row | null>(null);
  /** Config file paths currently drifted from desired (host config-drift) → yellow dot. */
  private driftPaths = signal<Set<string>>(new Set());

  constructor() {
    effect(() => {
      const id = this.agentId();
      this.rows.set([]);
      this.selected.set(null);
      this.driftPaths.set(new Set());
      if (!id) return;
      this.loading.set(true);
      let pending = KINDS.length;
      const done = () => { if (--pending === 0) this.loading.set(false); };
      for (const k of KINDS) {
        this.http.get<unknown>(`${environment.apiUrl}/agents/${id}/${k.list}`).subscribe({
          next: (body) => {
            const add = k.names(body).map((n) => ({ kind: k.kind, label: k.label, ...n }));
            if (add.length) this.rows.update((r) => [...r, ...add]);
            done();
          },
          error: () => done(),
        });
      }
      // Config drift → status dots for the config kind (cheap, one call).
      this.http.get<{ drift?: { path: string }[] }>(`${environment.apiUrl}/agents/${id}/config-drift`).subscribe({
        next: (d) => this.driftPaths.set(new Set((d.drift ?? []).map((c) => c.path))),
        error: () => {},
      });
    });
  }

  rowsOf(kind: ResourceKind): Row[] { return this.rows().filter((r) => r.kind === kind); }
  private activeKindDef = computed(() => KINDS.find((k) => k.kind === this.activeKind()) ?? KINDS[0]);
  activeLabel = computed(() => this.activeKindDef().label);
  activeDescription = computed(() => this.activeKindDef().description);
  activeDeepLink = computed(() => this.activeKindDef().deepLink?.(this.agentId()) ?? null);

  visibleRows = computed<Row[]>(() => {
    const q = this.search().trim().toLowerCase();
    return this.rowsOf(this.activeKind())
      .filter((r) => !q || r.name.toLowerCase().includes(q) || (r.namespace || '').toLowerCase().includes(q))
      .sort((a, b) => a.name.localeCompare(b.name));
  });

  isDrifted(row: Row): boolean { return row.kind === 'config' && this.driftPaths().has(row.name); }
  isSelected(row: Row): boolean {
    const s = this.selected();
    return !!s && s.kind === row.kind && s.name === row.name && (s.namespace || '') === (row.namespace || '');
  }
  select(row: Row): void { this.selected.set(row); }

  openDeepLink(): void {
    const dl = this.activeDeepLink();
    if (dl) this.router.navigate([dl.path], dl.query ? { queryParams: dl.query } : {});
  }

  selectedRef = computed<ResourceRef | null>(() => {
    const s = this.selected();
    return s ? { agentId: this.agentId(), kind: s.kind, name: s.name, namespace: s.namespace } : null;
  });
}
