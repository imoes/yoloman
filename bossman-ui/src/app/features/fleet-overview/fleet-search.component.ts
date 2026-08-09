import { Component, ElementRef, afterNextRender, inject, input, signal, viewChild } from '@angular/core';
import { Router } from '@angular/router';
import { Subject, debounceTime, distinctUntilChanged, switchMap } from 'rxjs';
import { MatIconModule } from '@angular/material/icon';
import { SearchService } from '../../core/services/search.service';
import { SearchResultItem, UnifiedSearchResponse } from '../../core/models/search.model';

/**
 * The Checkmk-quicksearch-style omnibox for the Fleet Overview. Type a query
 * (host / host-group / service-check name, with the crit:/site:/st:/tag: fields
 * and AND/OR/! operators) and get a debounced, grouped live-preview dropdown.
 * Picking a row deep-links (host → host detail, service → that host's services);
 * pressing Enter runs the full result view on /fleet?q=… (see FleetOverview).
 */
@Component({
  selector: 'app-fleet-search',
  standalone: true,
  imports: [MatIconModule],
  template: `
    <div class="bm-omni" (keydown.escape)="close()">
      <mat-icon class="bm-omni-icon">search</mat-icon>
      <input
        #box
        class="bm-omni-input"
        type="text"
        placeholder="Search hosts, groups, service-checks…  e.g.  crit:prod st:CRIT   ·   s:disk OR s:cpu   ·   hg:linux !site:FRA-1"
        [value]="query()"
        (input)="onInput($any($event.target).value)"
        (focus)="open.set(true)"
        (keydown.enter)="submit()"
        aria-label="Fleet search"
      />
      @if (query()) {
        <button class="bm-omni-clear" (click)="clear()" aria-label="Clear search"><mat-icon>close</mat-icon></button>
      }

      @if (open() && query().length >= 2 && results(); as r) {
        <div class="bm-omni-drop">
          @if (!r.counts['host'] && !r.counts['host_group'] && !r.counts['service']) {
            <div class="bm-omni-none">No matches. Press Enter to run the full search.</div>
          }
          @if (r.hosts.length) {
            <div class="bm-omni-group">Hosts</div>
            @for (it of r.hosts; track it.title) {
              <button class="bm-omni-row" (click)="pick(it)">
                <span class="bm-omni-dot" [attr.data-state]="it.state"></span>
                <span class="bm-omni-title">{{ it.title }}</span>
                @if (it.subtitle) { <span class="bm-omni-sub">{{ it.subtitle }}</span> }
              </button>
            }
          }
          @if (r.host_groups.length) {
            <div class="bm-omni-group">Host groups</div>
            @for (it of r.host_groups; track it.title) {
              <button class="bm-omni-row" (click)="pick(it)">
                <mat-icon class="bm-omni-gicon">workspaces</mat-icon>
                <span class="bm-omni-title">{{ it.title }}</span>
              </button>
            }
          }
          @if (r.services.length) {
            <div class="bm-omni-group">Service checks</div>
            @for (it of r.services; track it.title + it.subtitle) {
              <button class="bm-omni-row" (click)="pick(it)">
                <span class="bm-omni-dot" [attr.data-state]="it.state"></span>
                <span class="bm-omni-title">{{ it.title }}</span>
                @if (it.subtitle) { <span class="bm-omni-sub">on {{ it.subtitle }}</span> }
              </button>
            }
          }
          <button class="bm-omni-run" (click)="submit()">
            <mat-icon>keyboard_return</mat-icon> Run full search for “{{ query() }}”
          </button>
        </div>
      }
    </div>
    @if (open()) { <div class="bm-omni-scrim" (click)="close()"></div> }
  `,
  styles: [
    `
      :host { display: block; position: relative; z-index: 20; }
      .bm-omni { position: relative; display: flex; align-items: center; gap: 8px;
        border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 8px 12px;
        background: var(--mat-sys-surface); }
      .bm-omni-icon { opacity: 0.6; }
      .bm-omni-input { flex: 1; border: 0; outline: 0; background: transparent; font-size: 15px;
        color: var(--mat-sys-on-surface); }
      .bm-omni-clear { border: 0; background: transparent; cursor: pointer; opacity: 0.6; display: flex; }
      .bm-omni-clear mat-icon { font-size: 18px; width: 18px; height: 18px; }
      .bm-omni-drop { position: absolute; top: calc(100% + 6px); left: 0; right: 0;
        background: var(--mat-sys-surface); border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 10px; box-shadow: 0 8px 30px rgba(0,0,0,0.25); max-height: 60vh; overflow-y: auto;
        padding: 6px; z-index: 21; }
      .bm-omni-group { font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.55;
        padding: 8px 10px 4px; }
      .bm-omni-row { display: flex; align-items: center; gap: 10px; width: 100%; text-align: left;
        border: 0; background: transparent; cursor: pointer; padding: 7px 10px; border-radius: 6px;
        color: var(--mat-sys-on-surface); font-size: 14px; }
      .bm-omni-row:hover { background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .bm-omni-title { font-weight: 500; }
      .bm-omni-sub { opacity: 0.6; font-size: 12px; }
      .bm-omni-gicon { font-size: 18px; width: 18px; height: 18px; opacity: 0.6; }
      .bm-omni-dot { width: 9px; height: 9px; border-radius: 50%; background: var(--bm-unknown); flex: none; }
      .bm-omni-dot[data-state='OK'] { background: var(--bm-green); }
      .bm-omni-dot[data-state='WARN'] { background: var(--bm-gold); }
      .bm-omni-dot[data-state='CRIT'] { background: var(--bm-red); }
      .bm-omni-none { padding: 12px 10px; opacity: 0.6; font-size: 13px; }
      .bm-omni-run { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
        border: 0; border-top: 1px solid var(--mat-sys-outline-variant); margin-top: 6px; padding: 10px;
        background: transparent; cursor: pointer; color: var(--mat-sys-primary); font-size: 13px; }
      .bm-omni-run mat-icon { font-size: 18px; width: 18px; height: 18px; }
      .bm-omni-scrim { position: fixed; inset: 0; z-index: 10; }
    `,
  ],
})
export class FleetSearchComponent {
  private search = inject(SearchService);
  private router = inject(Router);
  private host = inject(ElementRef);

