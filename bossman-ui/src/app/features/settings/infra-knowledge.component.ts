import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { HttpClient } from '@angular/common/http';
import { DatePipe, DecimalPipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

interface KnowledgeStats { model: string; total: number; by_kind: Record<string, number>; last_indexed: string | null; }
interface Source { doc_id: string; kind: string; title: string; host_id: string | null; similarity: number; }
interface AskResult { question: string; answer: string; sources: Source[]; retriever: string; grounding: { cards: number; context_chars: number }; }

/**
 * Infrastructure knowledge (AI) — the RAG surface. Shows what the assistant has
 * indexed about the live fleet, lets you rebuild it, and lets you ask a
 * natural-language question answered STRICTLY from that live state (with the
 * source hosts cited and which retriever ran — semantic vector, or the lexical
 * fallback that needs no embed model).
 */
@Component({
  selector: 'app-infra-knowledge',
  standalone: true,
  imports: [FormsModule, DatePipe, DecimalPipe, MatCardModule, MatButtonModule, MatIconModule],
  template: `
    <mat-card class="bm-ik-card">
      <mat-card-header>
        <mat-card-title>Infrastructure knowledge (AI)</mat-card-title>
        <mat-card-subtitle>Ask about the live fleet — grounded answers, cited hosts</mat-card-subtitle>
      </mat-card-header>
      <mat-card-content>
        @if (stats(); as s) {
          <div class="bm-ik-stats">
            <span class="bm-ik-chip">{{ s.total }} facts indexed</span>
            @for (k of kinds(s); track k[0]) { <span class="bm-ik-chip bm-ik-kind">{{ k[1] }} {{ k[0] }}</span> }
            <span class="bm-ik-dim">
              @if (s.last_indexed) { updated {{ s.last_indexed | date: 'short' }} } @else { not indexed yet }
              @if (s.model) { · embed model {{ s.model }} } @else { · lexical only (no embed model) }
            </span>
            <button mat-stroked-button (click)="reindex()" [disabled]="busy()">
              <mat-icon>autorenew</mat-icon> {{ reindexing() ? 'Reindexing…' : 'Reindex now' }}
            </button>
          </div>
        }

        <div class="bm-ik-ask">
          <textarea class="bm-ik-q" rows="2" [(ngModel)]="question"
                    placeholder="Ask the infrastructure — e.g. 'Which hosts are CRIT and what do they depend on?'"
                    (keydown.enter)="onEnter($event)"></textarea>
          <button mat-flat-button color="primary" (click)="ask()" [disabled]="busy() || !question.trim()">
            <mat-icon>psychology</mat-icon> {{ asking() ? 'Thinking…' : 'Ask' }}
          </button>
        </div>

        @if (result(); as r) {
          <div class="bm-ik-answer">
            <div class="bm-ik-answer-text">{{ r.answer }}</div>
            <div class="bm-ik-src-head">
              <mat-icon>{{ r.retriever === 'semantic' ? 'hub' : 'search' }}</mat-icon>
              Grounded in {{ r.grounding.cards }} fact(s) · {{ r.retriever }} retrieval
            </div>
            @if (r.sources.length) {
              <ul class="bm-ik-srcs">
                @for (src of r.sources; track src.doc_id) {
                  <li><span class="bm-ik-kind">{{ src.kind }}</span> {{ src.title }}
                    <span class="bm-ik-dim">· {{ (src.similarity * 100) | number: '1.0-0' }}%</span></li>
                }
              </ul>
            }
          </div>
        }
        @if (error()) { <p class="bm-ik-err">{{ error() }}</p> }
      </mat-card-content>
    </mat-card>
  `,
  styles: [`
    .bm-ik-card { margin-top: 16px; }
    .bm-ik-stats { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 12px; }
    .bm-ik-chip { font-size: 12px; padding: 2px 9px; border-radius: 20px; border: 1px solid var(--mat-sys-outline-variant); }
    .bm-ik-kind { text-transform: capitalize; opacity: 0.85; }
    .bm-ik-dim { opacity: 0.6; font-size: 12px; }
    .bm-ik-err { color: var(--mat-sys-error, #c62828); font-size: 13px; }
    .bm-ik-ask { display: flex; gap: 10px; align-items: flex-start; }
    .bm-ik-q { flex: 1; padding: 8px 10px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; background: var(--mat-sys-surface); color: inherit; font: inherit; resize: vertical; box-sizing: border-box; }
    .bm-ik-answer { margin-top: 14px; padding: 12px 14px; border-radius: 10px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-ik-answer-text { white-space: pre-wrap; line-height: 1.5; font-size: 14px; }
    .bm-ik-src-head { display: flex; align-items: center; gap: 6px; margin-top: 12px; font-size: 12px; opacity: 0.7; }
    .bm-ik-src-head mat-icon { font-size: 16px; height: 16px; width: 16px; }
    .bm-ik-srcs { margin: 6px 0 0; padding-left: 4px; list-style: none; font-size: 12.5px; }
    .bm-ik-srcs li { padding: 2px 0; }
  `],
})
export class InfraKnowledgeComponent implements OnInit {
  private http = inject(HttpClient);
  private base = environment.apiUrl;
  stats = signal<KnowledgeStats | null>(null);
  result = signal<AskResult | null>(null);
  error = signal('');
  question = '';
  asking = signal(false);
  reindexing = signal(false);
  busy = signal(false);

  kinds(s: KnowledgeStats): [string, number][] { return Object.entries(s.by_kind); }

  ngOnInit(): void { this.loadStats(); }
  private loadStats(): void {
    this.http.get<KnowledgeStats>(`${this.base}/knowledge/stats`).subscribe((s) => this.stats.set(s));
  }
  onEnter(ev: Event): void {
    const e = ev as KeyboardEvent;
    if (!e.shiftKey) { e.preventDefault(); this.ask(); }
  }
  ask(): void {
    if (!this.question.trim() || this.busy()) return;
    this.busy.set(true); this.asking.set(true); this.error.set(''); this.result.set(null);
    this.http.post<AskResult>(`${this.base}/ask`, { question: this.question }).subscribe({
      next: (r) => { this.result.set(r); this.busy.set(false); this.asking.set(false); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'ask failed'); this.busy.set(false); this.asking.set(false); },
    });
  }
  reindex(): void {
    this.busy.set(true); this.reindexing.set(true); this.error.set('');
    this.http.post(`${this.base}/knowledge/reindex`, {}).subscribe({
      next: () => { this.busy.set(false); this.reindexing.set(false); this.loadStats(); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'reindex failed'); this.busy.set(false); this.reindexing.set(false); },
    });
  }
}
