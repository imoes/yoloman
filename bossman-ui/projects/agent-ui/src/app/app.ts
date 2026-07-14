import { Component, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HostViewComponent } from './host-view.component';
import { RunbookBuilderComponent } from './runbook-builder.component';
import { StateViewComponent } from './state-view.component';
import { TOKEN_KEY } from './agent-api.service';

/** Standalone-agent frontend shell: served by the agent itself at /ui, talking
 * to its own API. Two views — Host (read-only overview) and Runbooks (visual
 * builder → POST /api/v1/runbook/run). A token field feeds authInterceptor. */
@Component({
  selector: 'app-root',
  standalone: true,
  imports: [FormsModule, HostViewComponent, RunbookBuilderComponent, StateViewComponent],
  template: `
    <header>
      <strong>YOLO-MANager</strong> <span class="dim">standalone agent</span>
      <nav>
        <button [class.on]="view() === 'host'" (click)="view.set('host')">Host</button>
        <button [class.on]="view() === 'state'" (click)="view.set('state')">State</button>
        <button [class.on]="view() === 'runbooks'" (click)="view.set('runbooks')">Runbooks</button>
      </nav>
      <span class="spacer"></span>
      <input class="tok" type="password" [(ngModel)]="token" (ngModelChange)="saveToken()" placeholder="API token (optional)" />
    </header>
    <main>
      @switch (view()) {
        @case ('host') { <app-host-view /> }
        @case ('state') { <app-state-view /> }
        @default { <app-runbook-builder /> }
      }
    </main>
  `,
  styles: [`
    :host { display: flex; flex-direction: column; height: 100vh; font-family: system-ui, sans-serif; }
    header { display: flex; align-items: center; gap: 12px; padding: 8px 14px; background: #1b1b1b; color: #eee; }
    header .dim { opacity: 0.6; font-size: 12px; }
    nav { display: flex; gap: 4px; margin-left: 12px; }
    nav button { padding: 4px 14px; background: transparent; color: #ccc; border: 1px solid #444; border-radius: 4px; cursor: pointer; }
    nav button.on { background: #2e7d32; color: #fff; border-color: #2e7d32; }
    .spacer { flex: 1; }
    .tok { padding: 4px 8px; width: 200px; }
    main { flex: 1 1 auto; overflow: auto; background: #fff; }
  `],
})
export class App {
  view = signal<'host' | 'state' | 'runbooks'>('host');
  token = localStorage.getItem(TOKEN_KEY) || '';
  saveToken(): void { localStorage.setItem(TOKEN_KEY, this.token); }
}
