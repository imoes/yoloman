import { Component, NgZone, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { marked } from 'marked';
import { ChatService } from '../../core/services/chat.service';
import { ChatBackendName, ChatEvent, ChatUiMessage, ChatWidget, CodexStartResponse, ClaudeStartResponse, PlanGraphSpec } from '../../core/models/chat.model';
import { DashboardWidgetComponent } from '../../shared/components/dashboard-widget/dashboard-widget.component';
import { DashboardWidget, WidgetType } from '../../core/models/dashboard.model';
import { ChatPlanGraphComponent } from './chat-plan-graph.component';

const WIDGET_TYPES: WidgetType[] = [
  'top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat',
  'bar', 'table', 'status_tiles', 'progress', 'ai_summary', 'war_room', 'log', 'callout',
];
// PlantUML server for the ~h hex-encoding (pure client-side, no deflate dep).
const PLANTUML_SERVER = 'https://www.plantuml.com/plantuml/svg/~h';

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
  imports: [MatIconModule, MatButtonModule, MatProgressSpinnerModule, DashboardWidgetComponent, ChatPlanGraphComponent],
  template: `
    <div class="bm-dock" [class.bm-dock-collapsed]="!open()" [style.height.px]="open() ? height() : null">
      <div class="bm-dock-resize" (mousedown)="startResize($event)"></div>
      <div class="bm-dock-head">
        <button mat-icon-button (click)="open.set(!open())" [title]="open() ? 'Collapse' : 'Expand'">
          <mat-icon>{{ open() ? 'expand_more' : 'expand_less' }}</mat-icon>
        </button>
        <mat-icon class="bm-dock-icon">smart_toy</mat-icon>
        <span class="bm-dock-title">Assistant</span>
        <select class="bm-dock-backend" [value]="backend()" (change)="onBackendChange($any($event.target).value)" [disabled]="streaming()">
          @for (b of backends(); track b) { <option [value]="b">{{ label(b) }}{{ authed()[b] === false ? ' ⚠' : '' }}</option> }
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
              @if (m.widgets?.length) {
                <div class="bm-msg-widgets">
                  @for (w of m.widgets!; track $index) {
                    <div class="bm-msg-widget"><app-dashboard-widget [widget]="w.widget" [data]="w.data" /></div>
                  }
                </div>
              }
              @if (m.planGraphs?.length) {
                <div class="bm-msg-widgets">
                  @for (g of m.planGraphs!; track $index) {
                    <div class="bm-msg-widget">
                      @if (g.title) { <div class="bm-graph-title">{{ g.title }}</div> }
                      <app-chat-plan-graph [data]="g" />
                    </div>
                  }
                </div>
              }
              @if (m.diagrams?.length) {
                <div class="bm-msg-widgets">
                  @for (src of m.diagrams!; track $index) {
                    <img class="bm-msg-diagram" [src]="src" alt="diagram" loading="lazy" />
                  }
                </div>
              }
            </div>
          }
        </div>

        @if (needsAuth()) {
          <div class="bm-dock-login">
            <span class="bm-login-note">{{ label(backend()) }} is not logged in.</span>
            @if (backend() === 'codex') {
              @if (codexLogin(); as c) {
                <span>Open <a [href]="c.verification_uri" target="_blank" rel="noopener">{{ c.verification_uri }}</a> and enter code</span>
                <code class="bm-login-code">{{ c.user_code }}</code>
                <span class="bm-login-wait"><mat-spinner diameter="14" /> waiting…</span>
              } @else {
                <button mat-flat-button color="primary" (click)="startCodexLogin()" [disabled]="loginBusy()">Log in with ChatGPT</button>
              }
            } @else if (backend() === 'claude_cli') {
              @if (claudeLogin(); as c) {
                <span>Open <a [href]="c.authorize_url" target="_blank" rel="noopener">the Claude authorize page</a>, then paste the code:</span>
                <input class="bm-login-input" type="text" [value]="claudeCode()" (input)="claudeCode.set($any($event.target).value)" placeholder="code#state" />
                <button mat-stroked-button (click)="completeClaudeLogin()" [disabled]="loginBusy() || !claudeCode().trim()">Complete</button>
              } @else {
                <button mat-flat-button color="primary" (click)="startClaudeLogin()" [disabled]="loginBusy()">Log in with Claude</button>
              }
            }
            @if (loginErr()) { <span class="bm-svc-err">{{ loginErr() }}</span> }
          </div>
        }

        <form class="bm-dock-input" (submit)="send($event)">
          <input
            type="text"
            placeholder="Ask the assistant… (Markdown, plans, widgets)"
            [value]="input()"
            (input)="input.set($any($event.target).value)"
            [disabled]="streaming() || needsAuth()"
          />
          @if (streaming()) {
            <button type="button" mat-stroked-button (click)="stop()">Stop</button>
          } @else {
            <button type="submit" mat-flat-button color="primary" [disabled]="!input().trim() || needsAuth()">Send</button>
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
      .bm-dock-login { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; padding: 8px 12px; font-size: 12px; border-top: 1px solid var(--mat-sys-outline-variant); background: color-mix(in srgb, var(--mat-sys-tertiary) 10%, transparent); }
      .bm-login-note { color: var(--mat-sys-on-surface-variant); }
      .bm-login-code { font-family: monospace; font-size: 15px; letter-spacing: 2px; background: var(--mat-sys-surface); padding: 2px 8px; border-radius: 4px; }
      .bm-login-wait { display: inline-flex; align-items: center; gap: 6px; color: var(--mat-sys-on-surface-variant); }
      .bm-login-input { padding: 4px 8px; border: 1px solid var(--mat-sys-outline); border-radius: 4px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-msg-widgets { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; }
      .bm-msg-widget { min-height: 160px; background: var(--mat-sys-surface-container-high); border-radius: 8px; padding: 6px; }
      .bm-graph-title { font-size: 12px; color: var(--mat-sys-on-surface-variant); margin: 2px 4px; }
      .bm-msg-diagram { max-width: 100%; background: #fff; border-radius: 6px; padding: 4px; }
    `,
  ],
})
export class ChatDockComponent implements OnInit, OnDestroy {
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

