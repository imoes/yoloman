import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { DatePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatSnackBar } from '@angular/material/snack-bar';
import {
  MmcService, ConsoleTree, NodeResult, Snapin, SnapinAction, SnapinColumn,
} from '../../core/services/mmc.service';

/**
 * THE MANAGEMENT CONSOLE — MMC's three panes, for any host in the fleet.
 *
 * Console tree on the left, result list in the middle, actions for the selected row on the right. That layout
 * is not nostalgia: it is the shape that lets one screen serve twenty different kinds of object without
 * teaching the reader a new screen each time, which is exactly what RSAT does for Windows and what a fleet
 * with two operating systems needs more of, not less.
 *
 * EVERYTHING HERE IS DRIVEN BY THE SERVER'S CATALOG — columns, actions, availability and its reasons. This
 * component knows how to render a table and how to run an action, and nothing about services, accounts or
 * disks. Adding a snap-in is a block in `configs/mmc_snapins.json`; it needs no change here.
 */
@Component({
  selector: 'app-mmc-console',
  standalone: true,
  imports: [DatePipe, FormsModule, MatButtonModule, MatIconModule],
  template: `
    <div class="bm-mmc">
      <!-- ── Scope pane ─────────────────────────────────────────────── -->
      <aside class="bm-scope">
        <div class="bm-scope-head">
          <mat-icon>account_tree</mat-icon>
          <div>
            <div class="bm-scope-title">Console root</div>
            <div class="bm-dim bm-small">{{ tree()?.host || '…' }}@if (tree()?.os_family) { · {{ tree()?.os_family }} }</div>
          </div>
        </div>

        @if (tree()?.tools_error) {
          <!-- WHY STATES READ "unknown", once at the top instead of on every snap-in. -->
          <div class="bm-note">
            The host could not be asked which modules it has, so availability below is <em>unknown</em> rather
            than decided: {{ tree()?.tools_error }}
          </div>
        }

        @for (s of tree()?.snapins || []; track s.id) {
          <div class="bm-snapin" [class.bm-off]="s.state !== 'available'">
            <div class="bm-snapin-head" (click)="toggle(s.id)">
              <mat-icon class="bm-chev">{{ open().has(s.id) ? 'expand_more' : 'chevron_right' }}</mat-icon>
              <mat-icon class="bm-sicon">{{ s.icon || 'folder' }}</mat-icon>
              <span class="bm-sname">{{ s.title }}</span>
              @if (s.state !== 'available') { <span class="bm-state bm-state--{{ s.state }}">{{ s.state }}</span> }
            </div>
            @if (open().has(s.id)) {
              @if (s.mmc_equivalent) { <div class="bm-dim bm-small bm-mmceq">≙ {{ s.mmc_equivalent }}</div> }
              @if (s.state !== 'available') {
                <!-- NOT HIDDEN, and the reason is the point: an operator has to be able to tell "this system
                     cannot do it" from "this host cannot" from "we could not ask". -->
                <div class="bm-note bm-note--why">{{ s.reason }}</div>
              }
              @for (n of s.nodes; track n.id) {
                <button class="bm-node" [class.bm-sel]="isSelected(s.id, n.id)"
                        [disabled]="n.state !== 'available'"
                        [title]="n.state === 'available' ? n.title : n.reason"
                        (click)="select(s, n.id)">
                  <mat-icon>{{ isSelected(s.id, n.id) ? 'folder_open' : 'description' }}</mat-icon>
                  {{ n.title }}
                </button>
              }
            }
          </div>
        } @empty {
          <div class="bm-note">Loading the console tree…</div>
        }
      </aside>

      <!-- ── Result pane ────────────────────────────────────────────── -->
      <section class="bm-result">
        @if (!node()) {
          <div class="bm-empty">
            <mat-icon>account_tree</mat-icon>
            <p>Pick a node in the console tree.</p>
            <p class="bm-dim bm-small">
              The snap-ins come from the server's catalog and are filtered by what this host actually has —
              a snap-in the host cannot serve stays visible with the reason, so the tree is the same on every
              host and the differences are stated rather than hidden.
            </p>
          </div>
        } @else {
          <header class="bm-result-head">
            <div>
              <h2>{{ node()!.title }}</h2>
              <div class="bm-dim bm-small">
                {{ node()!.count }} row(s) · {{ node()!.host }}
                @if (node()!.error) { · <span class="bm-err">could not be read</span> }
              </div>
            </div>
            <div class="bm-head-actions">
              <input class="bm-filter" placeholder="filter rows"
                     [ngModel]="filter()" (ngModelChange)="filter.set($event)" />
              <button mat-stroked-button (click)="reloadNode()"><mat-icon>refresh</mat-icon> Refresh</button>
            </div>
          </header>

          @if (node()!.error) {
            <div class="bm-note bm-note--err">
              This node's columns are known; its rows are not, because the host could not be read:
              {{ node()!.error }}
            </div>
          }

          <div class="bm-table-wrap">
            <table class="bm-table">
              <thead>
                <tr>
                  @for (c of node()!.columns; track c.key) {
                    <th [style.width.px]="c.width" [class.bm-num]="c.numeric">{{ c.title }}</th>
                  }
                  @if (node()!.actions.length) { <th class="bm-act-col"></th> }
                </tr>
              </thead>
              <tbody>
                @for (r of visibleRows(); track $index) {
                  <tr [class.bm-sel]="selectedRow() === r" (click)="selectedRow.set(r)">
                    @for (c of node()!.columns; track c.key) {
                      <td [class.bm-num]="c.numeric"
                          [style.paddingLeft.px]="c.indent_key ? 10 + 18 * depth(r, c) : null">
                        @if (c.badge) {
                          <span class="bm-badge bm-badge--{{ badgeClass(cell(r, c)) }}">{{ cell(r, c) }}</span>
                        } @else {
                          {{ display(r, c) }}
                        }
                      </td>
                    }
                    @if (node()!.actions.length) {
                      <td class="bm-act-col">
                        @for (a of actionsFor(r); track a.id) {
                          <button mat-icon-button [title]="a.title" [disabled]="running() === a.id"
                                  (click)="run(a, r, $event)">
                            <mat-icon>{{ a.icon || 'play_arrow' }}</mat-icon>
                          </button>
                        }
                      </td>
                    }
                  </tr>
                } @empty {
                  <tr>
                    <td [attr.colspan]="node()!.columns.length + 1" class="bm-dim">
                      @if (node()!.error) { No rows could be read — see the reason above. }
                      @else if (filter()) { No row matches “{{ filter() }}”. }
                      @else { This node is empty on this host. }
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          </div>

          <!-- ── Action pane: what the selected row can be told to do ── -->
          @if (selectedRow()) {
            <footer class="bm-actions">
              <div class="bm-dim bm-small">Selected: <strong>{{ label(selectedRow()!) }}</strong></div>
              @for (a of actionsFor(selectedRow()!); track a.id) {
                <button mat-stroked-button [disabled]="running() === a.id" (click)="run(a, selectedRow()!, null)">
                  <mat-icon>{{ a.icon || 'play_arrow' }}</mat-icon> {{ a.title }}
                </button>
              } @empty {
                <span class="bm-dim bm-small">No action applies to this row.</span>
              }
              @if (lastResult()) { <span class="bm-last">{{ lastResult() }}</span> }
            </footer>
          }
        }
      </section>
    </div>
  `,
  styles: [`
    .bm-mmc { display: grid; grid-template-columns: 290px 1fr; gap: 0; height: calc(100vh - 120px); min-height: 520px; }
    .bm-scope { border-right: 1px solid var(--mat-sys-outline-variant); overflow-y: auto; padding: 10px 8px 24px; }
    .bm-scope-head { display: flex; gap: 10px; align-items: center; padding: 6px 8px 12px; }
    .bm-scope-title { font-weight: 600; }
    .bm-small { font-size: 12px; }
    .bm-dim { opacity: 0.62; }
    .bm-note { margin: 8px; padding: 8px 10px; border-radius: 6px; font-size: 12px; line-height: 1.45;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-note--why { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 12%, transparent); }
    .bm-note--err { background: color-mix(in srgb, var(--bm-red, #c62828) 12%, transparent); margin: 0 0 12px; }
    .bm-snapin { margin-bottom: 2px; }
    .bm-snapin-head { display: flex; align-items: center; gap: 4px; padding: 5px 6px; cursor: pointer; border-radius: 6px; }
    .bm-snapin-head:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-off .bm-sname { opacity: 0.55; }
    .bm-chev, .bm-sicon { font-size: 18px; width: 18px; height: 18px; }
    .bm-sname { font-size: 13px; }
    .bm-mmceq { padding: 0 6px 4px 46px; font-family: ui-monospace, monospace; }
    .bm-state { font-size: 10px; padding: 1px 6px; border-radius: 8px; margin-left: auto;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 14%, transparent); }
    .bm-state--unavailable { background: color-mix(in srgb, var(--bm-red, #c62828) 20%, transparent); }
    .bm-state--unknown { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 22%, transparent); }
    .bm-node { display: flex; align-items: center; gap: 8px; width: calc(100% - 22px); margin-left: 22px;
      padding: 5px 8px; border: 0; border-radius: 6px; background: transparent; color: inherit; font: inherit;
      font-size: 13px; text-align: left; cursor: pointer; }
    .bm-node:hover:not(:disabled) { background: color-mix(in srgb, var(--mat-sys-on-surface) 7%, transparent); }
    .bm-node:disabled { opacity: 0.4; cursor: not-allowed; }
    .bm-node mat-icon { font-size: 17px; width: 17px; height: 17px; }
    .bm-node.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 18%, transparent); font-weight: 600; }
    .bm-result { padding: 14px 18px 0; overflow: hidden; display: flex; flex-direction: column; }
    .bm-result-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; }
    .bm-result-head h2 { margin: 0 0 2px; font-size: 18px; }
    .bm-head-actions { display: flex; gap: 8px; align-items: center; }
    .bm-filter { padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; min-width: 180px; }
    .bm-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 6px;
      height: 100%; max-width: 520px; margin: 0 auto; text-align: center; }
    .bm-empty mat-icon { font-size: 46px; width: 46px; height: 46px; opacity: 0.35; }
    .bm-table-wrap { flex: 1; overflow: auto; margin-top: 12px; }
    .bm-table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-table th { position: sticky; top: 0; z-index: 1; text-align: left; padding: 7px 10px; font-size: 11px;
      text-transform: uppercase; opacity: 0.65; background: var(--mat-sys-surface);
      border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-table td { padding: 5px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); white-space: nowrap;
      overflow: hidden; text-overflow: ellipsis; max-width: 460px; }
    .bm-table tbody tr:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-table tbody tr.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-num { text-align: right; font-variant-numeric: tabular-nums; }
    .bm-act-col { width: 120px; text-align: right; white-space: nowrap; }
    .bm-badge { font-size: 11px; padding: 1px 8px; border-radius: 9px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
    .bm-badge--good { background: color-mix(in srgb, var(--bm-green, #2e7d32) 24%, transparent); }
    .bm-badge--warn { background: color-mix(in srgb, var(--bm-amber, #ef6c00) 26%, transparent); }
    .bm-badge--bad { background: color-mix(in srgb, var(--bm-red, #c62828) 26%, transparent); }
    .bm-actions { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; padding: 10px 0 14px;
      border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-last { font-size: 12px; opacity: 0.75; }
    .bm-err { color: var(--bm-red, #c62828); }
  `],
})
export class MmcConsoleComponent {
  /** The host this console is rooted at. */
  agentId = input.required<string>();

