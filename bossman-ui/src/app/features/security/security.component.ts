import { Component, computed, inject, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { BulkUpdateResult, CveFilters, CveHost, CveSummary, FeedStatus, FleetCve, SecurityService } from '../../core/services/security.service';

/** A package to update, with the CVEs it closes and the hosts affected —
 * inverted from the CVE-keyed API so the page reads "package → its CVEs". */
interface PkgCve { cve: string; severity: string; description: string; }
interface PkgGroup { package: string; severity: string; cves: PkgCve[]; hosts: CveHost[]; }
import { FilterBarComponent, FilterDef, FilterValues } from '../../shared/components/filter-bar/filter-bar.component';

/** Block 4-D — fleet-wide Security page: which pending package upgrades close
 * which CVEs across the fleet. Summary cards + a filterable table (severity,
 * distro, "fix available", text search); each CVE row expands to the affected
 * hosts with the version window and a link to that host's Updates tab. */
@Component({
  selector: 'app-security',
  standalone: true,
  imports: [DatePipe, FormsModule, RouterLink, MatButtonModule, MatIconModule, MatCheckboxModule, MatProgressSpinnerModule, FilterBarComponent],
  template: `
    <div class="bm-sec">
      <header class="bm-head">
        <h2><mat-icon>security</mat-icon> Security — packages to update &amp; the CVEs they close</h2>
        <span class="bm-spacer"></span>
        <button mat-stroked-button (click)="refreshFeed()" [disabled]="refreshing()">
          <mat-icon>cloud_download</mat-icon> {{ refreshing() ? 'Refreshing feed…' : 'Refresh CVE feed' }}
        </button>
        <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
      </header>

      @if (feed(); as f) {
        <p class="bm-feed-status">
          @if (!f.enabled) {
            <mat-icon class="bm-fi bm-fi-off">pause_circle</mat-icon> Scheduled CVE feed is <strong>disabled</strong> — use “Refresh CVE feed”.
          } @else {
            <mat-icon class="bm-fi" [class.bm-fi-ok]="f.last_run_ok" [class.bm-fi-err]="f.last_run_ok === false">
              {{ f.last_run_ok === false ? 'error' : 'schedule' }}
            </mat-icon>
            Feed every {{ f.interval_hours }} h ·
            @if (f.last_run_started) { last refresh {{ f.last_run_started | date: 'medium' }} } @else { not run yet }
            @if (f.last_run_ok === false) { — <span class="bm-fi-err-txt">failed: {{ f.last_error }}</span> }
            · {{ feedTotal(f) }} advisories cached
          }
        </p>
      }

      @if (feedMsg()) { <p class="bm-feed-msg">{{ feedMsg() }}</p> }

      <!-- Summary cards -->
      @if (summary(); as s) {
        <div class="bm-cards">
          <div class="bm-scard"><div class="bm-num">{{ s.distinct_cves }}</div><div class="bm-lbl">CVEs</div></div>
          <div class="bm-scard"><div class="bm-num">{{ s.affected_hosts }}</div><div class="bm-lbl">Affected hosts</div></div>
          <div class="bm-scard"><div class="bm-num">{{ s.total_findings }}</div><div class="bm-lbl">Findings</div></div>
          @for (sev of severities; track sev) {
            @if (s.by_severity[sev]) {
              <div class="bm-scard bm-sev-{{ sev }}"><div class="bm-num">{{ s.by_severity[sev] }}</div><div class="bm-lbl">{{ sev }}</div></div>
            }
          }
        </div>
      }

      <!-- Filters (shared fleet filter bar) -->
      <app-filter-bar [filters]="filterDefs" [values]="fvals()" (valuesChange)="onFilters($event)" />

      @if (loading()) {
        <div class="bm-loading"><mat-spinner diameter="28" /></div>
      } @else if (err()) {
        <p class="bm-err">{{ err() }}</p>
      } @else {
        <table class="bm-ct">
          <thead><tr><th></th><th>Package to update</th><th>Severity</th><th>CVEs</th><th>Hosts</th></tr></thead>
          <tbody>
            @for (p of packages(); track p.package) {
              <tr class="bm-row" (click)="toggle(p.package)">
                <td class="bm-exp"><mat-icon>{{ expanded() === p.package ? 'expand_more' : 'chevron_right' }}</mat-icon></td>
                <td class="bm-mono bm-pkg">{{ p.package }}</td>
                <td><span class="bm-sev bm-sev-{{ p.severity || 'unknown' }}">{{ p.severity || 'unknown' }}</span></td>
                <td>{{ p.cves.length }}</td>
                <td>{{ p.hosts.length }}</td>
              </tr>
              @if (expanded() === p.package) {
                <tr class="bm-detail"><td></td><td colspan="4">
                  <!-- The CVEs this update closes, each explained in plain language -->
                  <div class="bm-cvelist">
                    @for (c of p.cves; track c.cve) {
                      <div class="bm-cveitem">
                        <div class="bm-cveline">
                          <span class="bm-sev bm-sev-{{ c.severity || 'unknown' }}">{{ c.severity || 'unknown' }}</span>
                          <a class="bm-mono bm-cvelink" [href]="cveUrl(c.cve)" target="_blank" rel="noopener">{{ c.cve }} <mat-icon>open_in_new</mat-icon></a>
                        </div>
                        <p class="bm-cvedesc">{{ c.description || 'No description in the current feed — open the link for details.' }}</p>
                      </div>
                    }
                  </div>
                  <div class="bm-bulkbar">
                    @if (selectedHosts().size) {
                      <span class="bm-bulkcount">{{ selectedHosts().size }} host(s) selected</span>
                      <button mat-stroked-button [disabled]="bulkBusy()" (click)="bulkUpdate(true)">
                        <mat-icon>science</mat-icon> Preview security updates (dry run)
                      </button>
                      <button mat-raised-button color="primary" [disabled]="bulkBusy()" (click)="bulkUpdate(false)">
                        <mat-icon>system_update_alt</mat-icon> Apply security updates
                      </button>
                      <button mat-button (click)="clearHosts()">Clear</button>
                    } @else {
                      <span class="bm-hint">Select hosts to bulk-apply security updates.</span>
                    }
                    @if (bulkBusy()) { <mat-spinner diameter="16" /> }
                  </div>
                  @if (bulkMsg()) { <p class="bm-bulkmsg" [class.bm-bulkerr]="bulkHadError()">{{ bulkMsg() }}</p> }
                  <table class="bm-hosts">
                    <thead><tr>
                      <th class="bm-cb"><mat-checkbox [checked]="allHostsSelected(p)" [indeterminate]="someHostsSelected(p)" (change)="toggleAllHosts(p, $event.checked)" /></th>
                      <th>Host</th><th>Installed</th><th>Fixed in</th><th></th>
                    </tr></thead>
                    <tbody>
                      @for (h of p.hosts; track h.agent_id) {
                        <tr [class.bm-hsel]="hostSelected(h.agent_id)">
                          <td class="bm-cb"><mat-checkbox [checked]="hostSelected(h.agent_id)" (change)="toggleHost(h.agent_id)" /></td>
                          <td class="bm-mono">{{ h.host }}</td>
                          <td class="bm-mono">{{ h.current_version || '—' }}</td>
                          <td class="bm-mono">{{ h.fixed_version || '—' }}</td>
                          <td><a mat-button [routerLink]="['/hosts', h.agent_id]" [queryParams]="{ tab: 'management' }"><mat-icon>open_in_new</mat-icon> Updates</a></td>
                        </tr>
                      }
                    </tbody>
                  </table>
                </td></tr>
              }
            }
            @if (!packages().length) { <tr><td colspan="5" class="bm-empty">No updatable packages with CVEs. Refresh the feed and open a host's Updates/CVE view to collect.</td></tr> }
          </tbody>
        </table>
      }
    </div>
  `,
  styles: [
    `
      .bm-sec { padding: 16px; display: flex; flex-direction: column; gap: 14px; }
      .bm-head { display: flex; align-items: center; gap: 10px; }
      .bm-head h2 { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 18px; }
      .bm-spacer { flex: 1; }
      .bm-feed-msg { font-size: 12.5px; opacity: 0.8; margin: 0; }
      .bm-cards { display: flex; gap: 12px; flex-wrap: wrap; }
      .bm-scard { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 12px 18px; min-width: 96px; text-align: center; background: var(--mat-sys-surface); }
      .bm-num { font-size: 24px; font-weight: 700; }
      .bm-lbl { font-size: 11.5px; opacity: 0.65; text-transform: capitalize; }
      .bm-filters { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
      .bm-filters select, .bm-filters input { padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
      .bm-filters input { flex: 1; min-width: 180px; }
      .bm-chk { font-size: 12.5px; display: flex; align-items: center; gap: 5px; opacity: 0.85; }
      .bm-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-ct { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ct th { text-align: left; font-weight: 500; opacity: 0.6; padding: 6px 12px; font-size: 12px; }
      .bm-ct td { padding: 8px 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-row { cursor: pointer; }
      .bm-row:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-exp mat-icon { font-size: 18px; opacity: 0.6; vertical-align: middle; }
      .bm-mono { font-family: monospace; }
      .bm-detail td { background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
      .bm-hosts { width: 100%; border-collapse: collapse; font-size: 12.5px; }
      .bm-hosts th { text-align: left; opacity: 0.55; padding: 4px 8px; font-weight: 500; }
      .bm-hosts td { padding: 4px 8px; border-top: 1px dashed var(--mat-sys-outline-variant); }
      .bm-sev { font-size: 11px; padding: 1px 8px; border-radius: 999px; text-transform: capitalize; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-sev-critical, .bm-scard.bm-sev-critical .bm-num { color: #b71c1c; }
      .bm-sev-important, .bm-scard.bm-sev-important .bm-num { color: #e65100; }
      .bm-sev-moderate { color: #f9a825; }
      .bm-empty { opacity: 0.6; padding: 16px 12px; }
      .bm-err { color: #c62828; }
      .bm-cb { width: 34px; }
      .bm-hsel { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
      .bm-bulkbar { display: flex; align-items: center; gap: 10px; padding: 6px 0 10px; flex-wrap: wrap; }
      .bm-bulkcount { font-weight: 600; font-size: 12.5px; }
      .bm-hint { font-size: 12px; opacity: 0.6; }
      .bm-bulkmsg { font-size: 12.5px; margin: 0 0 8px; padding: 6px 10px; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); white-space: pre-line; }
      .bm-bulkerr { background: color-mix(in srgb, #c62828 14%, transparent); }
      .bm-feed-status { display: flex; align-items: center; gap: 6px; font-size: 12.5px; opacity: 0.85; margin: 0 0 4px; flex-wrap: wrap; }
      .bm-fi { font-size: 17px; height: 17px; width: 17px; opacity: 0.7; }
      .bm-fi-ok { color: #2e7d32; opacity: 1; }
      .bm-fi-err { color: #c62828; opacity: 1; }
      .bm-fi-off { color: #f9a825; opacity: 1; }
      .bm-fi-err-txt { color: #c62828; }
      .bm-pkg { font-weight: 600; }
      .bm-cvelist { display: flex; flex-direction: column; gap: 10px; padding: 6px 0 12px; }
      .bm-cveitem { border-left: 3px solid var(--mat-sys-outline-variant); padding: 2px 0 2px 12px; }
      .bm-cveline { display: flex; align-items: center; gap: 8px; }
      .bm-cvelink { display: inline-flex; align-items: center; gap: 3px; color: var(--mat-sys-primary); text-decoration: none; }
      .bm-cvelink:hover { text-decoration: underline; }
      .bm-cvelink mat-icon { font-size: 13px; width: 13px; height: 13px; }
      .bm-cvedesc { margin: 3px 0 0; font-size: 12.5px; opacity: 0.8; line-height: 1.45; }
    `,
  ],
})
export class SecurityComponent {
  private security = inject(SecurityService);

  severities = ['critical', 'important', 'moderate', 'low'];

  summary = signal<CveSummary | null>(null);
  cves = signal<FleetCve[]>([]);
  // Invert the CVE-keyed list into "package → its CVEs + affected hosts", worst
  // severity first, so the page leads with what you actually act on: the update.
  packages = computed<PkgGroup[]>(() => {
    const byPkg = new Map<string, PkgGroup>();
    for (const c of this.cves()) {
      for (const h of c.hosts) {
        let g = byPkg.get(h.package);
        if (!g) { g = { package: h.package, severity: '', cves: [], hosts: [] }; byPkg.set(h.package, g); }
        if (!g.cves.some((x) => x.cve === c.cve)) g.cves.push({ cve: c.cve, severity: c.severity, description: c.description || '' });
        if (!g.hosts.some((x) => x.agent_id === h.agent_id)) g.hosts.push(h);
        if (this.sevRank(c.severity) > this.sevRank(g.severity)) g.severity = c.severity;
      }
    }
    return [...byPkg.values()].sort((a, b) =>
      this.sevRank(b.severity) - this.sevRank(a.severity) || a.package.localeCompare(b.package),
    );
  });
  loading = signal(false);
  err = signal<string | null>(null);
  expanded = signal<string | null>(null);
  refreshing = signal(false);
  feedMsg = signal<string | null>(null);
  feed = signal<FeedStatus | null>(null);

  filterDefs: FilterDef[] = [
    { ident: 'severity', label: 'Severity', kind: 'select', options: this.severities.map((s) => ({ value: s, label: s })) },
    { ident: 'distro', label: 'Distro', kind: 'select', options: [
      { value: 'debian', label: 'debian' }, { value: 'ubuntu', label: 'ubuntu' }, { value: 'redhat', label: 'redhat' },
    ] },
    { ident: 'fix_available', label: 'fix available', kind: 'checkbox' },
    { ident: 'q', label: 'search CVE / package', kind: 'text', placeholder: 'search CVE / package' },
  ];
  fvals = signal<FilterValues>({});

  // Bulk security-update over the expanded CVE's affected hosts.
  selectedHosts = signal<Set<string>>(new Set());
  bulkBusy = signal(false);
  bulkMsg = signal<string | null>(null);
  bulkHadError = signal(false);

  constructor() {
    this.reload();
    this.security.summary().subscribe({ next: (s) => this.summary.set(s), error: () => {} });
    this.loadFeed();
  }

  private loadFeed(): void {
    this.security.feedStatus().subscribe({ next: (f) => this.feed.set(f), error: () => {} });
  }

  /** Total advisories cached across all distros — proof the scheduled feed ran. */
  feedTotal(f: FeedStatus): number {
    return Object.values(f.counts || {}).reduce((a, b) => a + b, 0);
  }

  private filters(): CveFilters {
    const v = this.fvals();
    return {
      severity: (v['severity'] as string) || undefined,
      distro: (v['distro'] as string) || undefined,
      fix_available: v['fix_available'] === true || undefined,
      q: (v['q'] as string) || undefined,
    };
  }

  reload(): void {
    this.loading.set(true);
    this.err.set(null);
    this.security.cves(this.filters()).subscribe({
      next: (r) => { this.cves.set(r.cves); this.loading.set(false); },
      error: (e) => { this.loading.set(false); this.err.set(e?.error?.detail ?? 'failed to load CVEs'); },
    });
  }

  onFilters(values: FilterValues): void {
    this.fvals.set(values);
    this.reload();
  }

  toggle(cve: string): void {
    this.expanded.set(this.expanded() === cve ? null : cve);
    // Selection + result are scoped to one expanded CVE.
    this.clearHosts();
    this.bulkMsg.set(null);
  }

  // ---- per-CVE host multi-select ----
  hostSelected(agentId: string): boolean {
    return this.selectedHosts().has(agentId);
  }
  toggleHost(agentId: string): void {
    const next = new Set(this.selectedHosts());
    next.has(agentId) ? next.delete(agentId) : next.add(agentId);
    this.selectedHosts.set(next);
  }
  private hostIds(p: PkgGroup): string[] {
    return [...new Set(p.hosts.map((h) => h.agent_id))];
  }
  allHostsSelected(p: PkgGroup): boolean {
    const ids = this.hostIds(p);
    return ids.length > 0 && ids.every((id) => this.selectedHosts().has(id));
  }
  someHostsSelected(p: PkgGroup): boolean {
    return this.selectedHosts().size > 0 && !this.allHostsSelected(p);
  }
  toggleAllHosts(p: PkgGroup, checked: boolean): void {
    this.selectedHosts.set(checked ? new Set(this.hostIds(p)) : new Set());
  }
  private sevRank(s: string): number {
    return { critical: 4, important: 3, high: 3, moderate: 2, medium: 2, low: 1 }[(s || '').toLowerCase()] ?? 0;
  }
  /** Link to the authoritative CVE record (Debian tracker) for the full write-up. */
  cveUrl(cve: string): string {
    return `https://security-tracker.debian.org/tracker/${cve}`;
  }
  clearHosts(): void {
    this.selectedHosts.set(new Set());
  }

  bulkUpdate(dryRun: boolean): void {
    const ids = [...this.selectedHosts()];
    if (!ids.length) return;
    this.bulkBusy.set(true);
    this.bulkMsg.set(null);
    this.security.bulkUpdate(ids, true, dryRun).subscribe({
      next: (r: BulkUpdateResult) => {
        this.bulkBusy.set(false);
        const bad = r.results.filter((x) => x.status !== 'ok');
        this.bulkHadError.set(bad.length > 0);
        const verb = dryRun ? 'Preview' : 'Applied';
        const lines = [`${verb}: ${r.applied}/${r.results.length} host(s) ok${dryRun ? ' (dry run — nothing changed)' : ''}.`];
        for (const b of bad) lines.push(`• ${b.host ?? b.agent_id}: ${b.status}${b.error ? ' — ' + b.error : ''}`);
        this.bulkMsg.set(lines.join('\n'));
      },
      error: (e) => {
        this.bulkBusy.set(false);
        this.bulkHadError.set(true);
        this.bulkMsg.set(e?.error?.detail ?? 'bulk update failed');
      },
    });
  }

  refreshFeed(): void {
    this.refreshing.set(true);
    this.feedMsg.set(null);
    this.security.refresh().subscribe({
      next: (r) => {
        this.refreshing.set(false);
        this.feedMsg.set(`feed refreshed: ${Object.entries(r.counts).map(([d, n]) => `${d} ${n}`).join(', ')}`);
        this.security.summary().subscribe({ next: (s) => this.summary.set(s) });
        this.loadFeed();
        this.reload();
      },
      error: (e) => { this.refreshing.set(false); this.feedMsg.set(e?.error?.detail ?? 'refresh failed (admin only)'); },
    });
  }
}
