import { Component, computed, inject, signal } from '@angular/core';
import { JsonPipe } from '@angular/common';
import { AgentService } from '../../core/services/agent.service';
import { ConfigTemplate } from '../../core/models/agent.model';

/** Block F3 — the Class-B config template catalog (Setup → Config templates).
 * A read-only reference browser over configs/config_templates/: pick a
 * template to see its schema (the editable variables), sample values, and the
 * Jinja2 source. Binding + preview + apply against a host happen in the host's
 * Configuration tab (K2). */
@Component({
  selector: 'app-config-templates',
  standalone: true,
  imports: [JsonPipe],
  template: `
    <div class="bm-page">
      <h1>Config templates</h1>
      <p class="bm-dim">
        Class-B templates: a whole config file rendered from high-level values (Jinja2). Bind one to a
        discovered file — and edit its values as a form — in a host's <strong>Configuration</strong> tab.
      </p>
      @if (templates().length) {
        <div class="bm-ct">
          <div class="bm-ct-list">
            @for (t of templates(); track t.name) {
              <div class="bm-ct-item" [class.bm-ct-sel]="selected()?.name === t.name" (click)="select(t)">
                <span class="bm-ct-name">{{ t.name }}</span>
                <span class="bm-dim">{{ keyCount(t) }} vars</span>
              </div>
            }
          </div>
          <div class="bm-ct-detail">
            @if (selected(); as t) {
              <h2>{{ t.name }}</h2>
              <h3>Variables (schema)</h3>
              <table class="bm-ct-schema">
                <thead><tr><th>Variable</th><th>Type</th><th>Default</th><th>Description</th></tr></thead>
                <tbody>
                  @for (row of schemaRows(t); track row.key) {
                    <tr>
                      <td class="bm-ct-key">{{ row.key }}</td>
                      <td>{{ row.type }}</td>
                      <td>{{ row.default }}</td>
                      <td class="bm-dim">{{ row.desc }}</td>
                    </tr>
                  }
                </tbody>
              </table>
              <h3>Sample values</h3>
              <pre class="bm-ct-code">{{ t.sample | json }}</pre>
              <h3>Template (Jinja2)</h3>
              <pre class="bm-ct-code">{{ t.template }}</pre>
            } @else {
              <p class="bm-dim">Select a template.</p>
            }
          </div>
        </div>
      } @else {
        <p class="bm-empty">No config templates found.</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 1100px; margin: 0 auto; }
      .bm-dim { opacity: 0.7; }
      .bm-ct { display: flex; gap: 16px; align-items: flex-start; margin-top: 12px; }
      .bm-ct-list { flex: 0 0 220px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 6px 0; max-height: 70vh; overflow-y: auto; }
      .bm-ct-item { display: flex; justify-content: space-between; gap: 8px; padding: 7px 12px; cursor: pointer; font-size: 13px; border-left: 3px solid transparent; }
      .bm-ct-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
      .bm-ct-sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-ct-name { font-weight: 600; }
      .bm-ct-detail { flex: 1 1 auto; min-width: 0; }
      .bm-ct-detail h3 { margin: 16px 0 6px; }
      .bm-ct-schema { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ct-schema th, .bm-ct-schema td { text-align: left; padding: 5px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); vertical-align: top; }
      .bm-ct-key { font-family: ui-monospace, monospace; }
      .bm-ct-code { padding: 10px 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); border-radius: 6px; font-size: 12px; max-height: 340px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
      .bm-empty { opacity: 0.7; margin-top: 16px; }
    `,
  ],
})
export class ConfigTemplatesComponent {
  private agentService = inject(AgentService);

  templates = signal<ConfigTemplate[]>([]);
  selected = signal<ConfigTemplate | null>(null);

  constructor() {
    this.agentService.configTemplates().subscribe({
      next: (res) => {
        const ts = res.templates ?? [];
        this.templates.set(ts);
        if (ts.length) this.selected.set(ts[0]);
      },
      error: () => this.templates.set([]),
    });
  }

  select(t: ConfigTemplate): void {
    this.selected.set(t);
  }
  keyCount(t: ConfigTemplate): number {
    return Object.keys(t.schema || {}).length;
  }
  schemaRows(t: ConfigTemplate): { key: string; type: string; default: string; desc: string }[] {
    return Object.entries(t.schema || {}).map(([key, def]) => ({
      key,
      type: (def?.type as string) || 'string',
      default: def?.default === undefined ? '' : typeof def.default === 'object' ? JSON.stringify(def.default) : String(def.default),
      desc: def?.description ?? '',
    }));
  }
}