  private svc = inject(MmcService);
  private snack = inject(MatSnackBar);

  tree = signal<ConsoleTree | null>(null);
  node = signal<NodeResult | null>(null);
  open = signal<Set<string>>(new Set());
  selected = signal<{ snapin: string; node: string } | null>(null);
  selectedRow = signal<Record<string, unknown> | null>(null);
  running = signal<string | null>(null);
  lastResult = signal<string>('');
  /** A SIGNAL, not a field: `visibleRows` is a computed, and a computed cannot see a plain property change —
   * the filter box typed happily and filtered nothing. Caught in the browser, not by the compiler. */
  filter = signal('');

  constructor() {
    // Keyed on the input rather than read in the constructor: a required input is not available yet when the
    // component is constructed (NG0950), which is a mistake this codebase has already paid for once.
    effect(() => {
      const id = this.agentId();
      if (!id) return;
      this.node.set(null);
      this.selected.set(null);
      this.svc.tree(id).subscribe((t) => {
        this.tree.set(t);
        // The first available snap-in opens, so the console is not an empty room on arrival.
        const first = t.snapins.find((s) => s.state === 'available');
        if (first) this.open.set(new Set([first.id]));
      });
    });
  }

  toggle(id: string): void {
    const next = new Set(this.open());
    next.has(id) ? next.delete(id) : next.add(id);
    this.open.set(next);
  }

