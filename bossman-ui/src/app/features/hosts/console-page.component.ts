import { Component, OnInit, inject, signal } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import { Agent } from '../../core/models/agent.model';
import { AgentService } from '../../core/services/agent.service';
import { HostConsoleComponent } from './host-console.component';

/** Stand-alone, chrome-less console page (route /console/:id) opened in its own
 * browser window via the host's "Open console" button. Each window is an
 * independent PTY session, so several can be open at once. */
@Component({
  selector: 'app-console-page',
  standalone: true,
  imports: [HostConsoleComponent],
  template: `
    <div class="bm-console-page">
      @if (agent(); as a) {
        <div class="bm-cbar">
          <span class="bm-ctitle">{{ a.name }}</span>
          <span class="bm-cdim">console</span>
        </div>
        <div class="bm-cbody"><app-host-console [agent]="a" /></div>
      } @else if (error()) {
        <p class="bm-cerr">{{ error() }}</p>
      } @else {
        <p class="bm-cdim" style="padding:16px;">Loading…</p>
      }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100vh; }
    .bm-console-page { display: flex; flex-direction: column; height: 100vh; background: #000; }
    .bm-cbar { display: flex; align-items: baseline; gap: 10px; padding: 8px 14px; background: #111; color: #ddd; border-bottom: 1px solid #333; }
    .bm-ctitle { font-family: monospace; font-weight: 600; }
    .bm-cdim { opacity: 0.55; font-size: 12.5px; }
    .bm-cbody { flex: 1; min-height: 0; padding: 8px 10px; overflow: hidden; }
    .bm-cbody app-host-console { display: block; height: 100%; }
    .bm-cerr { color: #f48771; padding: 16px; }
  `],
})
export class ConsolePageComponent implements OnInit {
  private route = inject(ActivatedRoute);
  private agentService = inject(AgentService);
  agent = signal<Agent | null>(null);
  error = signal<string>('');

  ngOnInit(): void {
    const id = this.route.snapshot.paramMap.get('id');
    if (!id) { this.error.set('no host id'); return; }
    this.agentService.get(id).subscribe({
      next: (a) => { this.agent.set(a); document.title = `${a.name} — console`; },
      error: () => this.error.set('host not found'),
    });
  }
}
