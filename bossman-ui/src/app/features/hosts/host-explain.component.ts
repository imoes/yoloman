import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../core/services/agent.service';

/**
 * "Explain / Ask this server" (killer-feature increment a) — self-documenting
 * infrastructure. Generates always-current documentation of the host, or
 * answers a natural-language question, grounded STRICTLY in its live
 * server-document (config + desired + generations + topology). The answer is
 * regenerated from live state each time, so it never goes stale like a wiki.
 */
@Component({
  selector: 'app-host-explain',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-ex">
      <p class="bm-dim">
        The assistant answers from this host's <strong>live</strong> state (config, desired state, change
        history, dependencies) — grounded, not guessed, and always current.
      </p>
      <div class="bm-ex-ask">
        <input class="bm-ex-in" #q placeholder="Ask about this server — e.g. is TLS enabled? what changed recently? what does it depend on?"
               [disabled]="busy()" (keydown.enter)="ask(q.value)" />
        <button mat-raised-button color="primary" (click)="ask(q.value)" [disabled]="busy()">Ask</button>
        <button mat-stroked-button (click)="ask('')" [disabled]="busy()" title="Generate documentation of this server">
          <mat-icon>description</mat-icon> Document
        </button>
      </div>
      @if (busy()) { <p class="bm-dim">Reading the live server-document…</p> }
      @if (err()) { <p class="bm-err">{{ err() }}</p> }
      @if (answer()) {
        <div class="bm-ex-answer">
          @if (asked()) { <div class="bm-ex-q">{{ asked() }}</div> }
          <pre class="bm-ex-text">{{ answer() }}</pre>
          @if (grounding()) {
            <div class="bm-ex-ground">
              grounded on {{ grounding()!.sections?.join(', ') }} · {{ grounding()!.context_chars }} chars
              @if (hasErrors()) { · <span class="bm-warn">partial: {{ errorKeys() }}</span> }
            </div>
          }
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-ex { max-width: 900px; }
    .bm-dim { opacity: 0.65; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-ex-ask { display: flex; gap: 8px; margin: 12px 0; }
    .bm-ex-in { flex: 1; box-sizing: border-box; padding: 9px 12px; border-radius: 8px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-ex-answer { border: 1px solid var(--mat-sys-outline-variant); border-radius: 12px; padding: 14px 16px; margin-top: 6px; }
    .bm-ex-q { font-weight: 600; margin-bottom: 8px; }
    .bm-ex-text { white-space: pre-wrap; word-break: break-word; font: inherit; font-size: 13.5px; line-height: 1.5; margin: 0; }
    .bm-ex-ground { margin-top: 10px; font-size: 11.5px; opacity: 0.55; }
    .bm-warn { color: var(--bm-gold, #b8860b); }
  `],
})
export class HostExplainComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  busy = signal(false);
  err = signal('');
  answer = signal('');
  asked = signal('');
  grounding = signal<{ context_chars: number; sections: string[]; errors: Record<string, string> } | null>(null);

  loadOnce(): void { /* the LLM call is on-demand (a click), not on tab open. */ }

  ask(question: string): void {
    const q = (question || '').trim();
    this.busy.set(true); this.err.set(''); this.answer.set(''); this.grounding.set(null);
    this.asked.set(q);
    this.agentService.explainHost(this.agentId(), q || undefined).subscribe({
      next: (r) => { this.busy.set(false); this.answer.set(r.answer || '(no answer)'); this.grounding.set(r.grounding); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Explain failed (model busy or unreachable?).'); },
    });
  }

  hasErrors(): boolean { const g = this.grounding(); return !!g && !!g.errors && Object.keys(g.errors).length > 0; }
  errorKeys(): string { const g = this.grounding(); return g ? Object.keys(g.errors).join(', ') : ''; }
}
