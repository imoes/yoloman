import { AfterViewInit, Component, ElementRef, computed, inject, input, output, signal, viewChild } from '@angular/core';
import { Router } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../core/services/agent.service';

/** One navigation target the shell offers (WORKSPACES in app.ts, role-filtered there). */
export interface PaletteNavItem {
  path: string;
  label: string;
  workspace: string;
  icon: string;
}

/** A row of the palette. `id` is stable across sessions — it is what "recently used" remembers. */
interface PaletteEntry {
  id: string;
  kind: 'nav' | 'host' | 'search';
  label: string;
  /** Where it lives: the workspace for a screen, "Host" for a host, "Fleet search" for the free-text row. */
  context: string;
  icon: string;
  commands: unknown[];
  queryParams?: Record<string, string>;
}

const RECENT_KEY = 'bm.palette.recent';
const RECENT_MAX = 8;

/**
 * Command palette (Ctrl/Cmd-K): jump to any screen or host by typing. It COMPLEMENTS the workspace nav —
 * every entry here is also reachable through the nav or the hosts list; the palette only shortens the way.
 *
 * Content: every nav item (label + workspace), every host by name (→ /hosts/:id, the hosts list's route), and
 * — once something is typed — a last row that runs the text as a fleet search (/fleet?q=), which is what
 * Ctrl-K opened before the palette existed, so that path is kept. Recently used entries come first.
 *
 * ARIA: the input is a combobox owning a listbox; the highlighted option is aria-activedescendant, so focus
 * never leaves the input while ↑/↓ move through the list.
 */
@Component({
  selector: 'bm-command-palette',
  standalone: true,
  imports: [MatIconModule],
  template: `
    <div class="bm-cp-scrim" (click)="close()"></div>
    <div class="bm-cp" role="dialog" aria-modal="true" aria-label="Command palette">
      <div class="bm-cp-box">
        <mat-icon class="bm-cp-search" aria-hidden="true">search</mat-icon>
        <input #box class="bm-cp-input" type="text" role="combobox" aria-autocomplete="list" aria-expanded="true"
               aria-controls="bm-cp-list" [attr.aria-activedescendant]="results().length ? 'bm-cp-opt-' + active() : null"
               aria-label="Go to a screen or host" placeholder="Go to a screen or host…" autocomplete="off" spellcheck="false"
               [value]="query()" (input)="onInput($any($event.target).value)" (keydown)="onKey($event)" />
        <kbd class="bm-cp-kbd">Esc</kbd>
      </div>
      <ul id="bm-cp-list" class="bm-cp-list" role="listbox" aria-label="Matches">
        @for (e of results(); track e.id; let i = $index) {
          <li [id]="'bm-cp-opt-' + i" role="option" class="bm-cp-opt" [class.bm-cp-opt--active]="i === active()"
              [attr.aria-selected]="i === active()" (mousemove)="active.set(i)" (click)="pick(e)">
            <mat-icon class="bm-cp-icon" aria-hidden="true">{{ e.icon }}</mat-icon>
            <span class="bm-cp-label">{{ e.label }}</span>
            @if (isRecent(e.id)) { <span class="bm-cp-recent">recent</span> }
            <span class="bm-cp-ctx">{{ e.context }}</span>
          </li>
        } @empty {
          <li class="bm-cp-empty" role="presentation">No screen or host matches “{{ query() }}”.</li>
        }
      </ul>
      <div class="bm-cp-foot" aria-hidden="true">
        <span><kbd>↑</kbd><kbd>↓</kbd> move</span><span><kbd>Enter</kbd> open</span><span><kbd>Esc</kbd> close</span>
        <span class="bm-cp-hosts">{{ hostsNote() }}</span>
      </div>
    </div>
  `,
  styles: [`
    .bm-cp-scrim { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.45); z-index: 1000; }
    .bm-cp { position: fixed; top: 12vh; left: 50%; transform: translateX(-50%); width: min(640px, calc(100vw - 32px));
      z-index: 1001; background: var(--mat-sys-surface-container-high); color: var(--mat-sys-on-surface);
      border: 1px solid var(--bm-hairline); border-radius: 12px; box-shadow: 0 18px 48px rgba(0, 0, 0, 0.5);
      display: flex; flex-direction: column; max-height: 70vh; overflow: hidden; }
    .bm-cp-box { display: flex; align-items: center; gap: 8px; padding: 10px 14px; border-bottom: 1px solid var(--bm-hairline); }
    .bm-cp-search { opacity: 0.6; }
    .bm-cp-input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; color: inherit; font: inherit; font-size: 15px; padding: 4px 0; }
    .bm-cp-input:focus-visible { outline: none; }
    .bm-cp-list { list-style: none; margin: 0; padding: 6px; overflow-y: auto; flex: 1; }
    .bm-cp-opt { display: flex; align-items: center; gap: 10px; padding: 7px 10px; border-radius: 8px; cursor: pointer; font-size: 13.5px; }
    .bm-cp-opt--active { background: var(--bm-sel); }
    .bm-cp-icon { width: 18px; height: 18px; font-size: 18px; opacity: 0.75; flex: none; }
    .bm-cp-label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .bm-cp-ctx { font-size: 12px; opacity: 0.6; white-space: nowrap; }
    .bm-cp-recent { font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.55;
      border: 1px solid var(--bm-hairline); border-radius: 6px; padding: 0 5px; }
    .bm-cp-empty { padding: 14px 10px; font-size: 13px; opacity: 0.7; }
    .bm-cp-foot { display: flex; gap: 14px; flex-wrap: wrap; padding: 7px 14px; border-top: 1px solid var(--bm-hairline); font-size: 11.5px; opacity: 0.7; }
    .bm-cp-hosts { margin-left: auto; }
    kbd { font: inherit; font-size: 11px; padding: 0 5px; margin-right: 3px; border-radius: 4px;
      border: 1px solid var(--bm-hairline); background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-cp-kbd { opacity: 0.6; }
  `],
})
export class CommandPaletteComponent implements AfterViewInit {
  private router = inject(Router);
  private agents = inject(AgentService);

