import { Component, OnInit, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { marked } from 'marked';
import { environment } from '../../../environments/environment';

/** Block G10 — the in-app Help page: renders the project README (served by
 * GET /api/v1/help) as Markdown. The same docs back the AI's search_help tool
 * and its stuck-fallback, so what you read here is what the assistant knows. */
@Component({
  selector: 'app-help',
  standalone: true,
  imports: [],
  template: `
    <div class="bm-page">
      <h1>Help</h1>
      <p class="bm-subtitle">
        The yolo-man documentation. The AI assistant searches these same docs
        (<code>search_help</code>) to answer questions — ask it in the chat dock too.
      </p>
      @if (loading()) {
        <p class="bm-dim">Loading…</p>
      } @else if (html()) {
        <article class="bm-md" [innerHTML]="html()"></article>
      } @else {
        <p class="bm-dim">No help content available.</p>
      }
    </div>
  `,
  styles: [
    `
      .bm-page { padding: 24px; max-width: 900px; margin: 0 auto; }
      .bm-subtitle { opacity: 0.7; margin-top: 4px; }
      .bm-dim { opacity: 0.6; }
      .bm-md { line-height: 1.6; }
      .bm-md :is(h1, h2, h3) { margin-top: 1.4em; }
      .bm-md code { background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); padding: 1px 5px; border-radius: 4px; }
      .bm-md pre { background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 12px; border-radius: 8px; overflow-x: auto; }
      .bm-md pre code { background: none; padding: 0; }
      .bm-md table { border-collapse: collapse; }
      .bm-md th, .bm-md td { border: 1px solid var(--mat-sys-outline-variant); padding: 4px 10px; }
      /* README banners (yolo-man / bossman) are full-res; cap them to a modest
         logo size so the top image doesn't dominate the page. max-width (not
         100%) is the real cap — a wide banner otherwise spans the whole content
         column. Aspect ratio preserved (no explicit width/height). */
      .bm-md img { max-width: 260px; max-height: 120px; width: auto; height: auto; }
      .bm-md a { color: var(--bm-green); }
    `,
  ],
})
export class HelpComponent implements OnInit {
  private http = inject(HttpClient);
  private sanitizer = inject(DomSanitizer);
  html = signal<SafeHtml | null>(null);
  loading = signal(true);

  ngOnInit(): void {
    this.http.get<{ markdown: string }>(`${environment.apiUrl}/help`).subscribe({
      next: (r) => {
        // The README uses GitHub-relative image paths (docs/assets/…) that don't
        // resolve in the app; the UI serves those images from /assets/, so
        // rewrite the prefix before rendering (fixes the missing yolo-man logo).
        const md = (r.markdown || '').replace(/docs\/assets\//g, 'assets/');
        this.html.set(md ? this.sanitizer.bypassSecurityTrustHtml(marked.parse(md) as string) : null);
        this.loading.set(false);
      },
      error: () => this.loading.set(false),
    });
  }
}
