import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { ActivatedRoute, Router } from '@angular/router';
import { AgentService } from '../../core/services/agent.service';
import { MmcConsoleComponent } from './mmc-console.component';

/**
 * The Management Console as a PAGE, with the host picker MMC calls "connect to another computer".
 *
 * WHY A PAGE AND NOT ONLY A HOST TAB: the per-host tabs answer "what is going on with THIS machine", and
 * that is where a host's own screens belong. RSAT's value is the other direction — one console, any machine,
 * the same tree — so the picker is the point rather than a convenience. The selected host lives in the URL
 * (?host=…), so a console view is a link somebody can send.
 *
 * The host list is deliberately not filtered to Windows. A snap-in that cannot serve a Debian host says so in
 * the tree, with the reason; hiding Linux hosts here would answer a question ("can I manage this one?") by
 * making it unaskable.
 */
@Component({
  selector: 'app-mmc-page',
  standalone: true,
  imports: [FormsModule, MatIconModule, MmcConsoleComponent],
  template: `
    <div class="bm-page">
      <header class="bm-head">
        <div>
          <h1>Management console</h1>
          <p class="bm-dim">
            One tree, any host: services, accounts, disks, roles, policies — the snap-in model RSAT uses for
            Windows, over every managed host. Snap-ins come from the server's catalog and are filtered by what
            the host actually has; what a host cannot serve stays listed with the reason.
          </p>
        </div>
        <label class="bm-picker">
          <mat-icon>dns</mat-icon>
          <select [ngModel]="agentId()" (ngModelChange)="pick($event)">
            <option [ngValue]="null" disabled>choose a host…</option>
            @for (h of hosts(); track h.id) {
              <option [ngValue]="h.id">{{ h.name }}{{ h.os_family ? ' · ' + h.os_family : '' }}</option>
            }
          </select>
        </label>
      </header>

      @if (agentId()) {
        <app-mmc-console [agentId]="agentId()!" />
      } @else {
        <p class="bm-dim bm-choose">Pick a host to open its console tree.</p>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 18px 20px 0; }
    .bm-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 24px; }
    .bm-head h1 { margin: 0 0 4px; }
    .bm-head p { margin: 0; max-width: 760px; font-size: 13px; line-height: 1.5; }
    .bm-dim { opacity: 0.62; }
    .bm-picker { display: flex; align-items: center; gap: 8px; }
    .bm-picker select { padding: 8px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; font: inherit; font-size: 13px; min-width: 260px; }
    .bm-choose { padding: 40px 0; }
  `],
})
export class MmcPageComponent implements OnInit {
  private agents = inject(AgentService);
  private route = inject(ActivatedRoute);
  private router = inject(Router);

  hosts = signal<{ id: string; name: string; os_family?: string | null }[]>([]);
  agentId = signal<string | null>(null);

  ngOnInit(): void {
    const fromUrl = this.route.snapshot.queryParamMap.get('host');
    this.agents.list().subscribe((list) => {
      const rows = (list || [])
        .filter((a) => a.enrollment_state === 'enrolled')
        .map((a) => ({ id: a.id, name: a.name, os_family: (a.facts as any)?.os_family ?? null }))
        .sort((a, b) => a.name.localeCompare(b.name));
      this.hosts.set(rows);
      // A ?host= that no longer exists must not silently open somebody else's console — the picker stays
      // empty and the reader chooses.
      if (fromUrl && rows.some((r) => r.id === fromUrl)) {
        this.agentId.set(fromUrl);
      }
    });
  }

  pick(id: string): void {
    this.agentId.set(id);
    // In the URL, so a console view can be linked and reopened where it was.
    this.router.navigate([], { queryParams: { host: id }, queryParamsHandling: 'merge', replaceUrl: true });
  }
}