  /** The shell's navigation items, already filtered to what this user may open. */
  items = input.required<PaletteNavItem[]>();
  closed = output<void>();

  query = signal('');
  active = signal(0);
  private hosts = signal<{ id: string; name: string }[] | null>(null);
  private hostsFailed = signal(false);
  private recent = signal<string[]>(readRecent());
  private box = viewChild<ElementRef<HTMLInputElement>>('box');
  private returnFocus = document.activeElement as HTMLElement | null;

  constructor() {
    this.agents.list().subscribe({
      next: (list) => this.hosts.set(list.map((a) => ({ id: a.id, name: a.name })).sort((a, b) => a.name.localeCompare(b.name))),
      error: () => { this.hosts.set([]); this.hostsFailed.set(true); },
    });
  }

  // Focus as soon as the view exists (not after the next render): keys typed right after Ctrl-K must land.
  ngAfterViewInit(): void { this.box()?.nativeElement.focus(); }

  /** Why hosts may be missing from the list — never let an empty host list pass for "no such host". */
  hostsNote = computed(() => {
    const h = this.hosts();
    if (h === null) return 'Loading hosts…';
    if (this.hostsFailed()) return 'Hosts could not be loaded — screens only';
    return `${h.length} host${h.length === 1 ? '' : 's'}`;
  });

  private entries = computed<PaletteEntry[]>(() => [
    ...this.items().map((i): PaletteEntry => ({
      id: `nav:${i.path}`, kind: 'nav', label: i.label, context: i.workspace, icon: i.icon, commands: [i.path],
    })),
    ...(this.hosts() ?? []).map((h): PaletteEntry => ({
      id: `host:${h.id}`, kind: 'host', label: h.name, context: 'Host', icon: 'dns', commands: ['/hosts', h.id],
    })),
  ]);

  results = computed<PaletteEntry[]>(() => {
    const q = this.query().trim().toLowerCase();
    const recent = this.recent();
    const rank = (id: string) => { const r = recent.indexOf(id); return r < 0 ? RECENT_MAX : r; };
    const all = this.entries();
    if (!q) {
      // Nothing typed: recents first, then the screens. Hosts only appear once you type (a fleet can be long).
      const recents = recent.map((id) => all.find((e) => e.id === id)).filter((e): e is PaletteEntry => !!e);
      return [...recents, ...all.filter((e) => e.kind === 'nav' && !recent.includes(e.id))];
    }
    const scored: { e: PaletteEntry; s: number }[] = [];
    for (const e of all) {
      const s = matchScore(q, e.label.toLowerCase(), e.context.toLowerCase());
      if (s > 0) scored.push({ e, s });
    }
    scored.sort((a, b) => rank(a.e.id) - rank(b.e.id) || b.s - a.s || a.e.label.localeCompare(b.e.label));
    const out = scored.slice(0, 50).map((x) => x.e);
    out.push({
      id: 'search', kind: 'search', label: `Search the fleet for “${this.query().trim()}”`, context: 'Fleet search',
      icon: 'manage_search', commands: ['/fleet'], queryParams: { q: this.query().trim() },
    });
    return out;
  });

  isRecent(id: string): boolean { return id !== 'search' && this.recent().includes(id); }

  onInput(v: string): void {
    this.query.set(v);
    this.active.set(0);
  }

  onKey(e: KeyboardEvent): void {
    const n = this.results().length;
    if (e.key === 'ArrowDown') { e.preventDefault(); if (n) this.active.set((this.active() + 1) % n); this.scrollActive(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); if (n) this.active.set((this.active() - 1 + n) % n); this.scrollActive(); }
    else if (e.key === 'Enter') { e.preventDefault(); const sel = this.results()[this.active()]; if (sel) this.pick(sel); }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); this.close(); }
  }

  pick(e: PaletteEntry): void {
    if (e.kind !== 'search') this.remember(e.id);
    this.close(false);
    this.router.navigate(e.commands, e.queryParams ? { queryParams: e.queryParams } : undefined);
  }

  close(restoreFocus = true): void {
    this.closed.emit();
    if (restoreFocus) this.returnFocus?.focus?.();
  }

  private scrollActive(): void {
    queueMicrotask(() => document.getElementById(`bm-cp-opt-${this.active()}`)?.scrollIntoView({ block: 'nearest' }));
  }

  private remember(id: string): void {
    const next = [id, ...this.recent().filter((x) => x !== id)].slice(0, RECENT_MAX);
    this.recent.set(next);
    try { localStorage.setItem(RECENT_KEY, JSON.stringify(next)); } catch { /* storage blocked: recents last this session only */ }
  }
}

function readRecent(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]');
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string').slice(0, RECENT_MAX) : [];
  } catch {
    return [];
  }
}

/** 0 = no match. Prefix > word-start > substring > in-order subsequence (fuzzy); the context (workspace)
 * matches too, weaker, so "deploy" also finds the screens of the Deploy workspace. */
function matchScore(q: string, label: string, context: string): number {
  if (label.startsWith(q)) return 100;
  if (label.includes(' ' + q) || label.includes('-' + q) || label.includes('.' + q)) return 80;
  if (label.includes(q)) return 60;
  if (context.startsWith(q)) return 40;
  let i = 0;
  for (const c of label) { if (c === q[i]) i++; if (i === q.length) return 20; }
  return 0;
}
