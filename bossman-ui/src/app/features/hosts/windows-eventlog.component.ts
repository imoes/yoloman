import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { AgentService } from '../../core/services/agent.service';

/** One event, as the agent's `windows_eventlog` module returns it. */
interface WinEvent {
  time: string;
  id: number;
  /** Windows' numeric level — authoritative. */
  level: number;
  /** OUR canonical name (critical/error/warning/…) — the one to filter and display on. */
  level_name: string;
  /** What the HOST calls it: localised ("Fehler", "Warnung"), and sometimes empty. */
  level_display: string | null;
  log: string;
  provider: string;
  machine: string;
  message: string;
}

interface EventLogResult {
  events: WinEvent[];
  count: number;
  capped: boolean;
  max_events: number;
  since: string;
  logs: string[];
  levels: string[];
  by_level: Record<string, number>;
  by_provider: Record<string, number>;
}

interface Channel {
  name: string;
  records: number;
  size_bytes: number;
  enabled: boolean;
  /** Circular | AutoBackup | Retain — whether an absent event never happened or has rotated away. */
  retention: string | null;
}

/**
 * The Windows event log, for the person.
 *
 * The same filtered read the AI gets through MCP — deliberately, because two views of one log that filter
 * differently is how an operator and an assistant end up describing different machines. The module does the
 * filtering ON THE HOST (measured: 50 events in 0.04 s), so this component sends a query rather than
 * receiving a channel and sifting it.
 *
 * THE LEVEL NAMES HERE ARE THE CANONICAL ONES, never the host's own: `level_display` on a German host reads
 * "Fehler"/"Warnung", so a filter built on it would work on some of the fleet and silently fail on the rest.
 * The host's word is still SHOWN, next to ours — it is what an operator sees in Event Viewer and will search
 * for.
 *
 * And ERROR is on by default alongside critical and warning, because "warnings and critical" is not what an
 * operator means: thirty days on the test host gave 126 errors, 126 warnings and ZERO criticals.
 */