  isSelected(snapin: string, node: string): boolean {
    const s = this.selected();
    return s?.snapin === snapin && s?.node === node;
  }

  select(snapin: Snapin, nodeId: string): void {
    this.selected.set({ snapin: snapin.id, node: nodeId });
    this.selectedRow.set(null);
    this.lastResult.set('');
    this.reloadNode();
  }

  reloadNode(): void {
    const sel = this.selected();
    if (!sel) return;
    this.svc.node(this.agentId(), sel.snapin, sel.node).subscribe({
      next: (n) => this.node.set(n),
      // An error here is the request failing, not the host being unreadable (that arrives as `error` in a
      // 200 answer) — so it is shown as what it is rather than as an empty node.
      error: (e) => this.snack.open(`Could not load the node: ${e?.error?.detail ?? e.message}`, 'Dismiss',
        { duration: 8000 }),
    });
  }

  visibleRows = computed(() => {
    const rows = this.node()?.rows ?? [];
    const needle = this.filter().trim().toLowerCase();
    if (!needle) return rows;
    return rows.filter((r) => Object.values(r).some((v) => String(v ?? '').toLowerCase().includes(needle)));
  });

  cell(row: Record<string, unknown>, column: SnapinColumn): string {
    let value = row[column.key];
    if ((value === null || value === undefined || value === '') && column.fallback) {
      value = row[column.fallback];
    }
    if (Array.isArray(value)) return value.join(column.join ?? ', ');
    if (value === null || value === undefined) return '';
    return String(value);
  }

