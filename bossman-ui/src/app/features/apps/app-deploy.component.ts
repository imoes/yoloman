import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService, DockerContainer } from '../../core/services/agent.service';
import { AppSummary } from '../../core/services/apps.service';
import { ResourceNodeComponent } from '../../shared/resource-node/resource-node.component';

/**
 * App-Store deploy panel — the unified App lifecycle made click-and-play (see
 * docs/app-model.md). One App, one values set, three target tiers:
 *   - docker: image + ports + env → docker/deploy (the sandboxed single-host tier)
 *   - k8s:    routes to the host's Kubernetes tab (chart + values form)
 *   - native: routes to the host's Management/Roles (config template + state)
 * The target picker + host picker are shared; docker is deployed inline here,
 * the other two reuse their existing surfaces rather than duplicating them.
 */
@Component({
  selector: 'app-app-deploy',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, ResourceNodeComponent],
  template: `
    <div class="bm-dep">
      <div class="bm-dep-head">
        <div>
          <div class="bm-dep-title">Deploy {{ app().label }}</div>
          <div class="bm-dep-sub">{{ app().description || app().id }}</div>
        </div>
      </div>

      <!-- Target-tier picker: only the tiers this App actually supports -->
      <div class="bm-dep-row">
        <span class="bm-dep-lbl">Target</span>
        <div class="bm-dep-tiers">
          @for (t of tiers(); track t) {
            <button class="bm-dep-tier" [class.on]="tier() === t" (click)="tier.set(t)">{{ t }}</button>
          }
        </div>
      </div>

      <!-- Host picker -->
      <div class="bm-dep-row">
        <span class="bm-dep-lbl">Host</span>
        <select class="bm-dep-in" [ngModel]="agentId()" (ngModelChange)="onHost($event)">
          <option value="">— choose a host —</option>
          @for (a of agents(); track a.id) { <option [value]="a.id">{{ a.name }}</option> }
        </select>
      </div>

      @switch (tier()) {
        @case ('docker') {
          <div class="bm-dep-row"><span class="bm-dep-lbl">Name</span>
            <input class="bm-dep-in" [(ngModel)]="dName" placeholder="container name" /></div>
          <div class="bm-dep-row"><span class="bm-dep-lbl">Image</span>
            <input class="bm-dep-in" [(ngModel)]="dImage" placeholder="e.g. nginx:latest" /></div>
          <div class="bm-dep-row"><span class="bm-dep-lbl">Ports</span>
            <input class="bm-dep-in" [(ngModel)]="dPorts" placeholder="host:container, e.g. 8099:80, 8443:443" /></div>
          <div class="bm-dep-row bm-dep-top"><span class="bm-dep-lbl">Env</span>
            <textarea class="bm-dep-in" rows="3" [(ngModel)]="dEnv" placeholder="KEY=VALUE, one per line"></textarea></div>
          <div class="bm-dep-actions">
            <button mat-stroked-button (click)="deployDocker(true)" [disabled]="!canDocker() || busy()">Preview command</button>
            <button mat-raised-button color="primary" (click)="deployDocker(false)" [disabled]="!canDocker() || busy()">
              <mat-icon>rocket_launch</mat-icon> Deploy
            </button>
          </div>
          @if (cmd()) { <pre class="bm-dep-cmd">{{ cmd() }}</pre> }
          @if (msg()) { <p [class.bm-err]="!ok()" [class.bm-good]="ok()">{{ msg() }}</p> }

          @if (agentId()) {
            <div class="bm-dep-containers">
              <div class="bm-dep-chead">Containers on host <button mat-button (click)="loadContainers()" [disabled]="busyC()"><mat-icon>refresh</mat-icon></button></div>
              @if (cErr()) { <p class="bm-warn">{{ cErr() }}</p> }
              @for (c of containers(); track c.name) {
                <div class="bm-dep-crow">
                  <span class="bm-dep-cname">{{ c.name }}</span>
                  <span class="bm-dim">{{ c.image }} · {{ c.status }}</span>
                  <button mat-button (click)="toggleManage(c.name)" [disabled]="busy()">
                    {{ manageName() === c.name ? 'Hide' : 'Manage' }}
                  </button>
                  <button mat-button color="warn" (click)="remove(c)" [disabled]="busy()">Remove</button>
                </div>
                @if (manageName() === c.name) {
                  <div class="bm-dep-manage"><app-resource-node [agentId]="agentId()" [name]="c.name" /></div>
                }
              }
              @if (!containers().length && !cErr() && !busyC()) { <p class="bm-dim">No containers.</p> }
            </div>
          }
        }
        @case ('k8s') {
          <p class="bm-dim">Kubernetes deploys use the chart + typed values form. Suggested chart:
            <code>{{ app().targets.k8s?.chart || '—' }}</code>.</p>
          <button mat-raised-button color="primary" (click)="openK8s()" [disabled]="!agentId()">
            <mat-icon>open_in_new</mat-icon> Open Kubernetes deploy
          </button>
        }
        @case ('native') {
          <p class="bm-dim">Native deploys apply this App's config template as a role on the host
            (values → template → state/apply, with generations &amp; rollback).</p>
          <button mat-raised-button color="primary" (click)="openNative()" [disabled]="!agentId()">
            <mat-icon>open_in_new</mat-icon> Open host management
          </button>
        }
      }
    </div>
  `,
  styles: [`
    .bm-dep { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 16px 18px; }
    .bm-dep-head { margin-bottom: 12px; }
    .bm-dep-title { font-weight: 600; font-size: 15px; }
    .bm-dep-sub { font-size: 12px; opacity: 0.7; }
    .bm-dep-row { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
    .bm-dep-top { align-items: flex-start; }
    .bm-dep-lbl { width: 60px; font-size: 12px; opacity: 0.7; text-align: right; flex: none; }
    .bm-dep-in { flex: 1; box-sizing: border-box; padding: 7px 10px; border-radius: 8px; font: inherit; font-size: 13px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    textarea.bm-dep-in { resize: vertical; font-family: ui-monospace, monospace; font-size: 12px; }
    .bm-dep-tiers { display: flex; gap: 6px; }
    .bm-dep-tier { text-transform: capitalize; padding: 5px 14px; border-radius: 999px; cursor: pointer; font: inherit; font-size: 12.5px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; }
    .bm-dep-tier.on { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
    .bm-dep-actions { display: flex; gap: 10px; margin: 12px 0 6px 72px; }
    .bm-dep-cmd { background: var(--mat-sys-surface-variant); padding: 10px; border-radius: 8px; font-size: 11.5px; overflow-x: auto; margin: 6px 0; }
    .bm-dim { opacity: 0.6; font-size: 12.5px; }
    .bm-warn { color: var(--bm-gold, #b8860b); font-size: 12.5px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-good { color: #1e9600; }
    .bm-dep-containers { margin-top: 14px; border-top: 1px solid var(--mat-sys-outline-variant); padding-top: 10px; }
    .bm-dep-chead { font-size: 12px; opacity: 0.75; display: flex; align-items: center; gap: 6px; margin-bottom: 4px; }
    .bm-dep-crow { display: flex; align-items: center; gap: 12px; font-size: 12.5px; padding: 3px 0; }
    .bm-dep-cname { font-weight: 600; min-width: 140px; }
    .bm-dep-manage { margin: 6px 0 12px; }
  `],
})
export class AppDeployComponent {
  private agentService = inject(AgentService);
  private router = inject(Router);
  app = input.required<AppSummary>();

