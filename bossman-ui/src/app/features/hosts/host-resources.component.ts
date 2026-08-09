import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';
import { ResourceInspectorComponent } from '../../shared/resource-inspector/resource-inspector.component';
import { ResourceKind, ResourceRef } from '../../core/services/resource.service';

/**
 * The host's Resources: everything on this machine that answers the Resource protocol, listed by kind and
 * opened in the ONE generic inspector (docs/ui-workspaces.md slice 2).
 *
 * This component only LISTS (each kind has its own list endpoint); it deliberately knows nothing about how
 * a resource is edited, previewed, applied or rolled back — that is the inspector's job, and the inspector
 * is kind-agnostic. Adding a kind here is one entry in KINDS.
 */
interface KindSource {
  kind: ResourceKind;
  label: string;
  /** Path under /agents/{id} that lists this kind. */
  list: string;
  /** Pull the instance names out of that endpoint's body (shapes differ per kind). */
  names: (body: unknown) => { name: string; namespace?: string }[];
}

const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const pick = (body: unknown, key: string): unknown[] => {
  if (Array.isArray(body)) return body;
  const o = (body ?? {}) as Record<string, unknown>;
  return asArray(o[key]);
};
/** List items are either bare names or objects carrying one — accept both. */
const nameOf = (item: unknown, field = 'name'): string => {
  if (typeof item === 'string') return item;
  const o = (item ?? {}) as Record<string, unknown>;
  return String(o[field] ?? '');
};

const KINDS: KindSource[] = [
  {
    kind: 'config', label: 'Config files', list: 'config-desired',
    names: (b) => pick(b, 'resources').map((r) => ({ name: nameOf(r, 'path') })).filter((r) => r.name),
  },
  {
    kind: 'docker', label: 'Containers', list: 'docker/containers',
    names: (b) => pick(b, 'containers').map((c) => ({ name: nameOf(c) })).filter((r) => r.name),
  },
  {
    kind: 'helm', label: 'Helm releases', list: 'helm/releases',
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
  imports: [MatIconModule, ResourceInspectorComponent],
  template: `
    <div class="bm-hr">
      <aside class="bm-hr-list">
        @for (k of kinds; track k.kind) {
          <div class="bm-hr-group">{{ k.label }}</div>
          @for (row of rowsOf(k.kind); track row.kind + row.name) {
            <button type="button" class="bm-hr-item" [class.on]="isSelected(row)" (click)="select(row)">
              <span class="bm-hr-name">{{ row.name }}</span>
            </button>
          } @empty {
            <p class="bm-hr-empty">{{ loading() ? 'loading…' : 'none' }}</p>
          }
        }
      </aside>
      <section class="bm-hr-insp">
        @if (selectedRef(); as ref) {
          <app-resource-inspector [ref]="ref" />
        } @else {
          <p class="bm-hr-empty">Pick a resource on the left. Every kind opens in the same inspector —
            its tabs are the protocol verbs: Values (schema), State (observe), Preview (plan),
            Generations (apply/rollback).</p>
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-hr { display: grid; grid-template-columns: 260px minmax(0, 1fr); gap: 14px; align-items: start; }
    @media (max-width: 1000px) { .bm-hr { grid-template-columns: 1fr; } }
    .bm-hr-list { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 8px;
      max-height: 460px; overflow: auto; }
    .bm-hr-group { font-size: 10.5px; text-transform: uppercase; letter-spacing: .05em; opacity: .55;
      padding: 8px 6px 4px; }
    .bm-hr-item { display: block; width: 100%; text-align: left; background: none; border: 0;
      border-radius: 6px; padding: 5px 8px; color: inherit; cursor: pointer; font: inherit; }
    .bm-hr-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-hr-item.on { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .bm-hr-name { font-size: 12.5px; font-family: ui-monospace, monospace; word-break: break-all; }
    .bm-hr-empty { opacity: .6; font-size: 12.5px; padding: 4px 8px; }
  `],
})
export class HostResourcesComponent {
  private http = inject(HttpClient);
  agentId = input.required<string>();

  kinds = KINDS;
  private rows = signal<Row[]>([]);
  loading = signal(false);
  private selected = signal<Row | null>(null);

  constructor() {
    effect(() => {
      const id = this.agentId();
      this.rows.set([]);
      this.selected.set(null);
      if (!id) return;
      this.loading.set(true);
      let pending = KINDS.length;
      const done = () => { if (--pending === 0) this.loading.set(false); };
      for (const k of KINDS) {
        // A kind whose tool is absent on this host (no docker, no helm) simply contributes nothing —
        // an error here is "not applicable", never a broken tab.
        this.http.get<unknown>(`${environment.apiUrl}/agents/${id}/${k.list}`).subscribe({
          next: (body) => {
            const add = k.names(body).map((n) => ({ kind: k.kind, label: k.label, ...n }));
            if (add.length) this.rows.update((r) => [...r, ...add]);
            done();
          },
          error: () => done(),
        });
      }
    });
  }

  rowsOf(kind: ResourceKind): Row[] { return this.rows().filter((r) => r.kind === kind); }
  isSelected(row: Row): boolean {
    const s = this.selected();
    return !!s && s.kind === row.kind && s.name === row.name;
  }
  select(row: Row): void { this.selected.set(row); }

  selectedRef = computed<ResourceRef | null>(() => {
    const s = this.selected();
    return s ? { agentId: this.agentId(), kind: s.kind, name: s.name, namespace: s.namespace } : null;
  });
}
