import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { SequentialWorkflowDesignerModule } from 'sequential-workflow-designer-angular';
import {
  Definition,
  Step,
  StepsConfiguration,
  ToolboxConfiguration,
  DefinitionChangedEvent,
} from 'sequential-workflow-designer';
import { AgentApi, Runbook, RunbookStep, RunResult } from './agent-api.service';

let uidCounter = 0;
function uid(): string {
  uidCounter += 1;
  return 'step-' + uidCounter + '-' + (uidCounter * 2654435761 % 1000000);
}

function task(type: string, name: string, properties: Record<string, unknown>): Step {
  return { id: uid(), componentType: 'task', type, name, properties } as Step;
}

/**
 * Visual runbook builder (Sequential Workflow Designer): drag ordered steps —
 * module call / set_fact / debug / assert — edit each step's properties on the
 * right, then submit the sequence to the agent's POST /api/v1/runbook/run. The
 * on-canvas definition converts 1:1 to the runbook JSON the agent executes.
 */
@Component({
  selector: 'app-runbook-builder',
  standalone: true,
  imports: [CommonModule, FormsModule, SequentialWorkflowDesignerModule],
  template: `
    <div class="rb">
      <div class="rb-bar">
        <input class="rb-name" [(ngModel)]="name" placeholder="runbook name" />
        <button (click)="run(true)" [disabled]="running()">▷ Dry-run</button>
        <button class="rb-apply" (click)="run(false)" [disabled]="running()">▶ Run</button>
        <span class="rb-status" *ngIf="result() as r" [class.ok]="r.status === 'succeeded'" [class.fail]="r.status === 'failed'">
          {{ r.status }}
        </span>
        <span class="rb-err" *ngIf="error()">{{ error() }}</span>
      </div>

      <sqd-designer
        theme="light"
        [definition]="definition"
        [toolboxConfiguration]="toolbox"
        [stepsConfiguration]="stepsConfig"
        [controlBar]="true"
        [rootEditor]="rootEditor"
        [stepEditor]="stepEditor"
        (onDefinitionChanged)="onChanged($event)"
        (onSelectedStepIdChanged)="selectedId.set($event)"
      ></sqd-designer>

      <ng-template #rootEditor>
        <div class="rb-editor">
          <h3>Runbook</h3>
          <p class="dim">Drag steps from the left onto the canvas, then click a step to edit its
            module, params, when/register. Dry-run or Run submits the sequence to the agent.</p>
        </div>
      </ng-template>

      <ng-template #stepEditor let-editor>
        <div class="rb-editor">
          <h3>{{ editor.step.type }}</h3>
          <label>Name <input [(ngModel)]="editor.step.name" (ngModelChange)="editor.context.notifyNameChanged()" /></label>

          <ng-container [ngSwitch]="editor.step.type">
            <label *ngSwitchCase="'module'">Module
              <input [(ngModel)]="editor.step.properties['module']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder="apt, service, file…" />
            </label>
            <label *ngSwitchCase="'module'">Params (JSON)
              <textarea rows="6" [(ngModel)]="editor.step.properties['params']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder='{"name":"nginx","state":"present"}'></textarea>
            </label>
            <label *ngSwitchCase="'set_fact'">Facts (JSON)
              <textarea rows="5" [(ngModel)]="editor.step.properties['facts']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder='{"web_pkg":"nginx"}'></textarea>
            </label>
            <label *ngSwitchCase="'debug'">Message
              <input [(ngModel)]="editor.step.properties['msg']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder="installing {{ '{{' }} web_pkg {{ '}}' }}" />
            </label>
            <ng-container *ngSwitchCase="'assert'">
              <label>Conditions (one per line)
                <textarea rows="4" [(ngModel)]="editor.step.properties['that']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder="ansible_os_family == 'Debian'"></textarea>
              </label>
              <label>Fail message
                <input [(ngModel)]="editor.step.properties['fail_msg']" (ngModelChange)="editor.context.notifyPropertiesChanged()" />
              </label>
            </ng-container>
          </ng-container>

          <label>when: <input [(ngModel)]="editor.step.properties['when']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder="optional condition" /></label>
          <label *ngIf="editor.step.type !== 'assert'">register: <input [(ngModel)]="editor.step.properties['register']" (ngModelChange)="editor.context.notifyPropertiesChanged()" placeholder="optional var name" /></label>
        </div>
      </ng-template>

      <div class="rb-results" *ngIf="result() as r">
        <table>
          <tr *ngFor="let s of r.steps" [class.ok]="!s.error && !s.skipped" [class.skip]="s.skipped" [class.fail]="s.error">
            <td>{{ s.name }}</td><td>{{ s.module }}</td><td>{{ s.error || s.msg || (s.skipped ? 'skipped' : '') }}</td>
          </tr>
        </table>
      </div>
    </div>
  `,
  styles: [`
    :host { display: block; height: 100%; }
    .rb { display: flex; flex-direction: column; height: 100%; }
    .rb-bar { display: flex; gap: 8px; align-items: center; padding: 8px; }
    .rb-name { flex: 0 0 220px; padding: 4px 8px; }
    .rb-bar button { padding: 4px 12px; cursor: pointer; }
    .rb-apply { font-weight: 700; }
    .rb-status.ok { color: #1e9600; font-weight: 700; }
    .rb-status.fail, .rb-err { color: #f44034; font-weight: 700; }
    sqd-designer { flex: 1 1 auto; display: block; min-height: 420px; }
    .rb-editor { padding: 10px; display: flex; flex-direction: column; gap: 8px; width: 260px; }
    .rb-editor label { display: flex; flex-direction: column; font-size: 12px; gap: 3px; }
    .rb-editor input, .rb-editor textarea { padding: 4px 6px; font-family: monospace; }
    .rb-results { padding: 8px; max-height: 200px; overflow: auto; }
    .rb-results table { width: 100%; border-collapse: collapse; font-size: 13px; }
    .rb-results td { padding: 2px 8px; border-bottom: 1px solid #eee; }
    .rb-results tr.ok td:first-child { border-left: 3px solid #1e9600; }
    .rb-results tr.fail td:first-child { border-left: 3px solid #f44034; }
    .rb-results tr.skip { opacity: 0.6; }
  `],
})
export class RunbookBuilderComponent {
  private api = inject(AgentApi);
  name = 'my-runbook';
  running = signal(false);
  result = signal<RunResult | null>(null);
  error = signal<string | null>(null);
  selectedId = signal<string | null>(null);