@Component({
  selector: 'app-windows-eventlog',
  standalone: true,
  imports: [CommonModule, FormsModule],
  template: `
    <div class="bm-evlog">
      <div class="bm-evlog-bar">
        <div class="bm-levels">
          @for (l of LEVELS; track l.name) {
            <label class="bm-level" [class.bm-level--on]="selectedLevels().includes(l.name)"
                   [attr.data-level]="l.name">
              <input type="checkbox" [checked]="selectedLevels().includes(l.name)"
                     (change)="toggleLevel(l.name)" />
              {{ l.label }}
              @if (result()?.by_level?.[l.name]) {
                <span class="bm-count">{{ result()!.by_level[l.name] }}</span>
              }
            </label>
          }
        </div>

        <label class="bm-field">
          Since
          <select [ngModel]="since()" (ngModelChange)="since.set($event); reload()">
            <option value="1h">last hour</option>
            <option value="24h">last 24 hours</option>
            <option value="7d">last 7 days</option>
            <option value="30d">last 30 days</option>
          </select>
        </label>

        <label class="bm-field">
          Max
          <select [ngModel]="maxEvents()" (ngModelChange)="maxEvents.set($event); reload()">
            <option [ngValue]="200">200</option>
            <option [ngValue]="500">500</option>
            <option [ngValue]="2000">2000</option>
          </select>
        </label>

        <input class="bm-search" type="search" placeholder="message contains…"
               [ngModel]="contains()" (ngModelChange)="contains.set($event)"
               (keyup.enter)="reload()" />

        <button class="bm-btn" (click)="reload()" [disabled]="loading()">
          {{ loading() ? 'Reading…' : 'Refresh' }}
        </button>
      </div>

      <!-- THE CATEGORIES. 406 channels exist on a Server 2022 and ~83 hold anything, so the picker starts
           from what has records and says how many — choosing blind from 406 names is not choosing. -->
      <details class="bm-channels" [open]="channelsOpen()">
        <summary (click)="loadChannels()">
          Categories: <strong>{{ selectedLogs().join(', ') }}</strong>
          @if (channels().length) { <span class="bm-dim">— {{ channels().length }} with records</span> }
        </summary>
        @if (channels().length) {
          <div class="bm-channel-list">
            @for (c of channels(); track c.name) {
              <label class="bm-channel" [class.bm-channel--on]="selectedLogs().includes(c.name)">
                <input type="checkbox" [checked]="selectedLogs().includes(c.name)"
                       (change)="toggleLog(c.name)" />
                <span class="bm-mono">{{ c.name }}</span>
                <span class="bm-dim">{{ c.records | number }} records</span>
                <!-- Retention is shown because it decides what an ABSENCE means: a Circular channel that has
                     rotated is not a channel where nothing happened. -->
                <span class="bm-chip">{{ c.retention }}</span>
              </label>
            }
          </div>
        } @else if (channelsLoading()) {
          <p class="bm-dim">Reading the channel inventory…</p>
        }
      </details>

      @if (error(); as e) {
        <p class="bm-error">{{ e }}</p>
      }

      @if (result(); as r) {
        <p class="bm-summary">
          {{ r.count | number }} event(s) since {{ r.since }}
          @if (r.capped) {
            <!-- A capped answer is a FLOOR, not a total. Saying "200 events" about a cap is the one thing a
                 log reader must not do. -->
            <strong class="bm-capped">— capped at {{ r.max_events }}, there may be more</strong>
          }
          @if (topProviders().length) {
            <span class="bm-dim"> · loudest: </span>
            @for (p of topProviders(); track p.name) {
              <span class="bm-chip" (click)="filterProvider(p.name)">{{ p.name }} {{ p.count }}</span>
            }
          }
          @if (provider()) {
            <button class="bm-btn bm-btn--sm" (click)="provider.set(''); reload()">
              clear provider: {{ provider() }}
            </button>
          }
        </p>

        @if (r.events.length) {
          <div class="bm-table-wrap">
            <table class="bm-table">
              <thead>
                <tr><th>Time</th><th>Level</th><th>Provider</th><th>ID</th><th>Channel</th><th>Message</th></tr>
              </thead>
              <tbody>
                @for (e of r.events; track e.time + e.id + e.message) {
                  <tr [attr.data-level]="e.level_name">
                    <td class="bm-mono bm-nowrap">{{ e.time }}</td>
                    <td>
                      <span class="bm-level-tag" [attr.data-level]="e.level_name">{{ e.level_name }}</span>
                      <!-- The host's own word, next to ours: it is what Event Viewer shows and what an
                           operator will search for. Empty for some events, which is why ours exists. -->
                      @if (e.level_display) { <span class="bm-dim"> {{ e.level_display }}</span> }
                    </td>
                    <td>{{ e.provider }}</td>
                    <td class="bm-mono">{{ e.id }}</td>
                    <td class="bm-dim">{{ e.log }}</td>
                    <td class="bm-msg">{{ e.message }}</td>
                  </tr>
                }
              </tbody>
            </table>
          </div>
        } @else {
          <!-- NOT "no data": the query is named, so an empty result is a statement about this host rather
               than a shrug. -->
          <p class="bm-empty">
            No {{ selectedLevels().join('/') }} events in {{ selectedLogs().join(', ') }} for the selected
            period. That is an answer about this host, not a missing reading.
          </p>
        }
      } @else if (loading()) {
        <p class="bm-dim">Reading the event log…</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-evlog { display: flex; flex-direction: column; gap: 0.75rem; }
      .bm-evlog-bar { display: flex; flex-wrap: wrap; gap: 0.75rem; align-items: center; }
      .bm-levels { display: flex; gap: 0.35rem; flex-wrap: wrap; }
      .bm-level { display: inline-flex; align-items: center; gap: 0.3rem; padding: 0.15rem 0.5rem;
        border: 1px solid var(--bm-border, #4448); border-radius: 999px; font-size: 0.85rem;
        cursor: pointer; opacity: 0.55; }
      .bm-level--on { opacity: 1; }
      .bm-level[data-level='critical'].bm-level--on { border-color: #b3261e; color: #b3261e; }
      .bm-level[data-level='error'].bm-level--on { border-color: #d93025; color: #d93025; }
      .bm-level[data-level='warning'].bm-level--on { border-color: #b26a00; color: #b26a00; }
      .bm-level input { margin: 0; }
      .bm-count { font-variant-numeric: tabular-nums; opacity: 0.75; }
      .bm-field { display: inline-flex; align-items: center; gap: 0.35rem; font-size: 0.85rem; }
      .bm-search { min-width: 14rem; }
      .bm-btn--sm { font-size: 0.75rem; padding: 0 0.4rem; }
      .bm-channels { border: 1px solid var(--bm-border, #4448); border-radius: 6px; padding: 0.4rem 0.6rem; }
      .bm-channels summary { cursor: pointer; }
      .bm-channel-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(24rem, 1fr));
        gap: 0.2rem 1rem; max-height: 16rem; overflow-y: auto; margin-top: 0.5rem; }
      .bm-channel { display: grid; grid-template-columns: auto 1fr auto auto; gap: 0.5rem;
        align-items: center; font-size: 0.82rem; opacity: 0.7; }
      .bm-channel--on { opacity: 1; font-weight: 500; }
      .bm-table-wrap { overflow-x: auto; }
      .bm-msg { max-width: 60ch; }
      .bm-nowrap { white-space: nowrap; }
      .bm-level-tag { font-size: 0.75rem; padding: 0.05rem 0.35rem; border-radius: 3px;
        background: var(--bm-chip-bg, #8882); }
      .bm-level-tag[data-level='critical'], .bm-level-tag[data-level='error'] { background: #d930251f; color: #d93025; }
      .bm-level-tag[data-level='warning'] { background: #b26a001f; color: #b26a00; }
      .bm-capped { color: #b26a00; }
      .bm-error { color: #d93025; }
      .bm-chip { font-size: 0.75rem; padding: 0.05rem 0.4rem; border-radius: 999px;
        background: var(--bm-chip-bg, #8882); cursor: pointer; }
    `,
  ],
})
export class WindowsEventlogComponent {
  private readonly agents = inject(AgentService);

