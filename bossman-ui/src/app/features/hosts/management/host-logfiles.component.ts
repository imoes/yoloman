import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import * as monaco from 'monaco-editor';
import { AgentService } from '../../../core/services/agent.service';

// Monaco locally, no CDN — a no-op worker (we only read, no language services).
(self as unknown as { MonacoEnvironment: unknown }).MonacoEnvironment = {
  getWorker() {
    return new Worker(URL.createObjectURL(new Blob(['self.onmessage=function(){}'], { type: 'text/javascript' })));
  },
};

interface LogFile { path: string; size: number; modified: number; }

/** /var/log file viewer: the path-jailed `logfiles` module lists the host's
 * plain-text logs (+ operator-added custom paths); selecting one tails it into
 * a read-only Monaco editor with an optional grep. Users read logs here; the
 * same data feeds the AI's error-source analysis (with the eBPF metrics). */
@Component({
  selector: 'app-host-logfiles',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-lf">
      <aside class="bm-lf-list">
        <div class="bm-lf-head">
          <strong>Log files</strong>
          <button mat-icon-button (click)="reload()" [disabled]="loading()" title="Reload"><mat-icon>refresh</mat-icon></button>
        </div>
        <div class="bm-lf-custom">
          <input type="text" placeholder="add custom path (e.g. /opt/app/app.log)" [(ngModel)]="customPath" (keyup.enter)="addCustom()" />
          <button mat-icon-button (click)="addCustom()" title="Add path"><mat-icon>add</mat-icon></button>
        </div>
        @if (loadErr()) { <p class="bm-err">{{ loadErr() }}</p> }
        <ul>
          @for (f of files(); track f.path) {
            <li [class.bm-sel]="selected() === f.path" (click)="open(f.path)">
              <span class="bm-lf-name">{{ base(f.path) }}</span>
              <span class="bm-lf-dir">{{ dir(f.path) }}</span>
              <span class="bm-lf-size">{{ human(f.size) }}</span>
            </li>
          }
          @if (!files().length && !loading()) { <li class="bm-empty">No log files.</li> }
        </ul>
      </aside>
      <section class="bm-lf-view">
        <div class="bm-lf-bar">
          <span class="bm-lf-path">{{ selected() || 'select a file' }}</span>
          <span class="bm-spacer"></span>
          <input type="text" class="bm-grep" placeholder="grep…" [(ngModel)]="grep" (keyup.enter)="refreshContent()" />
          <button type="button" class="bm-tgl" [class.bm-on]="regex" (click)="regex = !regex; refreshContent()"
                  title="Extended regex (grep -E)">.*</button>
          <button type="button" class="bm-tgl" [class.bm-on]="invert" (click)="invert = !invert; refreshContent()"
                  title="Invert match — keep non-matching lines (grep -v)">≠</button>
          <select [(ngModel)]="lines" (ngModelChange)="refreshContent()">
            <option [ngValue]="200">200</option><option [ngValue]="500">500</option>
            <option [ngValue]="2000">2000</option><option [ngValue]="5000">5000</option>
          </select>
          <button mat-icon-button (click)="refreshContent()" [disabled]="!selected() || contentBusy()" title="Reload content"><mat-icon>refresh</mat-icon></button>
          @if (truncated()) { <span class="bm-trunc" title="Only the tail is shown">tail</span> }
        </div>
        <div class="bm-lf-editor" #editor></div>
      </section>
    </div>
  `,
  styles: [
    `
      .bm-lf { display: grid; grid-template-columns: 300px 1fr; gap: 12px; height: 70vh; }
      @media (max-width: 900px) { .bm-lf { grid-template-columns: 1fr; height: auto; } }
      .bm-lf-list { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: auto; display: flex; flex-direction: column; }
      .bm-lf-head { display: flex; align-items: center; justify-content: space-between; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-lf-custom { display: flex; gap: 4px; padding: 6px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-lf-custom input { flex: 1; padding: 5px 7px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; font-size: 12px; }
      .bm-lf-list ul { list-style: none; margin: 0; padding: 0; overflow: auto; }
      .bm-lf-list li { padding: 6px 10px; cursor: pointer; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); display: grid; grid-template-columns: 1fr auto; gap: 2px 8px; font-size: 12.5px; }
      .bm-lf-list li:hover { background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
      .bm-lf-list li.bm-sel { background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-lf-name { font-family: monospace; font-weight: 600; }
      .bm-lf-dir { grid-column: 1; opacity: 0.5; font-size: 11px; font-family: monospace; }
      .bm-lf-size { grid-row: 1; grid-column: 2; opacity: 0.6; font-variant-numeric: tabular-nums; }
      .bm-empty { opacity: 0.6; cursor: default; }
      .bm-lf-view { display: flex; flex-direction: column; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; min-height: 300px; }
      .bm-lf-bar { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-lf-path { font-family: monospace; font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .bm-spacer { flex: 1; }
      .bm-grep { padding: 5px 7px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; font-size: 12px; width: 130px; }
      .bm-tgl { min-width: 26px; height: 26px; padding: 0 5px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; font-family: monospace; font-size: 13px; cursor: pointer; }
      .bm-tgl:hover { background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
      .bm-tgl.bm-on { background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); border-color: var(--mat-sys-primary); font-weight: 700; }
      .bm-lf-bar select { padding: 4px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: inherit; }
      .bm-trunc { font-size: 11px; padding: 1px 7px; border-radius: 999px; background: color-mix(in srgb, #ed6c02 18%, transparent); color: #e65100; }
      .bm-lf-editor { flex: 1; min-height: 260px; }
      .bm-err { color: #c62828; font-size: 12px; padding: 6px 10px; }
    `,
  ],
})
export class HostLogfilesComponent implements AfterViewInit, OnDestroy {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  @ViewChild('editor') editorEl!: ElementRef<HTMLDivElement>;

  files = signal<LogFile[]>([]);
  selected = signal<string | null>(null);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  contentBusy = signal(false);
  truncated = signal(false);
  customPath = '';
  grep = '';
  regex = false;
  invert = false;
  lines = 500;
  private extraPaths: string[] = [];
  private ed?: monaco.editor.IStandaloneCodeEditor;
  private pendingContent: string | null = null;

  ngAfterViewInit(): void {
    this.ed = monaco.editor.create(this.editorEl.nativeElement, {
      value: this.pendingContent ?? '',
      language: 'plaintext',
      readOnly: true,
      automaticLayout: true,
      minimap: { enabled: false },
      lineNumbers: 'on',
      scrollBeyondLastLine: false,
      fontSize: 12,
      theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'vs-dark' : 'vs',
    });
  }

  ngOnDestroy(): void {
    this.ed?.dispose();
  }

  /** Called when the tab is first shown. */
  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.logFiles(this.agentId(), this.extraPaths).subscribe({
      next: (res) => { this.files.set(res.files ?? []); this.loading.set(false); this.loaded.set(true); },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.loadErr.set(e?.error?.detail ?? 'failed to list log files'); },
    });
  }

  addCustom(): void {
    const p = this.customPath.trim();
    if (!p || this.extraPaths.includes(p)) return;
    this.extraPaths.push(p);
    this.customPath = '';
    this.reload();
  }

  open(path: string): void {
    this.selected.set(path);
    this.refreshContent();
  }

  refreshContent(): void {
    const path = this.selected();
    if (!path) return;
    this.contentBusy.set(true);
    this.agentService.logFile(this.agentId(), path, this.lines, this.grep, this.extraPaths, this.regex, this.invert).subscribe({
      next: (res) => {
        this.contentBusy.set(false);
        this.truncated.set(!!res.truncated);
        this.setContent((res.lines ?? []).join('\n'));
      },
      error: (e) => { this.contentBusy.set(false); this.setContent(`# failed to read: ${e?.error?.detail ?? 'error'}`); },
    });
  }

  private setContent(text: string): void {
    if (this.ed) {
      this.ed.setValue(text);
      this.ed.revealLine(this.ed.getModel()?.getLineCount() ?? 1); // scroll to newest
    } else {
      this.pendingContent = text;
    }
  }

  base(p: string): string { return p.split('/').pop() || p; }
  dir(p: string): string { const i = p.lastIndexOf('/'); return i > 0 ? p.slice(0, i) : ''; }
  human(n: number): string {
    if (!n) return '0';
    const u = ['B', 'K', 'M', 'G'];
    let i = 0, x = n;
    while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
    return `${x >= 10 || i === 0 ? Math.round(x) : x.toFixed(1)}${u[i]}`;
  }
}
