import { Component, Input, inject } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { marked } from 'marked';

// PlantUML server via the ~h hex encoding — pure client-side, no deflate dep.
// Kept in sync with chat-dock.component's renderer.
const PLANTUML_SERVER = 'https://www.plantuml.com/plantuml/svg/~h';

marked.setOptions({ gfm: true, breaks: true });

/**
 * Renders an LLM answer as Markdown, lifting ```plantuml``` fenced blocks out
 * into rendered <img> diagrams below the prose. The AI decides itself whether
 * to emit a diagram (see the plan-briefing / chat doctrine), so this component
 * just faithfully renders whatever it produced. Extracted from chat-dock so the
 * run dialog's AI briefing shows the same md + UML the chat does.
 */
@Component({
  selector: 'app-markdown-view',
  standalone: true,
  template: `
    <div class="bm-md" [innerHTML]="html"></div>
    @for (url of diagrams; track url) {
      <img class="bm-md-diagram" [src]="url" alt="diagram" />
    }
  `,
  styles: [
    `
      .bm-md {
        line-height: 1.5;
      }
      .bm-md :first-child {
        margin-top: 0;
      }
      .bm-md pre {
        overflow-x: auto;
        padding: 8px;
        border-radius: 4px;
        background: var(--mat-sys-surface-container-high, rgba(0, 0, 0, 0.06));
      }
      .bm-md-diagram {
        max-width: 100%;
        margin-top: 12px;
        background: #fff;
        border-radius: 4px;
      }
    `,
  ],
})
export class MarkdownViewComponent {
  private sanitizer = inject(DomSanitizer);

  html: SafeHtml = '';
  diagrams: string[] = [];

  @Input({ required: true }) set text(value: string) {
    const found: string[] = [];
    const cleaned = (value ?? '').replace(/```plantuml\s*([\s\S]*?)```/g, (_full, body) => {
      const url = this.plantumlUrl(String(body).trim());
      if (url) found.push(url);
      return '';
    });
    this.diagrams = found;
    this.html = this.sanitizer.bypassSecurityTrustHtml(marked.parse(cleaned.trim()) as string);
  }

  private plantumlUrl(source: string): string | null {
    if (!source) return null;
    const bytes = new TextEncoder().encode(source);
    let hex = '';
    for (const b of bytes) hex += b.toString(16).padStart(2, '0');
    return PLANTUML_SERVER + hex;
  }
}
