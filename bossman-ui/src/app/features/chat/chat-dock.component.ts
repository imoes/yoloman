import { Component, NgZone, OnInit, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { marked } from 'marked';
import { ChatService } from '../../core/services/chat.service';
import { ChatBackendName, ChatEvent, ChatUiMessage } from '../../core/models/chat.model';

marked.setOptions({ gfm: true, breaks: true });

const BACKEND_LABELS: Record<string, string> = {
  claude_cli: 'Claude CLI',
  codex: 'ChatGPT Codex',
  hermes_web: 'hermes-web',
};

/** Block K — the docked AI chat console (lower part of the window). Streams
 * from the selected backend via ChatService; renders assistant text as plain
 * text while streaming and as Markdown once complete (cached in a WeakMap so
 * change-detection doesn't re-parse and wipe text selection). Collapsible +
 * height-resizable. Widgets/diagrams (K4/K6) hook into the `widget` event. */
@Component({
  selector: 'app-chat-dock',
  standalone: true,
  imports: [MatIconModule, MatButtonModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-dock" [class.bm-dock-collapsed]="!open()" [style.height.px]="open() ? height() : null">
      <div class="bm-dock-resize" (mousedown)="startResize($event)"></div>
      <div class="bm-dock-head">
        <button mat-icon-button (click)="open.set(!open())" [title]="open() ? 'Collapse' : 'Expand'">
          <mat-icon>{{ open() ? 'expand_more' : 'expand_less' }}</mat-icon>
        </button>
        <mat-icon class="bm-dock-icon">smart_toy</mat-icon>
        <span class="bm-dock-title">Assistant</span>
        <select class="bm-dock-backend" [value]="backend()" (change)="backend.set($any($event.target).value)" [disabled]="streaming()">
          @for (b of backends(); track b) { <option [value]="b">{{ label(b) }}</option> }
        </select>
        <span class="bm-dock-spacer"></span>
        <button mat-icon-button (click)="newSession()" [disabled]="streaming()" title="New conversation"><mat-icon>add_comment</mat-icon></button>
      </div>

      @if (open()) {
        <div class="bm-dock-body">
          @if (loadErr()) { <p class="bm-dock-err">{{ loadErr() }}</p> }
          @for (m of messages(); track $index) {
            <div class="bm-msg" [class.bm-msg-user]="m.role === 'user'" [class.bm-msg-ai]="m.role === 'assistant'">
              @if (m.tools?.length) {
                <div class="bm-msg-tools">
                  @for (t of m.tools!; track t.tool) {
                    <span class="bm-tool" [class.bm-tool-done]="t.done">
                      @if (!t.done) { <mat-spinner diameter="12" /> } @else { <mat-icon>check</mat-icon> }
                      {{ t.tool }}
                    </span>
                  }
                </div>
              }
              @if (m.streaming) {
                <pre class="bm-msg-stream">{{ m.text }}</pre>
              } @else if (m.error) {
                <div class="bm-msg-err">{{ m.text }}</div>
              } @else {
                <div class="bm-md" [innerHTML]="rendered(m)"></div>
              }
            </div>
          }
        </div>

        <form class="bm-dock-input" (submit)="send($event)">
          <input
            type="text"
            placeholder="Ask the assistant… (Markdown, plans, widgets)"
            [value]="input()"
            (input)="input.set($any($event.target).value)"
            [disabled]="streaming()"
          />
          @if (streaming()) {
            <button type="button" mat-stroked-button (click)="stop()">Stop</button>
          } @else {
            <button type="submit" mat-flat-button color="primary" [disabled]="!input().trim()">Send</button>
          }
        </form>
      }
    </div>
  `,
  styles: [
    `
      .bm-dock { display: flex; flex-direction: column; flex: none; border-top: 2px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface-container); min-height: 42px; max-height: 80vh; position: relative; }
      .bm-dock-collapsed { height: 42px; }
      .bm-dock-resize { position: absolute; top: -3px; left: 0; right: 0; height: 6px; cursor: ns-resize; }
      .bm-dock-head { display: flex; align-items: center; gap: 8px; padding: 2px 10px; flex: none; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-dock-icon { color: var(--mat-sys-primary); }
      .bm-dock-title { font: var(--mat-sys-title-small); }
      .bm-dock-backend { background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); border: 1px solid var(--mat-sys-outline); border-radius: 4px; padding: 2px 6px; }
      .bm-dock-spacer { flex: 1; }
      .bm-dock-body { flex: 1; overflow-y: auto; padding: 10px 12px; display: flex; flex-direction: column; gap: 10px; }
      .bm-msg { max-width: 90%; padding: 6px 10px; border-radius: 8px; font-size: 13px; }
      .bm-msg-user { align-self: flex-end; background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); }
      .bm-msg-ai { align-self: flex-start; background: var(--mat-sys-surface); border: 1px solid var(--mat-sys-outline-variant); }
      .bm-msg-stream { white-space: pre-wrap; word-break: break-word; margin: 0; font-family: inherit; }
      .bm-msg-err { color: var(--mat-sys-error); }
      .bm-md :first-child { margin-top: 0; } .bm-md :last-child { margin-bottom: 0; }
      .bm-md pre { background: #1e1e1e; color: #d4d4d4; padding: 8px; border-radius: 6px; overflow-x: auto; }
      .bm-md code { font-family: monospace; }
      .bm-md table { border-collapse: collapse; } .bm-md th, .bm-md td { border: 1px solid var(--mat-sys-outline-variant); padding: 2px 6px; }
      .bm-msg-tools { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 4px; }
      .bm-tool { display: inline-flex; align-items: center; gap: 4px; font-size: 11px; color: var(--mat-sys-on-surface-variant); background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); border-radius: 10px; padding: 1px 8px; }
      .bm-tool-done { color: var(--mat-sys-primary); }
      .bm-dock-input { display: flex; gap: 8px; padding: 8px 12px; flex: none; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-dock-input input { flex: 1; padding: 8px 10px; border: 1px solid var(--mat-sys-outline); border-radius: 6px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-dock-err { color: var(--mat-sys-error); font-size: 12px; }
    `,
  ],
})
export class ChatDockComponent implements OnInit {
  private chat = inject(ChatService);
  private sanitizer = inject(DomSanitizer);
  private zone = inject(NgZone);

  open = signal(false);
  height = signal(320);
  backends = signal<ChatBackendName[]>(['claude_cli', 'codex', 'hermes_web']);
  backend = signal<ChatBackendName>('claude_cli');
  messages = signal<ChatUiMessage[]>([]);
  input = signal('');
  streaming = signal(false);
  loadErr = signal<string | null>(null);

  private sessionId: string | null = null;
  private abort: AbortController | null = null;
  private mdCache = new WeakMap<ChatUiMessage, SafeHtml>();

  label = (b: string) => BACKEND_LABELS[b] ?? b;

  ngOnInit(): void {
    this.chat.backends().subscribe({
      next: (res) => {
        this.backends.set(res.backends);
        this.backend.set(res.default);
      },
      error: () => {},
    });
  }

  rendered(m: ChatUiMessage): SafeHtml {
    let html = this.mdCache.get(m);
    if (!html) {
      html = this.sanitizer.bypassSecurityTrustHtml(marked.parse(m.text) as string);
      this.mdCache.set(m, html);
    }
    return html;
  }

  newSession(): void {
    this.sessionId = null;
    this.messages.set([]);
  }

  private async ensureSession(): Promise<string> {
    if (this.sessionId) return this.sessionId;
    const s = await new Promise<string>((resolve, reject) =>
      this.chat.createSession(this.backend()).subscribe({ next: (r) => resolve(r.id), error: reject }),
    );
    this.sessionId = s;
    return s;
  }

  send(ev: Event): void {
    ev.preventDefault();
    const text = this.input().trim();
    if (!text || this.streaming()) return;
    this.open.set(true);
    this.input.set('');
    this.loadErr.set(null);
    this.messages.update((m) => [...m, { role: 'user', text }]);
    const assistant: ChatUiMessage = { role: 'assistant', text: '', streaming: true, tools: [] };
    this.messages.update((m) => [...m, assistant]);
    this.streaming.set(true);
    this.abort = new AbortController();

    void this.run(text, assistant);
  }

  private async run(text: string, assistant: ChatUiMessage): Promise<void> {
    try {
      const sid = await this.ensureSession();
      await this.chat.streamMessage(
        sid,
        text,
        (e) => this.zone.run(() => this.onEvent(e, assistant)),
        { backend: this.backend(), signal: this.abort!.signal },
      );
    } catch (err: any) {
      this.zone.run(() => {
        assistant.error = true;
        assistant.text = err?.message ?? 'chat failed';
      });
    } finally {
      this.zone.run(() => {
        assistant.streaming = false;
        this.mdCache.delete(assistant);
        this.messages.update((m) => [...m]); // trigger re-render (markdown now)
        this.streaming.set(false);
        this.abort = null;
      });
    }
  }

  private onEvent(e: ChatEvent, assistant: ChatUiMessage): void {
    switch (e.type) {
      case 'delta':
        if (e.text) assistant.text += e.text;
        break;
      case 'tool_start':
        assistant.tools = [...(assistant.tools ?? []), { tool: String(e.tool ?? 'tool'), done: false }];
        break;
      case 'tool_done': {
        const t = (assistant.tools ?? []).find((x) => x.tool === e.tool && !x.done);
        if (t) t.done = true;
        break;
      }
      case 'error':
        assistant.error = true;
        assistant.text = e.text ?? 'error';
        break;
      // 'widget' handled in K4.
    }
    this.messages.update((m) => [...m]); // push signal update for streaming text
  }

  stop(): void {
    this.abort?.abort();
  }

  startResize(ev: MouseEvent): void {
    ev.preventDefault();
    const startY = ev.clientY;
    const startH = this.height();
    const move = (e: MouseEvent) => {
      const next = Math.min(Math.round(window.innerHeight * 0.8), Math.max(160, startH + (startY - e.clientY)));
      this.height.set(next);
    };
    const up = () => {
      document.removeEventListener('mousemove', move);
      document.removeEventListener('mouseup', up);
    };
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', up);
  }
}