  /** The rendered cell — the same value as `cell`, with the column's unit applied. */
  display(row: Record<string, unknown>, column: SnapinColumn): string {
    const raw = row[column.key];
    if (column.kind === 'bytes' && typeof raw === 'number') return this.bytes(raw);
    if (column.kind === 'time' && raw) {
      // Locale-formatted through the same pipe the rest of the product uses, so one timestamp does not look
      // like two different kinds of thing on two screens.
      const date = new Date(String(raw));
      return isNaN(date.getTime()) ? String(raw) : date.toLocaleString();
    }
    return this.cell(row, column);
  }

  private bytes(value: number): string {
    if (value <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const exp = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
    const scaled = value / Math.pow(1024, exp);
    return `${scaled.toFixed(scaled >= 100 || exp === 0 ? 0 : 1)} ${units[exp]}`;
  }

  depth(row: Record<string, unknown>, column: SnapinColumn): number {
    const key = column.indent_key;
    const value = key ? row[key] : 0;
    return typeof value === 'number' ? value : 0;
  }

  /**
   * The badge class for a state word. Deliberately a small fixed vocabulary rather than a colour per value:
   * an unknown word gets the neutral pill, which is better than an arbitrary colour implying a judgement the
   * server never made.
   */
  badgeClass(value: string): string {
    const v = value.toLowerCase();
    if (['running', 'healthy', 'auto', 'true', 'enabled', 'installed', 'ok'].includes(v)) return 'good';
    if (['warning', 'maybe', 'manual', 'awaiting-restart', 'installpending', 'uninstallpending'].includes(v)) return 'warn';
    if (['error', 'critical', 'unhealthy', 'failed', 'disabled', 'removed'].includes(v)) return 'bad';
    return 'neutral';
  }

  actionsFor(row: Record<string, unknown>): SnapinAction[] {
    return (this.node()?.actions ?? []).filter((a) => {
      if (!a.hide_when) return true;
      // AN IMPOSSIBLE ACTION IS NOT OFFERED. "Start" on a running service would be answered by the host with
      // "already in that state", which is a correct answer to a question nobody should have been able to ask.
      return String(row[a.hide_when.field] ?? '') !== String(a.hide_when.equals);
    });
  }

  label(row: Record<string, unknown>): string {
    const first = this.node()?.columns?.[0]?.key;
    return String((first ? row[first] : null) ?? '(row)');
  }

  run(action: SnapinAction, row: Record<string, unknown>, event: Event | null): void {
    event?.stopPropagation();
    const params = this.fill(action.params, row);
    if (action.confirm && !confirm(
      `${action.title} — ${this.label(row)} on ${this.tree()?.host}?\n\n`
      + `This runs the ${action.tool} module with:\n${JSON.stringify(params, null, 2)}`)) {
      return;
    }
    this.running.set(action.id);
    this.svc.runAction(this.agentId(), action.tool, params).subscribe({
      next: (r) => {
        this.running.set(null);
        const msg = r.result?.msg ?? (r.result?.changed ? 'changed' : 'unchanged');
        this.lastResult.set(`${action.title}: ${msg}`);
        this.snack.open(`${action.title}: ${msg}`, 'Dismiss', { duration: 6000 });
        // Re-read rather than patching the row in place: the host is the authority on what it now is, and a
        // locally invented state is how a UI ends up disagreeing with the machine it manages.
        this.reloadNode();
      },
      error: (e) => {
        this.running.set(null);
        const detail = e?.error?.detail ?? e.message;
        this.lastResult.set(`${action.title} failed: ${detail}`);
        // The host's own words, not a generic failure: a refusal ("Storage Services cannot be removed") is
        // the useful part of the answer.
        this.snack.open(`${action.title} failed: ${detail}`, 'Dismiss', { duration: 12000 });
      },
    });
  }

  /** Substitute {row.field} placeholders from the selected row; other values pass through unchanged. */
  private fill(params: Record<string, unknown>, row: Record<string, unknown>): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(params)) {
      if (typeof value === 'string') {
        const match = /^\{row\.([A-Za-z0-9_]+)\}$/.exec(value);
        out[key] = match ? row[match[1]] : value;
      } else {
        out[key] = value;
      }
    }
    return out;
  }
}