  // Per-user auth status + login state.
  authed = signal<Record<string, boolean>>({});
  codexLogin = signal<CodexStartResponse | null>(null);
  claudeLogin = signal<ClaudeStartResponse | null>(null);
  claudeCode = signal('');
  loginBusy = signal(false);
  loginErr = signal<string | null>(null);

  /** hermes_web needs no per-user login; codex/claude do. */
  needsAuth = computed(() => this.backend() !== 'hermes_web' && this.authed()[this.backend()] === false);

  private sessionId: string | null = null;
  private abort: AbortController | null = null;
  private codexPoll: ReturnType<typeof setInterval> | null = null;
  private mdCache = new WeakMap<ChatUiMessage, SafeHtml>();

  label = (b: string) => BACKEND_LABELS[b] ?? b;

  ngOnInit(): void {
    this.chat.backends().subscribe({ next: (res) => this.backends.set(res.backends), error: () => {} });
    // Per-user default backend + auth status.
    this.chat.getPrefs().subscribe({ next: (p) => this.backend.set(p.default_backend), error: () => {} });
    this.refreshAuth();
  }

  ngOnDestroy(): void {
    this.abort?.abort();
    this.stopCodexPoll();
  }

  private refreshAuth(): void {
    this.chat.oauthStatus().subscribe({ next: (s) => this.authed.set(s.authenticated), error: () => {} });
  }

