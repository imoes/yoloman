import { Component, inject, input, model, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../../core/services/agent.service';

interface FindEntry { path: string; isdir: boolean; }

/**
 * Reusable remote FILE picker — a text field bound to a path plus a browse
 * button that lists the current directory's subfolders (to descend) and its
 * files (to pick), via the agent `find` module. Optional `pattern` (comma/space
 * separated globs like "*.pem *.crt *.key") filters which files are selectable.
 * Sibling of dir-picker (which lists directories only); used for cert/key paths.
 *
 * Usage: <app-file-picker [agentId]="id" [(value)]="path" pattern="*.pem" />
 */
@Component({
  selector: 'app-file-picker',
  standalone: true,
  imports: [MatIconModule],
  template: `
    <div class="bm-fp">
      <div class="bm-fp-row">
        <input class="bm-fp-in" [value]="value()" (input)="value.set($any($event.target).value)" [placeholder]="placeholder()" />
        <button class="bm-fp-btn" (click)="toggle()" title="Browse files" type="button"><mat-icon>folder_open</mat-icon></button>
      </div>
      @if (open()) {
        <div class="bm-fp-panel">
          <div class="bm-fp-head"><span class="bm-fp-cwd">{{ cwd() }}</span></div>
          @if (loading()) { <div class="bm-fp-dim">loading…</div> }
          @else {
            <button class="bm-fp-item" (click)="up()" type="button" [disabled]="cwd()==='/'"><mat-icon>arrow_upward</mat-icon> up</button>
            @for (d of dirs(); track d) {
              <button class="bm-fp-item" (click)="descend(d)" type="button"><mat-icon>folder</mat-icon> {{ base(d) }}</button>
            }
            @for (f of files(); track f) {
              <button class="bm-fp-item bm-fp-file" (click)="pick(f)" type="button"><mat-icon>description</mat-icon> {{ base(f) }}</button>
            }
            @if (!dirs().length && !files().length) { <div class="bm-fp-dim">no matching files</div> }
          }
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-fp { position: relative; }
    .bm-fp-row { display: flex; gap: 6px; }
    .bm-fp-in { flex: 1; box-sizing: border-box; padding: 4px 7px; border-radius: 5px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font: inherit; font-size: 12.5px; }
    .bm-fp-btn { border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); border-radius: 5px; cursor: pointer; color: inherit; padding: 0 8px; display: flex; align-items: center; }
    .bm-fp-panel { position: absolute; z-index: 30; top: 100%; left: 0; right: 0; margin-top: 4px; max-height: 260px; overflow: auto;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; background: var(--mat-sys-surface); box-shadow: 0 6px 20px rgba(0,0,0,0.25); }
    .bm-fp-head { padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); position: sticky; top: 0; background: var(--mat-sys-surface); }
    .bm-fp-cwd { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
    .bm-fp-item { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; border: 0; background: none; color: inherit; padding: 6px 10px; cursor: pointer; font-size: 13px; }
    .bm-fp-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    .bm-fp-item mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.75; }
    .bm-fp-file mat-icon { color: var(--mat-sys-primary); }
    .bm-fp-dim { opacity: 0.6; font-size: 12px; padding: 8px 10px; }
  `],
})
export class FilePickerComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  value = model<string>('');
  placeholder = input<string>('/etc/ssl/certs/site.pem');
  pattern = input<string>('');   // e.g. "*.pem *.crt *.key" — empty = all files

  open = signal(false);
  loading = signal(false);
  cwd = signal('/etc');
  dirs = signal<string[]>([]);
  files = signal<string[]>([]);

  base(p: string): string { return p.replace(/\/+$/, '').split('/').pop() || p; }

  private suffixes(): string[] {
    return this.pattern().split(/[\s,]+/).map((s) => s.trim().replace(/^\*/, '')).filter(Boolean);
  }
  private matches(path: string): boolean {
    const sfx = this.suffixes();
    return !sfx.length || sfx.some((s) => path.endsWith(s));
  }

  toggle(): void {
    this.open.update((o) => !o);
    if (this.open()) {
      const v = this.value().trim();
      this.cwd.set(v.startsWith('/') ? (v.replace(/\/[^/]*$/, '') || '/') : '/etc');
      this.list();
    }
  }

  private list(): void {
    this.loading.set(true);
    this.agentService.callTool(this.agentId(), 'find', { paths: [this.cwd()], file_type: 'any' }).subscribe({
      next: (resp) => {
        this.loading.set(false);
        const data = (resp.result as { data?: FindEntry[] })?.data || [];
        const here = this.cwd();
        this.dirs.set(data.filter((e) => e.isdir && e.path !== here).map((e) => e.path).sort());
        this.files.set(data.filter((e) => !e.isdir && this.matches(e.path)).map((e) => e.path).sort());
      },
      error: () => { this.loading.set(false); this.dirs.set([]); this.files.set([]); },
    });
  }

  descend(dir: string): void { this.cwd.set(dir); this.list(); }
  up(): void { this.cwd.set(this.cwd().replace(/\/[^/]*\/?$/, '') || '/'); this.list(); }
  pick(file: string): void { this.value.set(file); this.open.set(false); }
}
