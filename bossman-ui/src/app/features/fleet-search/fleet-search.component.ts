import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

interface Leaf { path: string; value: string; }
interface HostHit { host: string; generation: number; match_count: number; matches: Leaf[]; }
interface FleetSearchResult { query: string; host_count: number; hosts: HostHit[]; }

/**
 * Fleet-wide search over every host's compiled desired_state (config keys/values,
 * variables, tags, facts, applied checks/roles/thresholds) in one call — the
 * same GET /fleet/search the MCP `fleet_search` tool uses. Answers "which hosts
 * have X?" across the whole fleet, with the matching leaves per host.
 */
@Component({
  selector: 'app-fleet-search',
  standalone: true,
  imports: [FormsModule, MatIconModule],
  template: `
    <div class="bm-fs">
      <h1>Fleet search</h1>
      <p class="bm-fs-hint">Search every host's desired state at once — config, variables, tags, facts,
        roles, checks, thresholds. Plain substring, or <code>key=value</code> (path contains key AND
        value contains value): e.g. <code>nginx</code>, <code>os.family=Debian</code>,
        <code>timezone=Europe</code>, <code>role=web</code>, <code>config./etc/ntp.conf</code>.</p>
      <div class="bm-fs-bar">
        <input class="bm-fs-in" type="search" placeholder="Search the fleet…" [ngModel]="q()"
               (ngModelChange)="q.set($event)" (keyup.enter)="run()" />
        <button class="bm-fs-go" (click)="run()" [disabled]="loading()">
          <mat-icon>search</mat-icon> {{ loading() ? 'Searching…' : 'Search' }}
        </button>
      </div>

      @if (result(); as r) {
        <p class="bm-fs-count">{{ r.host_count }} host{{ r.host_count === 1 ? '' : 's' }} match “{{ r.query }}”</p>
        @for (h of r.hosts; track h.host) {
          <div class="bm-fs-host">
            <div class="bm-fs-hh" (click)="toggle(h.host)">
              <mat-icon class="bm-fs-caret">{{ openHosts().has(h.host) ? 'expand_more' : 'chevron_right' }}</mat-icon>
              <mat-icon class="bm-fs-dns">dns</mat-icon>
              <a class="bm-fs-name" [href]="'/hosts'">{{ h.host }}</a>
              <span class="bm-fs-badge">{{ h.match_count }} match{{ h.match_count === 1 ? '' : 'es' }}</span>
              <span class="bm-fs-gen">gen {{ h.generation }}</span>
            </div>
            @if (openHosts().has(h.host)) {
              <table class="bm-fs-tbl">
                <tbody>
                  @for (m of h.matches; track m.path) {
                    <tr><td class="bm-fs-path">{{ m.path }}</td><td class="bm-fs-val">{{ m.value }}</td></tr>
                  }
                </tbody>
              </table>
              @if (h.match_count > h.matches.length) {
                <p class="bm-fs-more">+{{ h.match_count - h.matches.length }} more (refine the query)</p>
              }
            }
          </div>
        } @empty {
          <p class="bm-fs-empty">No hosts match.</p>
        }
      }
    </div>
  `,
  styles: [`
    .bm-fs { padding: 20px 24px; max-width: 1000px; }
    .bm-fs-hint { opacity: 0.72; font-size: 13px; max-width: 760px; line-height: 1.5; }
    .bm-fs-hint code { font-family: ui-monospace, monospace; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 1px 5px; border-radius: 4px; }
    .bm-fs-bar { display: flex; gap: 8px; margin: 12px 0 18px; }
    .bm-fs-in { flex: 1; max-width: 560px; padding: 9px 12px; border-radius: 8px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font-size: 14px; }
    .bm-fs-go { display: inline-flex; align-items: center; gap: 6px; padding: 0 16px; border: none; border-radius: 8px; background: var(--mat-sys-primary); color: var(--mat-sys-on-primary); cursor: pointer; font-size: 14px; }
    .bm-fs-go:disabled { opacity: 0.6; cursor: default; }
    .bm-fs-count { font-size: 13px; opacity: 0.75; margin: 0 0 10px; }
    .bm-fs-host { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; margin-bottom: 8px; overflow: hidden; }
    .bm-fs-hh { display: flex; align-items: center; gap: 8px; padding: 8px 12px; cursor: pointer; }
    .bm-fs-hh:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-fs-caret { opacity: 0.7; }
    .bm-fs-dns { opacity: 0.7; font-size: 18px; }
    .bm-fs-name { font-weight: 600; text-decoration: none; color: inherit; }
    .bm-fs-badge { margin-left: auto; font-size: 12px; padding: 1px 8px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .bm-fs-gen { font-size: 12px; opacity: 0.55; }
    .bm-fs-tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
    .bm-fs-tbl td { padding: 4px 12px; border-top: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 60%, transparent); font-family: ui-monospace, monospace; }
    .bm-fs-path { opacity: 0.7; white-space: nowrap; }
    .bm-fs-val { overflow-wrap: anywhere; }
    .bm-fs-more { font-size: 12px; opacity: 0.6; padding: 4px 12px 8px; }
    .bm-fs-empty { opacity: 0.6; font-style: italic; }
  `],
})
export class FleetSearchComponent {
  private http = inject(HttpClient);
  q = signal('');
  loading = signal(false);
  result = signal<FleetSearchResult | null>(null);
  openHosts = signal<Set<string>>(new Set());

  run(): void {
    const query = this.q().trim();
    if (!query) return;
    this.loading.set(true);
    this.http.get<FleetSearchResult>(`${environment.apiUrl}/fleet/search?q=${encodeURIComponent(query)}`).subscribe({
      next: (r) => {
        this.result.set(r);
        // Auto-expand when few hosts match, so results are readable at a glance.
        this.openHosts.set(new Set(r.hosts.length <= 5 ? r.hosts.map((h) => h.host) : []));
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }

  toggle(host: string): void {
    const s = new Set(this.openHosts());
    s.has(host) ? s.delete(host) : s.add(host);
    this.openHosts.set(s);
  }
}