  onBackendChange(b: ChatBackendName): void {
    if (b === this.backend()) return;
    this.backend.set(b);
    this.newSession(); // sessions are pinned to a backend — switch starts fresh
    this.stopCodexPoll();
    this.codexLogin.set(null);
    this.claudeLogin.set(null);
    this.loginErr.set(null);
    this.chat.setPrefs({ default_backend: b }).subscribe({ error: () => {} });
    this.refreshAuth();
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
        if (!assistant.error) {
          // Extract widget / plan-graph / plantuml blocks into rendered
          // artifacts and strip them from the markdown (once, at stream end).
          const { cleaned, widgets, planGraphs, diagrams } = this.parseArtifacts(assistant.text);
          assistant.text = cleaned;
          if (widgets.length) assistant.widgets = widgets;
          if (planGraphs.length) assistant.planGraphs = planGraphs;
          if (diagrams.length) assistant.diagrams = diagrams;
        }
        this.mdCache.delete(assistant);
        this.messages.update((m) => [...m]); // trigger re-render (markdown now)
        this.streaming.set(false);
        this.abort = null;
      });
    }
  }

  /** Pull ```bm-widget {json}``` and ```plantuml``` fenced blocks out of the
   * assistant text into rendered artifacts (widgets, plan graphs, diagram
   * images) and return the text with those blocks removed. */
  private parseArtifacts(text: string): {
    cleaned: string;
    widgets: ChatWidget[];
    planGraphs: PlanGraphSpec[];
    diagrams: string[];
  } {
    const widgets: ChatWidget[] = [];
    const planGraphs: PlanGraphSpec[] = [];
    const diagrams: string[] = [];

    let cleaned = text.replace(/```bm-widget\s*([\s\S]*?)```/g, (full, body) => {
      try {
        const spec = JSON.parse(String(body).trim());
        if (spec?.widget_type === 'plan_graph' && spec.data) {
          planGraphs.push({ title: spec.title, nodes: spec.data.nodes ?? [], edges: spec.data.edges ?? [] });
          return '';
        }
        const w = this.toChatWidget(spec);
        if (w) {
          widgets.push(w);
          return '';
        }
      } catch {
        /* leave a malformed block visible as-is */
      }
      return full;
    });

    cleaned = cleaned.replace(/```plantuml\s*([\s\S]*?)```/g, (_full, body) => {
      const url = this.plantumlUrl(String(body).trim());
      if (url) diagrams.push(url);
      return '';
    });

    return { cleaned: cleaned.trim(), widgets, planGraphs, diagrams };
  }

  /** PlantUML server URL via the ~h hex encoding (no deflate dependency). */
  private plantumlUrl(source: string): string | null {
    if (!source) return null;
    const bytes = new TextEncoder().encode(source);
    let hex = '';
    for (const b of bytes) hex += b.toString(16).padStart(2, '0');
    return PLANTUML_SERVER + hex;
  }

  private toChatWidget(spec: any): ChatWidget | null {
    if (!spec || !WIDGET_TYPES.includes(spec.widget_type)) return null;
    const widget: DashboardWidget = {
      id: (globalThis.crypto?.randomUUID?.() ?? String(Math.random())),
      widget_type: spec.widget_type,
      title: spec.title ?? '',
      gs_x: 0,
      gs_y: 0,
      gs_w: spec.gs_w ?? 4,
      gs_h: spec.gs_h ?? 3,
      config: spec.config ?? {},
      pinned: false,
      hidden: false,
      created_at: '',
    };
    return { widget, data: spec.data ?? null };
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

  // ---- OAuth login flows ----

  startCodexLogin(): void {
    this.loginBusy.set(true);
    this.loginErr.set(null);
    this.chat.codexStart().subscribe({
      next: (res) => {
        this.loginBusy.set(false);
        this.codexLogin.set(res);
        this.stopCodexPoll();
        this.codexPoll = setInterval(() => this.pollCodex(res.session_id), (res.poll_interval_seconds || 5) * 1000);
      },
      error: (e) => {
        this.loginBusy.set(false);
        this.loginErr.set(e?.error?.detail ?? 'login failed to start');
      },
    });
  }

  private pollCodex(sid: string): void {
    this.chat.codexPoll(sid).subscribe({
      next: (res) => {
        if (res.status === 'authorized') {
          this.stopCodexPoll();
          this.codexLogin.set(null);
          this.refreshAuth();
        } else if (res.status === 'timeout') {
          this.stopCodexPoll();
          this.codexLogin.set(null);
          this.loginErr.set('login timed out — try again');
        }
      },
      error: () => {
        this.stopCodexPoll();
        this.codexLogin.set(null);
        this.loginErr.set('login polling failed');
      },
    });
  }

  private stopCodexPoll(): void {
    if (this.codexPoll) {
      clearInterval(this.codexPoll);
      this.codexPoll = null;
    }
  }

  startClaudeLogin(): void {
    this.loginBusy.set(true);
    this.loginErr.set(null);
    this.chat.claudeStart().subscribe({
      next: (res) => {
        this.loginBusy.set(false);
        this.claudeLogin.set(res);
      },
      error: (e) => {
        this.loginBusy.set(false);
        this.loginErr.set(e?.error?.detail ?? 'login failed to start');
      },
    });
  }

  completeClaudeLogin(): void {
    const login = this.claudeLogin();
    const code = this.claudeCode().trim();
    if (!login || !code) return;
    this.loginBusy.set(true);
    this.loginErr.set(null);
    this.chat.claudeComplete(login.session_id, code).subscribe({
      next: () => {
        this.loginBusy.set(false);
        this.claudeLogin.set(null);
        this.claudeCode.set('');
        this.refreshAuth();
      },
      error: (e) => {
        this.loginBusy.set(false);
        this.loginErr.set(e?.error?.detail ?? 'login failed');
      },
    });
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