  definition: Definition = { sequence: [], properties: {} };

  toolbox: ToolboxConfiguration = {
    groups: [
      {
        name: 'Steps',
        steps: [
          task('module', 'module', { module: '', params: '{}' }),
          task('set_fact', 'set_fact', { facts: '{}' }),
          task('debug', 'debug', { msg: '' }),
          task('assert', 'assert', { that: '', fail_msg: '' }),
        ],
      },
    ],
  };

  stepsConfig: StepsConfiguration = {
    iconUrlProvider: () => null,
  };

  onChanged(e: DefinitionChangedEvent): void {
    this.definition = e.definition;
  }

  private toRunbook(): Runbook {
    const steps: RunbookStep[] = this.definition.sequence.map((s: Step) => {
      const p = s.properties as Record<string, string>;
      const step: RunbookStep = { name: s.name };
      if (p['when']) step.when = p['when'];
      if (p['register']) step.register = p['register'];
      switch (s.type) {
        case 'module':
          step.module = p['module'];
          step.params = JSON.parse(p['params'] || '{}');
          break;
        case 'set_fact':
          step.module = 'set_fact';
          step.params = JSON.parse(p['facts'] || '{}');
          break;
        case 'debug':
          step.module = 'debug';
          step.params = { msg: p['msg'] || '' };
          break;
        case 'assert':
          step.assert = {
            that: (p['that'] || '').split('\n').map((x) => x.trim()).filter(Boolean),
            fail_msg: p['fail_msg'] || undefined,
          };
          break;
      }
      return step;
    });
    return { name: this.name, steps };
  }

  run(dryRun: boolean): void {
    this.error.set(null);
    let rb: Runbook;
    try {
      rb = this.toRunbook();
    } catch (e) {
      this.error.set('invalid step JSON: ' + (e as Error).message);
      return;
    }
    if (rb.steps.length === 0) {
      this.error.set('add at least one step');
      return;
    }
    this.running.set(true);
    this.api.runRunbook(rb, dryRun).subscribe({
      next: (r) => { this.result.set(r); this.running.set(false); },
      error: (e) => { this.error.set(e?.error?.error || e.message || 'run failed'); this.running.set(false); },
    });
  }
}
