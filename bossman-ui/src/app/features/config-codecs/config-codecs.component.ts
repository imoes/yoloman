import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

interface CodecEntry {
  pattern: string;
  codec: string;
  confidence: string;
  comment: string;
  separator: string;
  notes: string;
  sections: boolean;
  paths: string[];
  packages: string[];
}
interface CodecResponse {
  entries: CodecEntry[];
  summary: { total: number; by_codec: Record<string, number>; by_confidence: Record<string, number> };
  available: boolean;
}

/**
 * F-8 — the config codec registry as a read-only reference browser (Setup →
 * Config codecs). The registry (configs/config_codecs.json, also go:embedded in
 * the agent) maps config-file patterns to the codec that reads/writes their
 * grammar (keyvalue/ini/xml/toml/…). config-templates had a UI; codecs didn't —
 * this closes that gap so an operator can see how a file will be parsed before
 * setting a value on it. Master list (searchable, grouped by codec) + detail.
 */
@Component({
  selector: 'app-config-codecs',
  standalone: true,
  imports: [FormsModule],
  template: `
    <div class="bm-page">
      <h1>Config codecs</h1>
      <p class="bm-dim">
        The codec registry: how each config file's grammar is read and written back — a
        <strong>codec</strong> (keyvalue, ini, xml, toml) plus its comment/separator syntax. Class-A
        editing (set one key, keep the rest) uses these; a file with no codec is edited as raw text.
        Read-only — the registry is generated offline from man pages.
      </p>

      @if (!loaded()) {
        <p class="bm-dim">Loading…</p>
      } @else if (!available()) {
        <p class="bm-dim">The codec registry is not available on this server.</p>
      } @else {
        <div class="bm-cc-stats">
          <span class="bm-chip">{{ summary().total }} patterns</span>
          @for (c of codecChips(); track c.codec) {
            <button class="bm-chip bm-chip-btn" [class.bm-chip-on]="codecFilter() === c.codec"
                    (click)="toggleCodec(c.codec)">{{ c.codec }} · {{ c.count }}</button>
          }
        </div>

        <input class="bm-cc-search" type="text" [ngModel]="search()"
               (ngModelChange)="search.set($event.toLowerCase())"
               placeholder="Search pattern, path, package, notes…" />

        <div class="bm-cc">
          <div class="bm-cc-list">
            @for (e of filtered(); track e.pattern) {
              <div class="bm-cc-item" [class.bm-cc-sel]="selected()?.pattern === e.pattern" (click)="select(e)">
                <span class="bm-cc-pattern">{{ e.pattern }}</span>
                <span class="bm-cc-tags">
                  <span class="bm-codec bm-codec-{{ e.codec }}">{{ e.codec }}</span>
                  <span class="bm-conf bm-conf-{{ e.confidence }}" [title]="'classification confidence: ' + e.confidence">{{ e.confidence }}</span>
                </span>
              </div>
            }
            @if (!filtered().length) {
              <p class="bm-dim bm-cc-empty">No codec matches “{{ search() }}”.</p>
            }
          </div>

          <div class="bm-cc-detail">
            @if (selected(); as e) {
              <h2>{{ e.pattern }}</h2>
              <dl class="bm-cc-dl">
                <dt>Codec</dt><dd><span class="bm-codec bm-codec-{{ e.codec }}">{{ e.codec }}</span></dd>
                <dt>Confidence</dt><dd><span class="bm-conf bm-conf-{{ e.confidence }}">{{ e.confidence }}</span></dd>
                @if (e.comment) { <dt>Comment</dt><dd><code>{{ e.comment }}</code></dd> }
                @if (e.separator) { <dt>Separator</dt><dd><code>{{ e.separator }}</code></dd> }
                <dt>Sections</dt><dd>{{ e.sections ? 'yes (grouped, e.g. [section])' : 'no' }}</dd>
                @if (e.notes) { <dt>Notes</dt><dd class="bm-dim">{{ e.notes }}</dd> }
              </dl>

              @if (e.paths.length) {
                <h3>Paths <span class="bm-dim">({{ e.paths.length }})</span></h3>
                <ul class="bm-cc-paths">
                  @for (p of e.paths; track p) { <li><code>{{ p }}</code></li> }
                </ul>
              }
              @if (e.packages.length) {
                <h3>Packages <span class="bm-dim">({{ e.packages.length }})</span></h3>
                <div class="bm-cc-pkgs">
                  @for (pk of e.packages; track pk) { <span class="bm-chip">{{ pk }}</span> }
                </div>
              }
            } @else {
              <p class="bm-dim">Select a pattern to see its codec, syntax, and covered paths.</p>
            }
          </div>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 24px; max-width: 1200px; margin: 0 auto; }
    .bm-dim { opacity: 0.65; }
    .bm-cc-stats { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin: 12px 0; }
    .bm-chip { padding: 2px 10px; border-radius: 12px; font-size: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-chip-btn { border: none; cursor: pointer; color: inherit; font: inherit; }
    .bm-chip-on { background: var(--bm-sel, color-mix(in srgb, var(--mat-sys-primary) 22%, transparent)); font-weight: 600; }
    .bm-cc-search { width: 100%; max-width: 420px; padding: 7px 11px; border-radius: 8px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; margin-bottom: 14px; }
    .bm-cc { display: grid; grid-template-columns: minmax(280px, 40%) 1fr; gap: 18px; align-items: start; }
    .bm-cc-list { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; max-height: 70vh; overflow-y: auto; }
    .bm-cc-item { display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 8px 12px; cursor: pointer; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-cc-item:last-child { border-bottom: none; }
    .bm-cc-item:hover { background: var(--bm-hover, color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent)); }
    .bm-cc-sel { background: var(--bm-sel, color-mix(in srgb, var(--mat-sys-primary) 14%, transparent)); }
    .bm-cc-pattern { font-family: monospace; font-size: 13px; word-break: break-all; }
    .bm-cc-tags { display: flex; gap: 6px; flex-shrink: 0; }
    .bm-cc-empty { padding: 16px; }
    .bm-codec { font-size: 11px; padding: 1px 7px; border-radius: 10px; font-weight: 600; background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .bm-codec-none { background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); opacity: 0.7; }
    .bm-conf { font-size: 11px; padding: 1px 7px; border-radius: 10px; }
    .bm-conf-high { background: color-mix(in srgb, #2e7d32 25%, transparent); }
    .bm-conf-medium { background: color-mix(in srgb, #caa300 30%, transparent); }
    .bm-conf-low { background: color-mix(in srgb, #d32f2f 25%, transparent); }
    .bm-cc-detail { min-width: 0; }
    .bm-cc-detail h2 { font-family: monospace; font-size: 16px; word-break: break-all; }
    .bm-cc-dl { display: grid; grid-template-columns: 120px 1fr; gap: 4px 14px; margin: 12px 0; }
    .bm-cc-dl dt { opacity: 0.6; font-size: 13px; }
    .bm-cc-dl dd { margin: 0; }
    .bm-cc-paths { margin: 4px 0; padding-left: 18px; }
    .bm-cc-paths li { font-size: 13px; }
    .bm-cc-pkgs { display: flex; flex-wrap: wrap; gap: 6px; }
    code { font-family: monospace; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 1px 5px; border-radius: 4px; }
  `],
})
export class ConfigCodecsComponent implements OnInit {
  private http = inject(HttpClient);