  agentId = input.required<string>();

  /** OUR canonical names, in severity order. `log_always` and `verbose` are offered but off by default. */
  readonly LEVELS = [
    { name: 'critical', label: 'Critical' },
    { name: 'error', label: 'Error' },
    { name: 'warning', label: 'Warning' },
    { name: 'information', label: 'Information' },
    { name: 'verbose', label: 'Verbose' },
    { name: 'log_always', label: 'LogAlways (0)' },
  ];

  // Error is ON. "Warnings and critical" is not what an operator means — measured on the test host, thirty
  // days gave 126 errors, 126 warnings and zero criticals.
  readonly selectedLevels = signal<string[]>(['critical', 'error', 'warning']);
  readonly selectedLogs = signal<string[]>(['System', 'Application']);
  readonly since = signal('24h');
  readonly maxEvents = signal(200);
  readonly contains = signal('');
  readonly provider = signal('');

  readonly loading = signal(false);
  readonly error = signal<string | null>(null);
  readonly result = signal<EventLogResult | null>(null);

  readonly channels = signal<Channel[]>([]);
  readonly channelsLoading = signal(false);
  readonly channelsOpen = signal(false);

  readonly topProviders = computed(() =>
    Object.entries(this.result()?.by_provider ?? {})
      .map(([name, count]) => ({ name, count }))
      .slice(0, 5),
  );

  constructor() {
    // AN EFFECT KEYED ON THE INPUT, not a microtask in the constructor. The first version did the latter and
    // threw NG0950 ("input is required but no value is available yet") — a required input is not set when the
    // constructor runs, so reading agentId there is always too early. Exactly the mistake the standalone
    // overview panel made with metricsFrom, in the opposite direction: that one read the input once and never
    // saw it fill, this one read it before it existed.
    //
    // Keyed on agentId means it also reloads if the page is reused for another host, which a
    // read-once-on-open would not.
    effect(() => {
      const id = this.agentId();
      if (id) {
        this.reload();
      }
    });
  }

  toggleLevel(name: string): void {
    const next = this.selectedLevels().includes(name)
      ? this.selectedLevels().filter((l) => l !== name)
      : [...this.selectedLevels(), name];
    // At least one level, or the query means nothing — an empty selection would read as "no events" when it
    // is really "no question asked".
    this.selectedLevels.set(next.length ? next : [name]);
    this.reload();
  }

  toggleLog(name: string): void {
    const next = this.selectedLogs().includes(name)
      ? this.selectedLogs().filter((l) => l !== name)
      : [...this.selectedLogs(), name];
    this.selectedLogs.set(next.length ? next : [name]);
    this.reload();
  }

  filterProvider(name: string): void {
    this.provider.set(name);
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.error.set(null);
    const params: Record<string, unknown> = {
      logs: this.selectedLogs().join(','),
      levels: this.selectedLevels().join(','),
      since: this.since(),
      max_events: this.maxEvents(),
    };
    if (this.contains()) params['contains'] = this.contains();
    if (this.provider()) params['provider'] = this.provider();

    this.agents.callTool(this.agentId(), 'windows_eventlog', params).subscribe({
      next: (r) => {
        const data = (r.result as { data?: EventLogResult })?.data;
        this.result.set(data ?? null);
        this.loading.set(false);
      },
      error: (e) => {
        // The host's own words, not "request failed": a refusal or a timeout from the agent carries the
        // reason, and that reason is the useful part.
        this.error.set(e?.error?.detail ?? e?.message ?? 'the host did not answer');
        this.loading.set(false);
      },
    });
  }

  loadChannels(): void {
    this.channelsOpen.set(!this.channelsOpen());
    if (this.channels().length || this.channelsLoading()) return;
    this.channelsLoading.set(true);
    this.agents
      .callTool(this.agentId(), 'windows_eventlog_channels', { only_with_records: true })
      .subscribe({
        next: (r) => {
          const data = (r.result as { data?: { channels?: Channel[] } })?.data;
          this.channels.set(data?.channels ?? []);
          this.channelsLoading.set(false);
        },
        error: () => this.channelsLoading.set(false),
      });
  }
}