  /** Seeds the box from the route (?q=) so it survives reload / deep-links. */
  seed = input<string>('');
  /** Focus the input on first render (used by the global Ctrl+K overlay). */
  autofocus = input(false);

  query = signal('');
  results = signal<UnifiedSearchResponse | null>(null);
  open = signal(false);

  private box = viewChild<ElementRef<HTMLInputElement>>('box');
  private input$ = new Subject<string>();

  constructor() {
    afterNextRender(() => {
      if (this.autofocus()) this.box()?.nativeElement.focus();
    });
    this.input$
      .pipe(
        debounceTime(250),
        distinctUntilChanged(),
        switchMap((q) => this.search.unified(q.trim())),
      )
      .subscribe((r) => this.results.set(r));

    // Seed once the parent supplies the route value.
    queueMicrotask(() => {
      const s = this.seed();
      if (s) this.query.set(s);
    });
  }

  onInput(value: string): void {
    this.query.set(value);
    this.open.set(true);
    if (value.trim().length >= 2) {
      this.input$.next(value);
    } else {
      this.results.set(null);
    }
  }

  pick(item: SearchResultItem): void {
    this.close();
    if (item.type === 'host' && item.id) {
      this.router.navigate(['/hosts', item.id]);
    } else if (item.type === 'service' && item.id) {
      this.router.navigate(['/hosts', item.id], { queryParams: { tab: 'services' } });
    } else {
      // host_group (or anything without a deep-link) → full result view.
      this.router.navigate(['/fleet'], { queryParams: { q: item.query_params.q } });
    }
  }

  submit(): void {
    const q = this.query().trim();
    this.close();
    this.router.navigate(['/fleet'], { queryParams: { q: q || null } });
  }

  clear(): void {
    this.query.set('');
    this.results.set(null);
    this.router.navigate(['/fleet'], { queryParams: { q: null } });
  }

  close(): void {
    this.open.set(false);
  }
}