  entries = signal<CodecEntry[]>([]);
  summary = signal<CodecResponse['summary']>({ total: 0, by_codec: {}, by_confidence: {} });
  available = signal(false);
  loaded = signal(false);
  selected = signal<CodecEntry | null>(null);
  search = signal('');
  codecFilter = signal<string | null>(null);

  codecChips = computed(() =>
    Object.entries(this.summary().by_codec)
      .map(([codec, count]) => ({ codec, count }))
      .sort((a, b) => b.count - a.count),
  );

  filtered = computed(() => {
    const term = this.search().trim();
    const codec = this.codecFilter();
    return this.entries().filter((e) => {
      if (codec && e.codec !== codec) return false;
      if (!term) return true;
      return (
        e.pattern.toLowerCase().includes(term) ||
        e.notes.toLowerCase().includes(term) ||
        e.paths.some((p) => p.toLowerCase().includes(term)) ||
        e.packages.some((p) => p.toLowerCase().includes(term))
      );
    });
  });

  ngOnInit(): void {
    this.http.get<CodecResponse>(`${environment.apiUrl}/config-codecs`).subscribe({
      next: (r) => {
        this.entries.set(r.entries);
        this.summary.set(r.summary);
        this.available.set(r.available);
        this.loaded.set(true);
      },
      error: () => this.loaded.set(true),
    });
  }

  select(e: CodecEntry): void {
    this.selected.set(e);
  }

  toggleCodec(codec: string): void {
    this.codecFilter.update((c) => (c === codec ? null : codec));
  }
}
