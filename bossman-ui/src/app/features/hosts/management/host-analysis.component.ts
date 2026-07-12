import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';

interface Finding { title: string; component: string; severity: string; evidence: string; recommendation: string; }
interface Report {
  host: string;
  signals: { journal_errors: number; file_errors: Record<string, number>; failed_services: string[]; metrics: number };
  summary: string;
  findings: Finding[];
}

/** AI error-source analysis: on demand, the backend gathers the host's
 * journald errors + /var/log error lines + failed services + latest eBPF/
 * service metrics and asks the LLM to name the likely error sources. Not
 * loaded on tab-open (it's an LLM call) — the user runs it explicitly. */
@Component({
  selector: 'app-host-analysis',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-an">
      <div class="bm-an-bar">
        <div>
          <h3><mat-icon>neurology</mat-icon> AI error analysis</h3>
          <p class="bm-an-hint">Correlates journald + /var/log logs with the eBPF/service metrics to pinpoint likely error sources.</p>
        </div>
        <span class="bm-spacer"></span>
        <button mat-raised-button color="primary" (click)="run()" [disabled]="busy()">
          @if (busy()) { <mat-spinner diameter="18" /> Analyzing… } @else { <mat-icon>play_arrow</mat-icon> Run analysis }
        </button>
      </div>

      @if (err()) { <p class="bm-err">{{ err() }}</p> }

      @if (report(); as r) {
        <div class="bm-signals">
          scanned: {{ r.signals.journal_errors }} journald errors ·
          {{ fileErrCount(r) }} /var/log error lines ·
          {{ r.signals.metrics }} metrics
          @if (r.signals.failed_services.length) { · <span class="bm-fail">failed: {{ r.signals.failed_services.join(', ') }}</span> }
        </div>

        @if (r.summary) { <p class="bm-summary">{{ r.summary }}</p> }

        @if (r.findings.length) {
          @for (f of r.findings; track f.title) {
            <section class="bm-finding bm-sev-{{ f.severity }}">
              <header>
                <span class="bm-sev-badge bm-sev-{{ f.severity }}">{{ f.severity }}</span>
                <strong>{{ f.title }}</strong>
                <span class="bm-comp">{{ f.component }}</span>
              </header>
              <div class="bm-ev"><span class="bm-lbl">Evidence</span><pre>{{ f.evidence }}</pre></div>
              <div class="bm-rec"><span class="bm-lbl">Fix</span><span>{{ f.recommendation }}</span></div>
            </section>
          }
        } @else {
          <p class="bm-ok"><mat-icon>check_circle</mat-icon> No error sources identified — the host looks healthy.</p>
        }
      } @else if (!busy()) {
        <p class="bm-empty">Run the analysis to have the AI correlate this host's logs + metrics.</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-an { padding: 4px 0; display: flex; flex-direction: column; gap: 12px; }
      .bm-an-bar { display: flex; align-items: flex-start; gap: 12px; }
      .bm-an-bar h3 { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 15px; }
      .bm-an-hint { margin: 2px 0 0; font-size: 12.5px; opacity: 0.6; max-width: 60ch; }
      .bm-spacer { flex: 1; }
      .bm-signals { font-size: 12px; opacity: 0.7; }
      .bm-fail { color: #c62828; }
      .bm-summary { font-size: 14px; line-height: 1.5; margin: 0; padding: 10px 12px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-primary) 8%, transparent); }
      .bm-finding { border: 1px solid var(--mat-sys-outline-variant); border-left-width: 4px; border-radius: 8px; padding: 10px 12px; display: flex; flex-direction: column; gap: 6px; }
      .bm-finding header { display: flex; align-items: center; gap: 8px; }
      .bm-finding.bm-sev-critical { border-left-color: #b71c1c; }
      .bm-finding.bm-sev-high { border-left-color: #e65100; }
      .bm-finding.bm-sev-medium { border-left-color: #f9a825; }
      .bm-finding.bm-sev-low, .bm-finding.bm-sev-info { border-left-color: var(--mat-sys-outline); }
      .bm-comp { font-family: monospace; font-size: 12px; opacity: 0.7; }
      .bm-sev-badge { font-size: 11px; padding: 1px 8px; border-radius: 999px; text-transform: uppercase; font-weight: 600; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); }
      .bm-sev-badge.bm-sev-critical { background: color-mix(in srgb, #b71c1c 20%, transparent); color: #b71c1c; }
      .bm-sev-badge.bm-sev-high { background: color-mix(in srgb, #e65100 20%, transparent); color: #e65100; }
      .bm-sev-badge.bm-sev-medium { background: color-mix(in srgb, #f9a825 24%, transparent); color: #a67c00; }
      .bm-ev, .bm-rec { font-size: 12.5px; }
      .bm-lbl { display: block; font-size: 11px; text-transform: uppercase; opacity: 0.5; margin-bottom: 2px; }
      .bm-ev pre { margin: 0; white-space: pre-wrap; font-size: 12px; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); padding: 6px 8px; border-radius: 6px; overflow-x: auto; }
      .bm-ok { display: flex; align-items: center; gap: 8px; color: var(--bm-green, #2e7d32); font-size: 14px; }
      .bm-ok mat-icon { color: var(--bm-green, #2e7d32); }
      .bm-empty { opacity: 0.6; font-size: 13px; }
      .bm-err { color: #c62828; font-size: 13px; }
    `,
  ],
})
export class HostAnalysisComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  report = signal<Report | null>(null);
  busy = signal(false);
  err = signal<string | null>(null);

  fileErrCount(r: Report): number {
    return Object.values(r.signals.file_errors || {}).reduce((a, b) => a + b, 0);
  }

  run(): void {
    this.busy.set(true);
    this.err.set(null);
    this.agentService.analyze(this.agentId()).subscribe({
      next: (r) => { this.report.set(r as Report); this.busy.set(false); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'analysis failed'); },
    });
  }
}
