import { Component, NgZone, OnDestroy, OnInit, computed, inject, signal } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { marked } from 'marked';
import { ChatService } from '../../core/services/chat.service';
import { ChatBackendName, ChatEvent, ChatForm, ChatHistoryMessage, ChatTask, ChatUiMessage, ChatWidget, CodexStartResponse, ClaudeStartResponse, PlanGraphSpec } from '../../core/models/chat.model';
import { DashboardWidgetComponent } from '../../shared/components/dashboard-widget/dashboard-widget.component';
import { DashboardWidget, WidgetType } from '../../core/models/dashboard.model';
import { ChatPlanGraphComponent } from './chat-plan-graph.component';
import { ChatFormComponent } from './chat-form.component';
import { ChatTaskComponent } from './chat-task.component';
import { plantumlToGraph } from './plantuml-graph';

const WIDGET_TYPES: WidgetType[] = [
  'top_hosts', 'problems', 'gauge', 'timeseries', 'donut', 'stat',
  'bar', 'table', 'status_tiles', 'progress', 'ai_summary', 'war_room', 'log', 'callout',
];

marked.setOptions({ gfm: true, breaks: true });

interface ChatTab {
  id: string | null;
  label: string;
  messages: ChatUiMessage[];
  loaded: boolean; // false = a persisted session whose history isn't fetched yet
}

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
  imports: [MatIconModule, MatButtonModule, MatProgressSpinnerModule, DashboardWidgetComponent, ChatPlanGraphComponent, ChatFormComponent, ChatTaskComponent],
  template: `
    <div class="bm-dock" [class.bm-dock-collapsed]="!open()" [class.bm-dock-max]="maximized() && open()" [style.height.px]="open() && !maximized() ? height() : null">
      <div class="bm-dock-resize" (mousedown)="startResize($event)"></div>
      <div class="bm-dock-head">
        <button mat-icon-button (click)="open.set(!open())" [title]="open() ? 'Collapse' : 'Expand'">
          <mat-icon>{{ open() ? 'expand_more' : 'expand_less' }}</mat-icon>
        </button>
        <mat-icon class="bm-dock-icon">smart_toy</mat-icon>
        <span class="bm-dock-title">Assistant</span>
        <select class="bm-dock-backend" [value]="backend()" (change)="onBackendChange($any($event.target).value)" [disabled]="streaming()">
          @for (b of visibleBackends(); track b) { <option [value]="b">{{ label(b) }}</option> }
        </select>
        <span class="bm-dock-spacer"></span>
        <button mat-icon-button (click)="newTab()" [disabled]="streaming()" title="New chat"><mat-icon>add_comment</mat-icon></button>
        <button mat-icon-button (click)="toggleMax()" [title]="maximized() ? 'Restore' : 'Maximize'"><mat-icon>{{ maximized() ? 'fullscreen_exit' : 'fullscreen' }}</mat-icon></button>
      </div>

      @if (open()) {
        <div class="bm-dock-tabs">
          @for (t of tabs(); track $index) {
            <button class="bm-tab" [class.bm-tab-active]="$index === active()" (click)="switchTab($index)" [title]="t.label">
              <span class="bm-tab-lbl">{{ t.label }}</span>
              @if (tabs().length > 1) { <mat-icon class="bm-tab-x" (click)="closeTab($index, $event)">close</mat-icon> }
            </button>
          }
          <button mat-icon-button class="bm-tab-new" (click)="newTab()" [disabled]="streaming()" title="New chat"><mat-icon>add</mat-icon></button>
        </div>
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
              @if (m.forms?.length) {
                @for (f of m.forms!; track $index) {
                  <app-chat-form [form]="f" />
                }
              }
              @if (m.tasks?.length) {
                @for (t of m.tasks!; track $index) {
                  <app-chat-task [task]="t" />
                }
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
      .bm-dock-max { position: fixed; top: 0; left: 0; width: 100vw; height: 100vh; height: 100dvh !important; max-height: 100dvh; z-index: 2000; border-top: none; }
      .bm-dock-resize { position: absolute; top: -3px; left: 0; right: 0; height: 6px; cursor: ns-resize; }
      .bm-dock-head { display: flex; align-items: center; gap: 8px; padding: 2px 10px; flex: none; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-dock-icon { color: var(--mat-sys-primary); }
      .bm-dock-title { font: var(--mat-sys-title-small); }
      .bm-dock-backend { background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); border: 1px solid var(--mat-sys-outline); border-radius: 4px; padding: 2px 6px; }
      .bm-dock-spacer { flex: 1; }
      .bm-dock-tabs { display: flex; align-items: center; gap: 4px; padding: 4px 8px 0; flex: none; overflow-x: auto; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-tab { display: inline-flex; align-items: center; gap: 4px; max-width: 170px; padding: 4px 8px; border: 1px solid var(--mat-sys-outline-variant); border-bottom: none; border-radius: 6px 6px 0 0; background: transparent; color: inherit; font-size: 12px; cursor: pointer; }
      .bm-tab-lbl { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 130px; }
      .bm-tab-active { background: var(--mat-sys-surface); box-shadow: inset 0 -2px 0 var(--mat-sys-primary); font-weight: 600; }
      .bm-tab-x { font-size: 15px; width: 15px; height: 15px; opacity: 0.55; }
      .bm-tab-x:hover { opacity: 1; }
      .bm-tab-new { transform: scale(0.8); }
      .bm-dock-body { flex: 1; overflow-y: auto; padding: 10px 12px; display: flex; flex-direction: column; gap: 10px; }
      .bm-msg { max-width: 90%; padding: 6px 10px; border-radius: 8px; font-size: 13px; }
      .bm-msg-user { align-self: flex-end; background: color-mix(in srgb, var(--mat-sys-primary) 22%, transparent); }
      .bm-msg-ai { align-self: flex-start; background: var(--mat-sys-surface); border: 1px solid var(--mat-sys-outline-variant); }
      /* A designed dashboard / form / graph uses the full width, not the 90% bubble. */
      .bm-msg-ai:has(app-chat-task), .bm-msg-ai:has(app-chat-form), .bm-msg-ai:has(app-chat-plan-graph) {
        max-width: 100%; width: 100%; background: none; border: none; padding: 0;
      }
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
  maximized = signal(false);
  // Default to ~72% of the viewport (clearly more than half), still resizable;
  // the maximize toggle takes it to the full window.
  height = signal(Math.max(420, Math.round((typeof window !== 'undefined' ? window.innerHeight : 900) * 0.72)));
  backends = signal<ChatBackendName[]>(['claude_cli', 'codex', 'hermes_web']);
  backend = signal<ChatBackendName>('claude_cli');
  messages = signal<ChatUiMessage[]>([]);
  // Multiple concurrent chats (tabs). `messages`/`sessionId` mirror the active
  // tab; switching persists the current one and loads the target.
  tabs = signal<ChatTab[]>([{ id: null, label: 'Chat 1', messages: [], loaded: true }]);
  active = signal(0);
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

  /** Only the CONFIGURED / usable LLMs are offered: hermes_web (server-side, no
   * login) plus any CLI backend the user is actually logged in to. Not-logged-in
   * CLI tools are hidden rather than shown with a ⚠. The current backend stays
   * visible so the selector never shows an empty/blank value. */
  visibleBackends = computed(() =>
    this.backends().filter((b) => b === 'hermes_web' || this.authed()[b] === true || b === this.backend()),
  );

  private sessionId: string | null = null;
  private abort: AbortController | null = null;
  private codexPoll: ReturnType<typeof setInterval> | null = null;
  private mdCache = new WeakMap<ChatUiMessage, SafeHtml>();

  label = (b: string) => BACKEND_LABELS[b] ?? b;

  toggleMax(): void {
    this.maximized.set(!this.maximized());
    if (this.maximized()) this.open.set(true);
  }

  ngOnInit(): void {
    this.chat.backends().subscribe({ next: (res) => this.backends.set(res.backends), error: () => {} });
    // Per-user default backend + auth status.
    this.chat.getPrefs().subscribe({ next: (p) => this.backend.set(p.default_backend), error: () => {} });
    this.refreshAuth();
    this.loadSessions();
  }

  /** Restore the user's persisted conversations as tabs so they're findable
   * across reloads. The newest becomes the active tab (its history is fetched);
   * the rest load lazily on switch. */
  private loadSessions(): void {
    this.chat.listSessions().subscribe({
      next: (res) => {
        const sessions = [...(res.sessions ?? [])].sort((a, b) => (b.updated_at ?? '').localeCompare(a.updated_at ?? ''));
        if (!sessions.length) return; // keep the default empty "Chat 1"
        const tabs: ChatTab[] = sessions.slice(0, 15).map((s, i) => ({
          id: s.id,
          label: s.label || `Chat ${i + 1}`,
          messages: [],
          loaded: false,
        }));
        this.tabs.set(tabs);
        this.active.set(0);
        this.sessionId = tabs[0].id;
        this.loadHistory(0);
      },
      error: () => {},
    });
  }

  /** Fetch one tab's persisted history (once), re-parsing artifacts so widgets
   * / diagrams / forms render on reload. */
  private loadHistory(i: number): void {
    const t = this.tabs()[i];
    if (!t || !t.id || t.loaded) return;
    this.chat.history(t.id).subscribe({
      next: (res) => {
        t.messages = this.historyToUi(res.messages ?? []);
        t.loaded = true;
        if (this.active() === i) this.messages.set(t.messages);
      },
      error: () => { t.loaded = true; },
    });
  }

  private historyToUi(hist: ChatHistoryMessage[]): ChatUiMessage[] {
    const out: ChatUiMessage[] = [];
    for (const h of hist) {
      if (h.role === 'system') continue;
      if (h.role === 'user') { out.push({ role: 'user', text: h.content }); continue; }
      const { cleaned, widgets, planGraphs, diagrams, forms, tasks } = this.parseArtifacts(h.content);
      const m: ChatUiMessage = { role: 'assistant', text: cleaned };
      if (widgets.length) m.widgets = widgets;
      if (planGraphs.length) m.planGraphs = planGraphs;
      if (diagrams.length) m.diagrams = diagrams;
      if (forms.length) m.forms = forms;
      if (tasks.length) m.tasks = tasks;
      out.push(m);
    }
    return out;
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
    // Reset the ACTIVE tab (used when the backend changes — sessions are pinned).
    this.sessionId = null;
    this.messages.set([]);
    const t = this.tabs();
    if (t[this.active()]) { t[this.active()].id = null; t[this.active()].messages = []; }
  }

  // ---- multiple chats (tabs) ----
  private persistActive(): void {
    const t = this.tabs();
    if (t[this.active()]) { t[this.active()].messages = this.messages(); t[this.active()].id = this.sessionId; }
  }

  switchTab(i: number): void {
    if (i === this.active() || this.streaming()) return;
    this.persistActive();
    this.active.set(i);
    const t = this.tabs()[i];
    this.sessionId = t.id;
    this.messages.set(t.messages);
    this.loadHistory(i);
  }

  newTab(): void {
    if (this.streaming()) return;
    this.persistActive();
    const next = [...this.tabs(), { id: null, label: `Chat ${this.tabs().length + 1}`, messages: [], loaded: true }];
    this.tabs.set(next);
    this.active.set(next.length - 1);
    this.sessionId = null;
    this.messages.set([]);
    this.open.set(true);
  }

  closeTab(i: number, ev: Event): void {
    ev.stopPropagation();
    if (this.tabs().length <= 1) return;
    // Deleting a tab deletes its persisted conversation server-side, so it does
    // NOT reappear on reload (a bare in-memory tab with no id has nothing to delete).
    const closing = this.tabs()[i];
    if (closing?.id) this.chat.deleteSession(closing.id).subscribe({ error: () => {} });
    if (i !== this.active()) this.persistActive();
    const next = this.tabs().filter((_, idx) => idx !== i);
    let act = this.active();
    if (i === act) act = Math.min(i, next.length - 1);
    else if (i < act) act -= 1;
    this.tabs.set(next);
    this.active.set(act);
    this.sessionId = next[act].id;
    this.messages.set(next[act].messages);
  }

  private async ensureSession(): Promise<string> {
    if (this.sessionId) return this.sessionId;
    const s = await new Promise<string>((resolve, reject) =>
      this.chat.createSession(this.backend()).subscribe({ next: (r) => resolve(r.id), error: reject }),
    );
    this.sessionId = s;
    const t = this.tabs();
    const cur = t[this.active()];
    if (cur) {
      cur.id = s;
      // Persist the tab's name as the session label so the chat is findable later.
      if (cur.label && !/^Chat \d+$/.test(cur.label)) this.chat.rename(s, cur.label).subscribe({ error: () => {} });
    }
    return s;
  }

  send(ev: Event): void {
    ev.preventDefault();
    const text = this.input().trim();
    if (!text || this.streaming()) return;
    this.open.set(true);
    this.input.set('');
    this.loadErr.set(null);
    // Name the active tab after its first message.
    const tabs = this.tabs();
    const cur = tabs[this.active()];
    if (cur && /^Chat \d+$/.test(cur.label)) {
      cur.label = text.length > 26 ? text.slice(0, 26) + '…' : text;
      this.tabs.set([...tabs]);
    }
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
          const { cleaned, widgets, planGraphs, diagrams, forms, tasks } = this.parseArtifacts(assistant.text);
          assistant.text = cleaned;
          if (widgets.length) assistant.widgets = widgets;
          if (planGraphs.length) assistant.planGraphs = planGraphs;
          if (diagrams.length) assistant.diagrams = diagrams;
          if (forms.length) assistant.forms = forms;
          if (tasks.length) { assistant.tasks = tasks; this.maximized.set(true); this.open.set(true); }
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
    forms: ChatForm[];
    tasks: ChatTask[];
  } {
    const widgets: ChatWidget[] = [];
    const planGraphs: PlanGraphSpec[] = [];
    const diagrams: string[] = [];
    const forms: ChatForm[] = [];
    const tasks: ChatTask[] = [];

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

    // Render PlantUML the CentralStation way — parse it into a node/edge graph
    // and draw it INTERACTIVELY with Cytoscape (no SVG, no external server).
    // Unparseable source is left as a code block rather than silently dropped.
    cleaned = cleaned.replace(/```plantuml\s*([\s\S]*?)```/g, (full, body) => {
      const graph = plantumlToGraph(String(body).trim());
      if (graph) { planGraphs.push({ title: 'Diagram', nodes: graph.nodes, edges: graph.edges }); return ''; }
      return full;
    });

    // Task → input-mask: pull ```bm-form``` blocks into rendered forms.
    cleaned = cleaned.replace(/```bm-form\s*([\s\S]*?)```/g, (full, body) => {
      try {
        const spec = JSON.parse(String(body).trim());
        if (spec && Array.isArray(spec.fields)) {
          forms.push({
            intent: spec.intent ?? '', plan: spec.plan ?? null,
            generated_plan: spec.generated_plan ?? null,
            needs_host: spec.needs_host, fields: spec.fields,
          });
          return '';
        }
      } catch {
        /* leave a malformed block visible as-is */
      }
      return full;
    });

    // Full task dashboards.
    cleaned = cleaned.replace(/```bm-task\s*([\s\S]*?)```/g, (full, body) => {
      try {
        const spec = JSON.parse(String(body).trim());
        if (spec && Array.isArray(spec.sections)) {
          tasks.push({
            title: spec.title ?? 'Task', intro: spec.intro, plan: spec.plan ?? null,
            generated_plan: spec.generated_plan ?? null, sections: spec.sections,
            summary: spec.summary, output: spec.output,
          });
          return '';
        }
      } catch {
        /* leave malformed block as text */
      }
      return full;
    });

    return { cleaned: cleaned.trim(), widgets, planGraphs, diagrams, forms, tasks };
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
