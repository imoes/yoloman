import { Component, computed, inject, input, signal, viewChild } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatButtonToggleModule } from '@angular/material/button-toggle';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { LogEntry, LogFilters } from '../../../core/models/agent.model';
import { HostLogfilesComponent } from './host-logfiles.component';

/** Block J4b — the unified "Logs" section of the host-management page. One
 * place for both log sources, switchable via a Journal / Files toggle so the
 * experience stays consistent: "Journal" reads systemd/journald (read-only
 * `journal` module) with unit/priority/since filters; "Files" browses/tails
 * /var/log via the path-jailed `logfiles` module (Monaco). Nothing is pulled
 * until the tab is opened (loadOnce) or the user acts. */
@Component({
  selector: 'app-host-logs',
  standalone: true,
  imports: [MatButtonModule, MatButtonToggleModule, MatProgressSpinnerModule, HostLogfilesComponent],
  template: `
    <div class="bm-mgmt-section">
      <mat-button-toggle-group class="bm-log-mode" [value]="mode()" (change)="setMode($event.value)" hideSingleSelectionIndicator>
        <mat-button-toggle value="journal">Journal (journald)</mat-button-toggle>
        <mat-button-toggle value="files">Files (/var/log)</mat-button-toggle>
      </mat-button-toggle-group>

      @if (mode() === 'files') {
        <app-host-logfiles [agentId]="agentId()" />
      } @else {
      <div class="bm-mgmt-toolbar">
        <input class="bm-log-in" type="text" placeholder="unit (e.g. nginx)" [value]="unit()" (input)="unit.set($any($event.target).value)" (keyup.enter)="load()" />
        <select class="bm-log-in" [value]="priority()" (change)="priority.set($any($event.target).value); load()">
          <option value="">any priority</option>
          <option value="3">err+ (0-3)</option>
          <option value="4">warning+ (0-4)</option>
          <option value="6">info+ (0-6)</option>
        </select>
        <input class="bm-log-in" type="text" placeholder="since (e.g. -1h, yesterday)" [value]="since()" (input)="since.set($any($event.target).value)" (keyup.enter)="load()" />
        <input class="bm-log-in bm-log-grep" type="text" placeholder="grep MESSAGE…" [value]="grep()" (input)="grep.set($any($event.target).value)" (keyup.enter)="load()" />
        <button mat-stroked-button (click)="load()" [disabled]="loading()">Load</button>
        <span class="bm-mgmt-count">{{ entries().length }} entries</span>
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (!loaded()) {
        <p class="bm-empty">Hit Load to fetch the latest journal entries.</p>
      } @else if (!entries().length) {
        <p class="bm-empty">No matching journal entries.</p>
      } @else {
        <pre class="bm-log-view">@for (e of entries(); track $index) {<span class="bm-log-line" [class.bm-log-err]="isErr(e)"><span class="bm-log-ts">{{ e.timestamp }}</span> <span class="bm-log-unit">{{ e.unit }}</span>: {{ e.message }}
</span>}</pre>
      }
      }
    </div>
  `,
  styles: [
    `.bm-log-mode { margin-bottom: 12px; }`,
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-log-in { padding: 6px 8px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-log-grep { flex: 1 1 180px; }
      .bm-mgmt-count { color: var(--bm-muted, #888); font-size: 12px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-log-view { max-height: 60vh; overflow: auto; background: var(--bm-code-bg, #1e1e1e); color: #d4d4d4; padding: 10px; border-radius: 6px; font-size: 12px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; }
      .bm-log-line { display: block; }
      .bm-log-ts { color: #6a9955; }
      .bm-log-unit { color: #569cd6; }
      .bm-log-err { color: #f48771; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
      .bm-empty { color: var(--bm-muted, #888); }
    `,
  ],
})
export class HostLogsComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();

  private logfiles = viewChild(HostLogfilesComponent);
  mode = signal<'journal' | 'files'>('journal');

  setMode(m: 'journal' | 'files'): void {
    this.mode.set(m);
    if (m === 'files') setTimeout(() => this.logfiles()?.loadOnce());
    else this.loadOnce();
  }

  unit = signal('');
  priority = signal('');
  since = signal('');
  grep = signal('');

  entries = signal<LogEntry[]>([]);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);

  isErr = (e: LogEntry) => Number(e.priority) <= 3 && e.priority !== '';

  /** First open: pull the default (last 200, no filter) view once. */
  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.load();
  }

  load(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    const filters: LogFilters = {
      lines: 200,
      unit: this.unit().trim() || undefined,
      priority: this.priority() || undefined,
      since: this.since().trim() || undefined,
      grep: this.grep().trim() || undefined,
    };
    this.agentService.logs(this.agentId(), filters).subscribe({
      next: (res) => {
        this.entries.set(res.entries ?? []);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load logs');
      },
    });
  }
}