  agents = signal<{ id: string; name: string }[]>([]);
  tiers = computed(() => Object.keys(this.app().targets || {}).filter((k) => (this.app().targets as Record<string, unknown>)[k]));
  tier = signal<string>('native');
  agentId = signal('');

  dName = signal('');
  dImage = signal('');
  dPorts = signal('');
  dEnv = signal('');

  busy = signal(false);
  ok = signal(false);
  msg = signal('');
  cmd = signal('');

  containers = signal<DockerContainer[]>([]);
  busyC = signal(false);
  cErr = signal('');
  manageName = signal('');

  toggleManage(name: string): void { this.manageName.set(this.manageName() === name ? '' : name); }

  canDocker = computed(() => !!this.agentId() && !!this.dName().trim() && !!this.dImage().trim());

  constructor() {
    this.agentService.list().subscribe({ next: (a) => this.agents.set(a.map((x) => ({ id: x.id, name: x.name }))), error: () => {} });
    // When the selected app changes, seed the tier + docker defaults from it.
    effect(() => {
      const a = this.app();
      const ts = Object.keys(a.targets || {}).filter((k) => (a.targets as Record<string, unknown>)[k]);
      this.tier.set(ts.includes('docker') ? 'docker' : (ts[0] || 'native'));
      this.dName.set(a.id);
      this.dImage.set(a.targets?.docker?.image ? `${a.targets.docker.image}:latest` : '');
      this.cmd.set(''); this.msg.set('');
    });
  }

  onHost(id: string): void { this.agentId.set(id); if (id && this.tier() === 'docker') this.loadContainers(); }

  private parsePorts(): { host: string; container: string }[] {
    return this.dPorts().split(',').map((p) => p.trim()).filter(Boolean).map((p) => {
      const [h, c] = p.split(':').map((x) => x.trim());
      return { host: h, container: c || h };
    });
  }
  private parseEnv(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const line of this.dEnv().split('\n').map((l) => l.trim()).filter(Boolean)) {
      const i = line.indexOf('='); if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    return out;
  }

  deployDocker(dryRun: boolean): void {
    this.busy.set(true); this.msg.set(''); this.cmd.set('');
    this.agentService.dockerDeploy(this.agentId(), {
      name: this.dName(), image: this.dImage(), ports: this.parsePorts(), env: this.parseEnv(), dry_run: dryRun,
    }).subscribe({
      next: (r) => {
        this.busy.set(false); this.ok.set(!!r.ok);
        if (dryRun) { this.cmd.set(r.command || '(no command)'); this.msg.set(''); }
        else { this.msg.set(r.ok ? `Deployed "${r.container}".` : `Failed: ${r.stderr || 'unknown error'}`); if (r.ok) this.loadContainers(); }
      },
      error: (e) => { this.busy.set(false); this.ok.set(false); this.msg.set(e?.error?.detail || 'deploy failed'); },
    });
  }

  loadContainers(): void {
    if (!this.agentId()) return;
    this.busyC.set(true); this.cErr.set('');
    this.agentService.dockerContainers(this.agentId()).subscribe({
      next: (r) => { this.busyC.set(false); this.containers.set(r.containers || []); if (r.error) this.cErr.set(r.error); },
      error: (e) => { this.busyC.set(false); this.cErr.set(e?.error?.detail || 'docker ps failed'); },
    });
  }
  remove(c: DockerContainer): void {
    this.busy.set(true);
    this.agentService.dockerRemove(this.agentId(), c.name).subscribe({
      next: (r) => { this.busy.set(false); this.ok.set(!!r.ok); this.msg.set(r.ok ? `Removed "${c.name}".` : `Failed: ${r.stderr || 'unknown error'}`); this.loadContainers(); },
      error: () => { this.busy.set(false); },
    });
  }

  openK8s(): void { this.router.navigate(['/hosts', this.agentId()], { queryParams: { tab: 'Kubernetes' } }); }
  openNative(): void { this.router.navigate(['/hosts', this.agentId()], { queryParams: { tab: 'Management' } }); }
}
