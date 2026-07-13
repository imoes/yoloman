import { Component, OnInit, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { PlanService } from '../../core/services/plan.service';
import { RunService } from '../../core/services/run.service';
import { AgentService } from '../../core/services/agent.service';
import { Agent } from '../../core/models/agent.model';
import { PlanRunDetail } from '../../core/models/run.model';
import { ChatTask, ChatTaskField } from '../../core/models/chat.model';

type Stage = 'config' | 'running' | 'previewed' | 'applied';
interface HostRun { host: string; status: string; lines: string[]; error?: string; }

/**
 * Renders a ```bm-task``` block — the full, AI-designed task dashboard (a
 * multi-section config grid + status cards + a generated shell-script preview
 * + run actions), modeled on the DeployMate-style mockup. All from JSON, so a
 * rendered view is fully cacheable (persisted in the chat message). Generate
 * Script = dry-run preview; Start = real apply — both via /plans/{…}/run,
 * so the chat itself stays read-only. Informational fields that aren't plan
 * parameters are shown but not sent (filtered to the plan's declared params).
 */
@Component({
  selector: 'app-chat-task',
  standalone: true,
  imports: [FormsModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-task">
      <div class="bm-task-head">
        <mat-icon>dashboard_customize</mat-icon>
        <span class="bm-task-title">{{ task().title }}</span>
        @if (task().plan) { <span class="bm-task-plan">plan: {{ task().plan }}</span> }
        @else if (task().generated_plan) { <span class="bm-task-plan">AI plan: {{ task().generated_plan!.name }}</span> }
      </div>
      @if (task().intro) { <p class="bm-task-intro">{{ task().intro }}</p> }

      <!-- Configuration grid -->
      <div class="bm-task-label">Configuration</div>
      <div class="bm-task-grid">
        @for (s of task().sections; track s.title) {
          <div class="bm-task-col">
            <div class="bm-task-col-title">{{ s.title }}</div>
            @for (f of s.fields; track f.name) {
              <div class="bm-task-field">
                @switch (f.type) {
                  @case ('toggle') {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <label class="bm-switch"><input type="checkbox" [(ngModel)]="values[f.name]" /><span></span></label>
                  }
                  @case ('checkbox') {
                    <label class="bm-task-chk"><input type="checkbox" [(ngModel)]="values[f.name]" /> {{ f.label || f.name }}</label>
                  }
                  @case ('select') {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <input [attr.list]="'dl-' + f.name" [(ngModel)]="values[f.name]" [placeholder]="f.placeholder || 'select or type'" />
                    <datalist [id]="'dl-' + f.name">
                      @for (o of f.options ?? []; track o) { <option [value]="o"></option> }
                    </datalist>
                  }
                  @case ('textarea') {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <textarea rows="2" [(ngModel)]="values[f.name]" [placeholder]="f.placeholder || ''" [disabled]="!!f.readonly"></textarea>
                  }
                  @case ('host') {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <select [(ngModel)]="values[f.name]">
                      <option value="">— pick a host —</option>
                      @for (a of agents(); track a.id) { <option [value]="a.name">{{ a.name }}</option> }
                    </select>
                  }
                  @case ('hosts') {
                    <label class="bm-task-flabel">{{ f.label || f.name }} <span class="bm-task-help">(multiple)</span></label>
                    <div class="bm-task-hosts">
                      @for (a of agents(); track a.id) {
                        <label class="bm-task-chk"><input type="checkbox" [checked]="inArray(f.name, a.name)" (change)="toggleArray(f.name, a.name)" /> {{ a.name }}</label>
                      }
                    </div>
                  }
                  @case ('upload') {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <input type="text" [(ngModel)]="values[f.name]" [placeholder]="f.placeholder || 'paste or path'" />
                  }
                  @default {
                    <label class="bm-task-flabel">{{ f.label || f.name }}</label>
                    <input [type]="f.type === 'number' ? 'number' : 'text'" [(ngModel)]="values[f.name]" [placeholder]="f.placeholder || ''" [disabled]="!!f.readonly" />
                  }
                }
                @if (f.help) { <span class="bm-task-help">{{ f.help }}</span> }
              </div>
            }
          </div>
        }
      </div>

      <!-- Summary & status cards -->
      @if (task().summary?.length) {
        <div class="bm-task-label">Summary &amp; Status</div>
        <div class="bm-task-cards">
          @for (c of task().summary!; track c.label) {
            <div class="bm-task-card bm-st-{{ c.state || 'ok' }}">
              <mat-icon>{{ c.icon || 'info' }}</mat-icon>
              <div><div class="bm-task-card-lbl">{{ c.label }}</div><div class="bm-task-card-val">{{ c.value }}</div></div>
            </div>
          }
        </div>
      }

      <!-- Terminal: the REAL tool output of the modules (per host), not a
           hand-written bash script. Before a run it shows a hint. -->
      <div class="bm-task-label">Terminal — module tool output
        @if (terminalText()) { <button class="bm-task-copy" (click)="copyTerminal()" [title]="copied() ? 'Copied' : 'Copy'"><mat-icon>{{ copied() ? 'check' : 'content_copy' }}</mat-icon></button> }
      </div>
      <pre class="bm-task-output">{{ terminalText() || placeholder() }}</pre>

      @if (stage() === 'running') {
        <div class="bm-task-busy"><mat-spinner diameter="18" /> Running… ({{ done() }}/{{ targetHosts().length }})</div>
      }
      @if ((stage() === 'previewed' || stage() === 'applied') && runs().length) {
        <div class="bm-task-runsummary">{{ stage() === 'applied' ? 'Applied' : 'Dry-run' }}: {{ okCount() }}/{{ runs().length }} host(s) ok</div>
      }
      @if (error()) { <p class="bm-bad">{{ error() }}</p> }

      <!-- Actions -->
      <div class="bm-task-actions">
        <span class="bm-task-targets">{{ targetHosts().length }} host(s)</span>
        <span class="bm-spacer"></span>
        <button mat-button (click)="reset()">Cancel</button>
        <button mat-stroked-button [disabled]="!canRun()" (click)="generate()"><mat-icon>science</mat-icon> Generate Script</button>
        <button mat-raised-button color="primary" [disabled]="!canRun()" (click)="start()"><mat-icon>rocket_launch</mat-icon> Start Installation</button>
      </div>
    </div>
  `,
  styles: [
    `
      .bm-task { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 14px; margin-top: 8px; background: var(--mat-sys-surface); }
      .bm-task-head { display: flex; align-items: center; gap: 8px; font-size: 16px; font-weight: 700; }
      .bm-task-plan { font-size: 11px; font-weight: 500; opacity: 0.75; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
      .bm-task-intro { opacity: 0.8; margin: 6px 0 4px; font-size: 13px; }
      .bm-task-label { display: flex; align-items: center; gap: 8px; font-size: 11px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; opacity: 0.6; margin: 16px 0 8px; }
      .bm-task-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; }
      .bm-task-col { border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 10px 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 2%, transparent); }
      .bm-task-col-title { font-weight: 600; font-size: 12.5px; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-task-field { display: flex; flex-direction: column; gap: 3px; margin-bottom: 10px; }
      .bm-task-flabel { font-size: 12px; opacity: 0.8; }
      .bm-task-field input[type='text'], .bm-task-field input[type='number'], .bm-task-field select, .bm-task-field textarea {
        padding: 7px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; font-size: 13px; font-family: inherit;
      }
      .bm-task-chk { display: flex; align-items: center; gap: 6px; font-size: 13px; }
      .bm-task-help { font-size: 11px; opacity: 0.55; }
      .bm-task-hosts { display: flex; flex-direction: column; gap: 3px; max-height: 130px; overflow: auto; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; padding: 6px 8px; }
      .bm-switch { position: relative; display: inline-block; width: 40px; height: 22px; }
      .bm-switch input { opacity: 0; width: 0; height: 0; }
      .bm-switch span { position: absolute; inset: 0; background: var(--mat-sys-outline-variant); border-radius: 999px; transition: 0.2s; }
      .bm-switch span::before { content: ''; position: absolute; height: 16px; width: 16px; left: 3px; top: 3px; background: #fff; border-radius: 50%; transition: 0.2s; }
      .bm-switch input:checked + span { background: var(--mat-sys-primary); }
      .bm-switch input:checked + span::before { transform: translateX(18px); }
      .bm-task-cards { display: flex; gap: 10px; flex-wrap: wrap; }
      .bm-task-card { display: flex; align-items: center; gap: 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; padding: 8px 14px; min-width: 130px; }
      .bm-task-card mat-icon { opacity: 0.8; }
      .bm-task-card-lbl { font-size: 10.5px; text-transform: uppercase; letter-spacing: 0.05em; opacity: 0.6; }
      .bm-task-card-val { font-weight: 700; font-size: 14px; }
      .bm-st-ok { border-left: 3px solid var(--bm-green, #2e7d32); }
      .bm-st-warn { border-left: 3px solid var(--bm-gold, #f9a825); }
      .bm-st-crit { border-left: 3px solid var(--bm-red, #c62828); }
      .bm-st-pending { border-left: 3px solid var(--mat-sys-outline); }
      .bm-task-copy { margin-left: auto; background: none; border: none; color: inherit; cursor: pointer; opacity: 0.7; }
      .bm-task-copy:hover { opacity: 1; }
      .bm-task-output { background: #1e1e1e; color: #d4d4d4; border-radius: 8px; padding: 12px; overflow: auto; font-size: 12px; max-height: 320px; white-space: pre-wrap; word-break: break-word; }
      .bm-task-runsummary { font-size: 12.5px; font-weight: 600; margin-top: 8px; }
      .bm-task-busy { display: flex; align-items: center; gap: 8px; opacity: 0.8; margin-top: 10px; }
      .bm-task-runs { list-style: none; padding: 0; margin: 4px 0; font-size: 12.5px; }
      .bm-task-runs li { padding: 3px 0; display: flex; gap: 6px; align-items: baseline; }
      .bm-task-actions { display: flex; align-items: center; gap: 8px; margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-task-targets { font-size: 11.5px; opacity: 0.6; }
      .bm-spacer { flex: 1; }
      .bm-ok { color: #2e7d32; } .bm-bad { color: #c62828; }
    `,
  ],
})
export class ChatTaskComponent implements OnInit {
  task = input.required<ChatTask>();

  private planService = inject(PlanService);
  private runService = inject(RunService);
  private agentService = inject(AgentService);

  agents = signal<Agent[]>([]);
  stage = signal<Stage>('config');
  runs = signal<HostRun[]>([]);
  done = signal(0);
  error = signal<string | null>(null);
  copied = signal(false);
  values: Record<string, unknown> = {};
  private allowedParams: Set<string> | null = null; // plan's declared params

  ngOnInit(): void {
    for (const f of this.fields()) {
      if (f.type === 'hosts') this.values[f.name] = Array.isArray(f.default) ? f.default : [];
      else if (f.default !== undefined && f.default !== null) this.values[f.name] = f.default;
      else if (f.type === 'toggle' || f.type === 'checkbox') this.values[f.name] = false;
    }
    if (this.fields().some((f) => f.type === 'host' || f.type === 'hosts')) {
      this.agentService.list().subscribe((a) => this.agents.set(a));
    }
    // Learn the plan's declared params so informational fields aren't sent.
    const gp = this.task().generated_plan;
    if (gp?.plan_body && typeof gp.plan_body === 'object') {
      this.allowedParams = new Set(Object.keys((gp.plan_body as any).params ?? {}));
    } else if (this.task().plan) {
      this.planService.get(this.task().plan!).subscribe({
        next: (d) => (this.allowedParams = new Set(Object.keys(d.params ?? {}))),
        error: () => (this.allowedParams = null),
      });
    }
  }

  fields(): ChatTaskField[] {
    return this.task().sections.flatMap((s) => s.fields);
  }

  inArray(name: string, v: string): boolean {
    return Array.isArray(this.values[name]) && (this.values[name] as string[]).includes(v);
  }
  toggleArray(name: string, v: string): void {
    const arr = Array.isArray(this.values[name]) ? [...(this.values[name] as string[])] : [];
    const i = arr.indexOf(v);
    i >= 0 ? arr.splice(i, 1) : arr.push(v);
    this.values[name] = arr;
  }

  targetHosts(): string[] {
    const multi = this.fields().find((f) => f.type === 'hosts');
    if (multi) return (this.values[multi.name] as string[]) ?? [];
    const single = this.fields().find((f) => f.type === 'host');
    if (single) return this.values[single.name] ? [this.values[single.name] as string] : [];
    return [];
  }

  canRun(): boolean {
    if (!this.task().plan && !this.task().generated_plan) return false;
    return this.targetHosts().length > 0;
  }

  /** The terminal transcript: each host's real per-step module output. When
   * rolling to several hosts the output can differ, so it's grouped per host. */
  terminalText(): string {
    const rs = this.runs();
    if (!rs.length) return '';
    if (rs.length === 1) return rs[0].lines.join('\n');
    return rs.map((r) => `──── ${r.host} (${r.status}) ────\n${r.lines.join('\n')}`).join('\n\n');
  }

  placeholder(): string {
    const n = this.targetHosts().length;
    return n
      ? `# Ready. "Generate Script" = dry-run preview, "Start Installation" = apply.\n# The real module tool output for ${n} host(s) appears here.`
      : '# Select a target host, then run to see the module tool output here.';
  }

  copyTerminal(): void {
    navigator.clipboard?.writeText(this.terminalText()).then(() => {
      this.copied.set(true);
      setTimeout(() => this.copied.set(false), 1500);
    });
  }

  reset(): void {
    this.stage.set('config');
    this.runs.set([]);
    this.error.set(null);
  }

  generate(): void { this.execute(true, 'previewed'); }
  start(): void { this.execute(false, 'applied'); }

  /** Params = only field values whose name is a declared plan param (informational
   * fields like hostname/ports are shown but not sent → no "unknown parameter"). */
  private params(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    for (const f of this.fields()) {
      if (f.type === 'host' || f.type === 'hosts') continue;
      if (this.allowedParams && !this.allowedParams.has(f.name)) continue;
      let v = this.values[f.name];
      if (v === undefined || v === '') continue;
      if (f.type === 'number') v = Number(v);
      if (f.type === 'toggle' || f.type === 'checkbox') v = v === true || v === 'true';
      out[f.name] = v;
    }
    return out;
  }

  private execute(dryRun: boolean, doneStage: Stage): void {
    const hosts = this.targetHosts();
    if (!this.canRun() || !hosts.length) return;
    this.error.set(null);
    this.runs.set([]);
    this.done.set(0);
    this.stage.set('running');
    const gp = this.task().generated_plan;
    if (gp) {
      const fmt = gp.plan_body != null ? 'json' : (gp.source_format ?? 'json');
      const text = gp.plan_body != null ? JSON.stringify(gp.plan_body) : (gp.source_text ?? '');
      this.planService.save(gp.prefix, gp.name, fmt, text).subscribe({
        next: () => this.runAll(hosts, dryRun, doneStage),
        error: (err) => { this.error.set(err.error?.detail ?? 'could not save the authored plan'); this.stage.set('config'); },
      });
    } else {
      this.runAll(hosts, dryRun, doneStage);
    }
  }

  private runAll(hosts: string[], dryRun: boolean, doneStage: Stage): void {
    const params = this.params();
    const gp = this.task().generated_plan;
    const plan = this.task().plan;
    let finished = 0;
    hosts.forEach((host) => {
      const req = { agent: host, params, dry_run: dryRun };
      const run$ = gp ? this.planService.runStored(gp.prefix, gp.name, req) : this.planService.run(plan!, req);
      run$.subscribe({
        next: (res) => this.runService.get(res.plan_run_id).subscribe({
          next: (d) => this.record({ host, status: d.status, lines: this.stepLines(d.steps) }, ++finished, hosts.length, doneStage),
          error: () => this.record({ host, status: 'error', lines: ['run detail could not be loaded'], error: 'run detail failed' }, ++finished, hosts.length, doneStage),
        }),
        error: (err) => this.record({ host, status: 'error', lines: [err.error?.detail ?? 'run failed'], error: err.error?.detail ?? 'run failed' }, ++finished, hosts.length, doneStage),
      });
    });
  }

  /** Render each step's REAL module result as a terminal line (tag + step +
   * module + msg/data or error) — the module tool output the operator wanted. */
  private stepLines(steps: PlanRunDetail['steps']): string[] {
    return steps.map((s) => {
      const rb = (s.response_body ?? {}) as Record<string, unknown>;
      const tag = s.error ? 'ERR' : s.changed ? 'chg' : 'ok ';
      let out = s.error || (rb['msg'] as string) || '';
      if (!out) {
        const data = rb['data'];
        out = data && Object.keys(data as object).length ? JSON.stringify(data).slice(0, 300)
          : rb['changed'] !== undefined ? `changed=${rb['changed']}` : 'ok';
      }
      return `[${tag}] ${s.step_name} (${s.module ?? '-'}): ${out}`;
    });
  }

  private record(r: HostRun, finished: number, total: number, doneStage: Stage): void {
    this.runs.update((rs) => [...rs, r]);
    this.done.set(finished);
    if (finished >= total) this.stage.set(doneStage);
  }

  okCount(): number {
    return this.runs().filter((r) => r.status === 'succeeded').length;
  }
}
