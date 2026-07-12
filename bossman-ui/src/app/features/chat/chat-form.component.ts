import { Component, OnInit, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { PlanService } from '../../core/services/plan.service';
import { RunService } from '../../core/services/run.service';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { ChatForm, ChatFormField } from '../../core/models/chat.model';

type Stage = 'form' | 'previewing' | 'previewed' | 'applying' | 'applied';
interface HostRun {
  host: string;
  status: string;
  changed: number;
  failed: number;
  error?: string;
}

/**
 * Renders a ```bm-form``` the assistant designed (task → generative input mask):
 * the AI dynamically chose the fields (text/number/checkbox/listbox/multiselect
 * /host/hosts) for an actionable task, mapped to a plan. The operator fills it,
 * previews (dry run), then applies — across ONE or MANY hosts. Writes go only
 * through the authenticated /plans/{name}/run endpoint (per selected host),
 * never the read-only chat.
 */
@Component({
  selector: 'app-chat-form',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-cform">
      <div class="bm-cform-head"><mat-icon>assignment</mat-icon> {{ form().intent }}
        @if (form().plan) { <span class="bm-cform-plan">plan: {{ form().plan }}</span> }
      </div>

      @if (stage() === 'form') {
        <div class="bm-cform-fields">
          @for (f of form().fields; track f.name) {
            <div class="bm-cform-field">
              @switch (f.type) {
                @case ('bool') {
                  <label class="bm-cform-chk"><input type="checkbox" [(ngModel)]="values[f.name]" /> {{ f.label || f.name }}</label>
                }
                @case ('textarea') {
                  <label>{{ label(f) }}</label>
                  <textarea rows="3" [(ngModel)]="values[f.name]" [placeholder]="f.help || ''"></textarea>
                }
                @case ('select') {
                  <label>{{ label(f) }}</label>
                  <select [(ngModel)]="values[f.name]">
                    <option value="">—</option>
                    @for (o of f.options ?? []; track o) { <option [value]="o">{{ o }}</option> }
                  </select>
                }
                @case ('multiselect') {
                  <label>{{ label(f) }}</label>
                  <div class="bm-cform-checks">
                    @for (o of f.options ?? []; track o) {
                      <label class="bm-cform-chk"><input type="checkbox" [checked]="inArray(f.name, o)" (change)="toggleArray(f.name, o)" /> {{ o }}</label>
                    }
                  </div>
                }
                @case ('host') {
                  <label>{{ label(f) }}</label>
                  <select [(ngModel)]="values[f.name]">
                    <option value="">— pick a host —</option>
                    @for (a of agents(); track a.id) { <option [value]="a.name">{{ a.name }}</option> }
                  </select>
                }
                @case ('hosts') {
                  <label>{{ label(f) }} <span class="bm-cform-help">(multiple)</span></label>
                  <div class="bm-cform-checks bm-cform-hosts">
                    @for (a of agents(); track a.id) {
                      <label class="bm-cform-chk"><input type="checkbox" [checked]="inArray(f.name, a.name)" (change)="toggleArray(f.name, a.name)" /> {{ a.name }}</label>
                    }
                    @if (!agents().length) { <span class="bm-cform-help">no hosts enrolled</span> }
                  </div>
                }
                @default {
                  <label>{{ label(f) }}</label>
                  <input [type]="f.type === 'number' ? 'number' : 'text'" [(ngModel)]="values[f.name]" [placeholder]="f.help || ''" />
                }
              }
              @if (f.help && f.type !== 'bool') { <span class="bm-cform-help">{{ f.help }}</span> }
            </div>
          }
        </div>
        @if (form().generated_plan) {
          <p class="bm-cform-note">AI-authored plan <strong>{{ form().generated_plan!.name }}</strong> — saved to the library, then run.</p>
        } @else if (!form().plan) {
          <p class="bm-cform-note">No matching plan — this collects the inputs; nothing runs.</p>
        }
        <div class="bm-cform-actions">
          <span class="bm-cform-targets">{{ targetHosts().length }} host(s)</span>
          <button mat-stroked-button [disabled]="!canRun()" (click)="preview()"><mat-icon>science</mat-icon> Preview (dry run)</button>
          <button mat-raised-button color="primary" [disabled]="!canRun()" (click)="apply()"><mat-icon>play_arrow</mat-icon> Ausführen</button>
        </div>
      }

      @if (stage() === 'previewing' || stage() === 'applying') {
        <div class="bm-cform-busy"><mat-spinner diameter="20" /> {{ stage() === 'previewing' ? 'Previewing…' : 'Applying…' }} ({{ done() }}/{{ targetHosts().length }})</div>
      }

      @if ((stage() === 'previewed' || stage() === 'applied') && runs().length) {
        <div class="bm-cform-result">
          <div class="bm-cform-status">{{ stage() === 'applied' ? 'Applied' : 'Preview (dry run)' }} — {{ okCount() }}/{{ runs().length }} ok</div>
          <ul class="bm-cform-runs">
            @for (r of runs(); track r.host) {
              <li>
                <span [class.bm-ok]="r.status === 'succeeded'" [class.bm-bad]="r.status !== 'succeeded'">{{ r.status === 'succeeded' ? '✓' : '✗' }}</span>
                <strong>{{ r.host }}</strong> — {{ r.status }}
                @if (r.error) { <span class="bm-bad">{{ r.error }}</span> } @else { <span class="bm-cform-help">{{ r.changed }} changed, {{ r.failed }} failed</span> }
              </li>
            }
          </ul>
          @if (stage() === 'previewed') {
            <div class="bm-cform-actions">
              <button mat-button (click)="stage.set('form')">Back</button>
              <button mat-raised-button color="primary" (click)="apply()"><mat-icon>play_arrow</mat-icon> Apply for real ({{ targetHosts().length }})</button>
            </div>
          }
        </div>
      }

      @if (error()) { <p class="bm-cform-err">{{ error() }}</p> }
    </div>
  `,
  styles: [
    `
      .bm-cform { border: 1px solid var(--mat-sys-outline-variant); border-left: 3px solid var(--mat-sys-primary); border-radius: 8px; padding: 12px; margin-top: 8px; background: var(--mat-sys-surface); }
      .bm-cform-head { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 10px; }
      .bm-cform-plan { font-size: 11px; font-weight: 500; opacity: 0.7; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-primary) 14%, transparent); }
      .bm-cform-fields { display: flex; flex-direction: column; gap: 10px; margin: 10px 0; }
      .bm-cform-field { display: flex; flex-direction: column; gap: 3px; }
      .bm-cform-field label { font-size: 12.5px; opacity: 0.85; }
      .bm-cform-field input[type='text'], .bm-cform-field input[type='number'], .bm-cform-field select, .bm-cform-field textarea {
        padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; font-size: 13px; font-family: inherit;
      }
      .bm-cform-checks { display: flex; flex-direction: column; gap: 3px; }
      .bm-cform-hosts { max-height: 160px; overflow: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 6px 8px; }
      .bm-cform-chk { display: flex; align-items: center; gap: 6px; font-size: 13px; }
      .bm-cform-help { font-size: 11px; opacity: 0.55; }
      .bm-cform-note { font-size: 12px; opacity: 0.7; font-style: italic; }
      .bm-cform-actions { display: flex; gap: 8px; align-items: center; justify-content: flex-end; margin-top: 6px; }
      .bm-cform-targets { font-size: 11.5px; opacity: 0.6; margin-right: auto; }
      .bm-cform-busy { display: flex; align-items: center; gap: 8px; padding: 10px; opacity: 0.8; }
      .bm-cform-status { font-weight: 600; margin-bottom: 6px; }
      .bm-cform-runs { list-style: none; padding: 0; margin: 0; font-size: 12.5px; }
      .bm-cform-runs li { padding: 4px 0; border-top: 1px solid var(--mat-sys-outline-variant); display: flex; gap: 6px; align-items: baseline; }
      .bm-ok { color: #2e7d32; }
      .bm-bad { color: #c62828; }
      .bm-cform-err { color: #c62828; font-size: 12.5px; }
    `,
  ],
})
export class ChatFormComponent implements OnInit {
  form = input.required<ChatForm>();

  private planService = inject(PlanService);
  private runService = inject(RunService);
  private agentService = inject(AgentService);

  agents = signal<Agent[]>([]);
  stage = signal<Stage>('form');
  runs = signal<HostRun[]>([]);
  done = signal(0);
  error = signal<string | null>(null);
  values: Record<string, unknown> = {};

  ngOnInit(): void {
    for (const f of this.form().fields) {
      if (f.type === 'multiselect' || f.type === 'hosts') this.values[f.name] = Array.isArray(f.default) ? f.default : [];
      else if (f.default !== undefined && f.default !== null) this.values[f.name] = f.default;
      else if (f.type === 'bool') this.values[f.name] = false;
    }
    if (this.needsAgents()) this.agentService.list().subscribe((a) => this.agents.set(a));
  }

  label(f: ChatFormField): string {
    return (f.label || f.name) + (f.required ? ' *' : '');
  }

  private needsAgents(): boolean {
    return this.form().needs_host !== false || this.form().fields.some((f) => f.type === 'host' || f.type === 'hosts');
  }

  inArray(name: string, val: string): boolean {
    return Array.isArray(this.values[name]) && (this.values[name] as string[]).includes(val);
  }
  toggleArray(name: string, val: string): void {
    const arr = Array.isArray(this.values[name]) ? [...(this.values[name] as string[])] : [];
    const i = arr.indexOf(val);
    i >= 0 ? arr.splice(i, 1) : arr.push(val);
    this.values[name] = arr;
  }

  /** The hosts to run against: a `hosts` field (many), a `host` field (one), or
   * the single implicit picker when the form just set needs_host. */
  targetHosts(): string[] {
    const fields = this.form().fields;
    const multi = fields.find((f) => f.type === 'hosts');
    if (multi) return (this.values[multi.name] as string[]) ?? [];
    const single = fields.find((f) => f.type === 'host');
    if (single) return this.values[single.name] ? [this.values[single.name] as string] : [];
    return [];
  }

  canRun(): boolean {
    if (!this.form().plan && !this.form().generated_plan) return false;
    return this.targetHosts().length > 0;
  }

  preview(): void {
    this.execute(true, 'previewing', 'previewed');
  }
  apply(): void {
    this.execute(false, 'applying', 'applied');
  }

  /** Collect params (all non-host fields) and run the plan on each target host. */
  private params(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const f of this.form().fields) {
      if (f.type === 'host' || f.type === 'hosts') continue;
      let v = this.values[f.name];
      if (v === undefined || v === '') continue;
      if (f.type === 'number') v = Number(v);
      if (f.type === 'bool') v = v === true || v === 'true';
      out[f.name] = v;
    }
    return out;
  }

  private execute(dryRun: boolean, busy: Stage, doneStage: Stage): void {
    const hosts = this.targetHosts();
    if (!this.canRun() || !hosts.length) return;
    this.error.set(null);
    this.runs.set([]);
    this.done.set(0);
    this.stage.set(busy);
    const gp = this.form().generated_plan;
    // AI-authored plan: save it to the library once, then run it from the store.
    if (gp) {
      // Preferred: plan_body is a nested object we serialize; fall back to a
      // provided source_text (+ format) for older/explicit specs.
      const fmt = gp.plan_body !== undefined && gp.plan_body !== null ? 'json' : (gp.source_format ?? 'json');
      const text = gp.plan_body !== undefined && gp.plan_body !== null ? JSON.stringify(gp.plan_body) : (gp.source_text ?? '');
      this.planService.save(gp.prefix, gp.name, fmt, text).subscribe({
        next: () => this.runAll(hosts, dryRun, doneStage),
        error: (err) => { this.error.set(err.error?.detail ?? 'could not save the authored plan'); this.stage.set('form'); },
      });
    } else {
      this.runAll(hosts, dryRun, doneStage);
    }
  }

  private runAll(hosts: string[], dryRun: boolean, doneStage: Stage): void {
    const params = this.params();
    const gp = this.form().generated_plan;
    const plan = this.form().plan;
    let finished = 0;
    hosts.forEach((host) => {
      const req = { agent: host, params, dry_run: dryRun };
      const run$ = gp
        ? this.planService.runStored(gp.prefix, gp.name, req)
        : this.planService.run(plan!, req);
      run$.subscribe({
        next: (res) => {
          this.runService.get(res.plan_run_id).subscribe({
            next: (d) => this.record(host, {
              host, status: d.status,
              changed: d.steps.filter((s) => s.changed).length,
              failed: d.steps.filter((s) => s.error).length,
            }, ++finished, hosts.length, doneStage),
            error: () => this.record(host, { host, status: 'error', changed: 0, failed: 0, error: 'run detail failed' }, ++finished, hosts.length, doneStage),
          });
        },
        error: (err) => this.record(host, { host, status: 'error', changed: 0, failed: 0, error: err.error?.detail ?? 'run failed' }, ++finished, hosts.length, doneStage),
      });
    });
  }

  private record(_host: string, r: HostRun, finished: number, total: number, doneStage: Stage): void {
    this.runs.update((rs) => [...rs, r]);
    this.done.set(finished);
    if (finished >= total) this.stage.set(doneStage);
  }

  okCount(): number {
    return this.runs().filter((r) => r.status === 'succeeded').length;
  }
}
