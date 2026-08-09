import { Component, inject, input, model, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { AgentService } from '../../../core/services/agent.service';

interface FindEntry { path: string; isdir: boolean; }

/**
 * Reusable remote directory picker — a text field bound to a path plus a
 * "browse" button that opens an inline panel listing the subdirectories of the
 * current path (via the agent's `find` module, file_type=directory). Click a
 * folder to descend, "‹ up" to ascend, "Use this folder" to select. The path
 * stays editable by hand. No new agent capability — `find` already lists dirs.
 *
 * Usage: <app-dir-picker [agentId]="id" [(value)]="path" />
 */
@Component({
  selector: 'app-dir-picker',
  standalone: true,
  imports: [MatIconModule],
  template: `
    <div class="bm-dp">
      <div class="bm-dp-row">
        <input class="bm-dp-in" [value]="value()" (input)="value.set($any($event.target).value)" [placeholder]="placeholder()" />
        <button class="bm-dp-btn" (click)="toggle()" title="Browse directories" type="button"><mat-icon>folder_open</mat-icon></button>
      </div>
      @if (open()) {
        <div class="bm-dp-panel">
          <div class="bm-dp-head">
            <span class="bm-dp-cwd">{{ cwd() }}</span>
            <button class="bm-dp-use" (click)="use()" type="button">Use this folder</button>
          </div>
          @if (loading()) { <div class="bm-dp-dim">loading…</div> }
          @else {
            <button class="bm-dp-item" (click)="up()" type="button" [disabled]="cwd()==='/'"><mat-icon>arrow_upward</mat-icon> up</button>
            @for (d of dirs(); track d) {
              <button class="bm-dp-item" (click)="descend(d)" type="button"><mat-icon>folder</mat-icon> {{ base(d) }}</button>
            }
            @if (!dirs().length) { <div class="bm-dp-dim">no subdirectories</div> }
          }
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-dp { position: relative; }
    .bm-dp-row { display: flex; gap: 6px; }
    .bm-dp-in { flex: 1; box-sizing: border-box; padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-dp-btn { border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); border-radius: 6px; cursor: pointer; color: inherit; padding: 0 8px; display: flex; align-items: center; }
    .bm-dp-panel { position: absolute; z-index: 30; top: 100%; left: 0; right: 0; margin-top: 4px; max-height: 260px; overflow: auto;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; background: var(--mat-sys-surface); box-shadow: 0 6px 20px rgba(0,0,0,0.25); }
    .bm-dp-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 10px; border-bottom: 1px solid var(--mat-sys-outline-variant); position: sticky; top: 0; background: var(--mat-sys-surface); }
    .bm-dp-cwd { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
    .bm-dp-use { font-size: 12px; border: 1px solid var(--mat-sys-primary); color: var(--mat-sys-primary); background: none; border-radius: 6px; padding: 3px 10px; cursor: pointer; white-space: nowrap; }
    .bm-dp-item { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; border: 0; background: none; color: inherit; padding: 6px 10px; cursor: pointer; font-size: 13px; }
    .bm-dp-item:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    .bm-dp-item mat-icon { font-size: 17px; width: 17px; height: 17px; opacity: 0.75; }
    .bm-dp-dim { opacity: 0.6; font-size: 12px; padding: 8px 10px; }
  `],
})
export class DirPickerComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();
  value = model<string>('');
  placeholder = input<string>('/srv/share');

  open = signal(false);
  loading = signal(false);
  cwd = signal('/');
  dirs = signal<string[]>([]);

  base(p: string): string { return p.replace(/\/+$/, '').split('/').pop() || p; }

  toggle(): void {
    this.open.update((o) => !o);
    if (this.open()) {
      // Seed the browse dir from the current value if it looks like a path.
      const v = this.value().trim();
      this.cwd.set(v.startsWith('/') ? v.replace(/\/[^/]*$/, '') || '/' : '/');
      this.list();
    }
  }

  private list(): void {
    this.loading.set(true);
    this.agentService.callTool(this.agentId(), 'find', { paths: [this.cwd()], file_type: 'directory' }).subscribe({
      next: (resp) => {
        this.loading.set(false);
        const data = (resp.result as { data?: FindEntry[] })?.data || [];
        this.dirs.set(data.map((e) => e.path).filter((p) => p !== this.cwd()).sort());
      },
      error: () => { this.loading.set(false); this.dirs.set([]); },
    });
  }

  descend(dir: string): void { this.cwd.set(dir); this.list(); }
  up(): void { this.cwd.set(this.cwd().replace(/\/[^/]*\/?$/, '') || '/'); this.list(); }
  use(): void { this.value.set(this.cwd()); this.open.set(false); }
}
