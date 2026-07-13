import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AuthService } from '../../core/auth/auth.service';
import { PlanService } from '../../core/services/plan.service';
import { EnrollService } from '../../core/services/enroll.service';
import { ChatService } from '../../core/services/chat.service';
import { ChatBackendName, ChatPrefs, ClaudeStartResponse, CodexStartResponse } from '../../core/models/chat.model';
import { EnrollInfo } from '../../core/models/enroll.model';

/**
 * v1 scope, deliberately small: Bossman's REST API has no user-management
 * or trusted-key-management endpoints yet (see docs/plan.md's Bossman
 * Block B6 "known gap" note — no seed script/CLI/API for
 * bossman_users/api_tokens exists beyond direct DB access or
 * services.auth calls). This page only surfaces what's actually backed
 * by a real endpoint today: the logged-in identity, the plan-catalog
 * reload action from Block B8's prompt-caching design, and (Block E1) the
 * enrollment command a new host needs to actually appear anywhere in this
 * UI — without a host, the "Run a plan" dialog has nothing to pick from.
 */
@Component({
  selector: 'app-settings',
  standalone: true,
  imports: [FormsModule, MatCardModule, MatButtonModule, MatIconModule, MatFormFieldModule, MatInputModule, MatSelectModule],
  template: `
    <div class="bm-page">
      <h1>Settings</h1>

      <mat-card>
        <mat-card-header>
          <mat-card-title>Session</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>Signed in as <strong>{{ auth.username() }}</strong> ({{ auth.role() }})</p>
        </mat-card-content>
        <mat-card-actions>
          <button mat-button color="warn" (click)="auth.logout()">Log out</button>
        </mat-card-actions>
      </mat-card>

      <mat-card class="bm-enroll-card">
        <mat-card-header>
          <mat-card-title>Enrollment</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          @if (enrollInfo(); as info) {
            @if (info.configured) {
              <p>
                Run this on a server to enroll it as a node agent (Duppy) — it'll then show up here
                and become available to run plans against:
              </p>
              <div class="bm-command-row">
                <code class="bm-command">{{ info.register_command }}</code>
                <button mat-icon-button (click)="copyCommand(info.register_command)" title="Copy">
                  <mat-icon>content_copy</mat-icon>
                </button>
              </div>
              @if (copied()) {
                <p class="bm-success">Copied.</p>
              }
            } @else {
              <p class="bm-empty">
                Enrollment isn't configured on this Bossman instance yet — set
                <code>BOSSMAN_ENROLL_SECRET</code> (and, ideally, <code>BOSSMAN_PUBLIC_URL</code> so
                the exact command can be shown here) to allow new hosts to enroll.
              </p>
            }

            @if (info.deploy_configured) {
              <hr class="bm-sep" />
              <p>
                …or let Bossman deploy it for you: enter a host's IP or DNS name and Bossman will SSH
                in with its pre-configured operator identity, install the agent, and enroll it — no
                command to run on the host.
              </p>
              <div class="bm-command-row">
                <mat-form-field appearance="outline" class="bm-deploy-field">
                  <mat-label>Host (IP or DNS)</mat-label>
                  <input
                    matInput
                    [(ngModel)]="deployHost"
                    placeholder="e.g. host.example.internal"
                    [disabled]="deploying()"
                    (keyup.enter)="deployNewHost()"
                  />
                </mat-form-field>
                <button
                  mat-raised-button
                  color="primary"
                  [disabled]="deploying() || !deployHost.trim()"
                  (click)="deployNewHost()"
                >
                  {{ deploying() ? 'Deploying…' : 'Deploy & enroll' }}
                </button>
              </div>
              @if (deployMessage()) {
                <p class="bm-success">{{ deployMessage() }}</p>
              }
              @if (deployError()) {
                <p class="bm-error">{{ deployError() }}</p>
              }
            }
          }
        </mat-card-content>
      </mat-card>

      <mat-card class="bm-catalog-card">
        <mat-card-header>
          <mat-card-title>Plan catalog</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>
            The MCP facade's plan catalog is cached and only re-rendered on explicit reload — this
            is what keeps it byte-identical for prompt caching (see docs/plan.md's Bossman plan).
            Reload it here after adding or editing a plan file on disk.
          </p>
          @if (reloadMessage()) {
            <p class="bm-success">{{ reloadMessage() }}</p>
          }
        </mat-card-content>
        <mat-card-actions>
          <button mat-raised-button color="primary" (click)="reloadCatalog()">Reload plan catalog</button>
        </mat-card-actions>
      </mat-card>

      <mat-card class="bm-llm-card">
        <mat-card-header>
          <mat-card-title>AI Assistant (LLM)</mat-card-title>
        </mat-card-header>
        <mat-card-content>
          <p>
            Configure the console's AI backend and model. The OpenAI-compatible (hermes) endpoint can
            also point at a custom URL. The CLI assistants (Claude, ChatGPT) are connected via OAuth
            below — once connected they can be picked as the default backend.
          </p>
          @if (prefs(); as p) {
            <div class="bm-llm-row">
              <mat-form-field appearance="outline">
                <mat-label>Default backend</mat-label>
                <mat-select [(ngModel)]="p.default_backend">
                  @for (b of backends(); track b) {
                    <mat-option [value]="b">{{ backendLabel(b) }}</mat-option>
                  }
                </mat-select>
              </mat-form-field>
              <mat-form-field appearance="outline">
                <mat-label>Model ({{ backendLabel(p.default_backend) }})</mat-label>
                <input
                  matInput
                  [ngModel]="modelFor(p.default_backend)"
                  (ngModelChange)="setModel(p.default_backend, $event)"
                  placeholder="e.g. sonnet / gpt-5.5 / qwen3next-79b"
                />
              </mat-form-field>
            </div>
            @if (p.default_backend === 'hermes_web') {
              <div class="bm-llm-row">
                <mat-form-field appearance="outline" class="bm-llm-wide">
                  <mat-label>Endpoint (base URL)</mat-label>
                  <input matInput [(ngModel)]="p.hermes_base_url" placeholder="https://…/v1" />
                </mat-form-field>
                <mat-form-field appearance="outline">
                  <mat-label>Endpoint model</mat-label>
                  <input matInput [(ngModel)]="p.hermes_model" placeholder="qwen3next-79b" />
                </mat-form-field>
              </div>
            }
            <div class="bm-llm-actions">
              <button mat-raised-button color="primary" (click)="saveLlm()" [disabled]="llmBusy()">Save</button>
              @if (llmMsg()) {
                <span class="bm-success">{{ llmMsg() }}</span>
              }
            </div>
          }

          <hr class="bm-sep" />
          <p>Connect a CLI assistant via OAuth:</p>
          <div class="bm-llm-logins">
            <div class="bm-llm-login">
              <span class="bm-login-name">
                Claude CLI —
                <strong [class.bm-success]="authed()['claude_cli']">
                  {{ authed()['claude_cli'] ? 'connected ✓' : 'not connected' }}
                </strong>
              </span>
              @if (claudeLogin(); as c) {
                <a [href]="c.authorize_url" target="_blank" rel="noopener">Open Claude authorize page ↗</a>
                <input
                  class="bm-login-input"
                  [value]="claudeCode()"
                  (input)="claudeCode.set($any($event.target).value)"
                  placeholder="paste code#state"
                />
                <button
                  mat-stroked-button
                  (click)="completeClaudeLogin()"
                  [disabled]="loginBusy() || !claudeCode().trim()"
                >
                  Complete
                </button>
              } @else {
                <button mat-flat-button color="primary" (click)="startClaudeLogin()" [disabled]="loginBusy()">
                  Log in with Claude
                </button>
              }
            </div>

            <div class="bm-llm-login">
              <span class="bm-login-name">
                ChatGPT Codex —
                <strong [class.bm-success]="authed()['codex']">
                  {{ authed()['codex'] ? 'connected ✓' : 'not connected' }}
                </strong>
              </span>
              @if (codexLogin(); as c) {
                <span>
                  Open
                  <a [href]="c.verification_uri" target="_blank" rel="noopener">{{ c.verification_uri }} ↗</a>
                  and enter code <code>{{ c.user_code }}</code> (waiting…)
                </span>
              } @else {
                <button mat-flat-button color="primary" (click)="startCodexLogin()" [disabled]="loginBusy()">
                  Log in with ChatGPT
                </button>
              }
            </div>

            @if (loginErr()) {
              <span class="bm-error">{{ loginErr() }}</span>
            }
          </div>
        </mat-card-content>
      </mat-card>

      <!-- Check rules and Host groups live in the OU / Policy view (scoped to
           OUs there); they were removed from Settings to avoid a second,
           unscoped home for the same objects. -->
    </div>
  `,
  styles: [
    `
      .bm-default-tag {
        font-size: 10px;
        margin-left: 6px;
        padding: 1px 6px;
        border-radius: 999px;
        background: color-mix(in srgb, var(--bm-green) 22%, transparent);
        vertical-align: middle;
      }
      .bm-page {
        padding: 24px;
        max-width: 900px;
        margin: 0 auto;
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .bm-table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 8px;
      }
      .bm-table th {
        text-align: left;
        font-size: 12px;
        opacity: 0.7;
        padding: 8px 10px;
      }
      .bm-table td {
        padding: 8px 10px;
        border-top: 1px solid var(--mat-sys-outline-variant);
      }
      .bm-actions {
        text-align: right;
        white-space: nowrap;
      }
      .bm-groups-field {
        width: 100%;
      }
      .bm-success {
        color: var(--bm-green);
      }
      .bm-error {
        color: var(--bm-red);
      }
      .bm-empty {
        opacity: 0.75;
      }
      .bm-sep {
        border: none;
        border-top: 1px solid var(--mat-sys-outline-variant);
        margin: 16px 0;
      }
      .bm-deploy-field {
        flex: 1;
      }
      .bm-command-row {
        display: flex;
        align-items: center;
        gap: 8px;
      }
      .bm-command {
        display: block;
        flex: 1;
        padding: 10px 12px;
        background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent);
        border-radius: 6px;
        font-size: 12.5px;
        overflow-x: auto;
        white-space: pre;
      }
      .bm-llm-row {
        display: flex;
        gap: 12px;
        flex-wrap: wrap;
      }
      .bm-llm-row mat-form-field {
        flex: 1;
        min-width: 220px;
      }
      .bm-llm-wide {
        flex: 2 !important;
      }
      .bm-llm-actions {
        display: flex;
        align-items: center;
        gap: 12px;
      }
      .bm-llm-logins {
        display: flex;
        flex-direction: column;
        gap: 12px;
      }
      .bm-llm-login {
        display: flex;
        align-items: center;
        gap: 10px;
        flex-wrap: wrap;
      }
      .bm-login-name {
        min-width: 200px;
      }
      .bm-login-input {
        flex: 1;
        min-width: 220px;
        padding: 8px 10px;
        border: 1px solid var(--mat-sys-outline-variant);
        border-radius: 6px;
        background: transparent;
        color: inherit;
        font-family: monospace;
        font-size: 12.5px;
      }
    `,
  ],
})
export class SettingsComponent implements OnInit, OnDestroy {
  auth = inject(AuthService);
  private planService = inject(PlanService);
  private enrollService = inject(EnrollService);
  private chat = inject(ChatService);

  reloadMessage = signal<string | null>(null);
  enrollInfo = signal<EnrollInfo | null>(null);
  copied = signal(false);
  deployHost = '';
  deploying = signal(false);
  deployMessage = signal<string | null>(null);
  deployError = signal<string | null>(null);

  // AI Assistant / LLM config.
  prefs = signal<ChatPrefs | null>(null);
  backends = signal<ChatBackendName[]>([]);
  authed = signal<Record<string, boolean>>({});
  llmBusy = signal(false);
  llmMsg = signal<string | null>(null);
  // OAuth login (ported from the chat dock, which now only shows already-authed
  // backends — so connecting a new CLI assistant has to live here).
  codexLogin = signal<CodexStartResponse | null>(null);
  claudeLogin = signal<ClaudeStartResponse | null>(null);
  claudeCode = signal('');
  loginBusy = signal(false);
  loginErr = signal<string | null>(null);
  private codexPoll: ReturnType<typeof setInterval> | null = null;

  private readonly backendLabels: Record<ChatBackendName, string> = {
    hermes_web: 'OpenAI-compatible (hermes)',
    claude_cli: 'Claude CLI',
    codex: 'ChatGPT Codex',
  };

  ngOnInit(): void {
    this.enrollService.info().subscribe((info) => this.enrollInfo.set(info));
    this.chat.backends().subscribe((res) => this.backends.set(res.backends));
    this.chat.getPrefs().subscribe((p) => this.prefs.set(p));
    this.refreshAuth();
  }

  ngOnDestroy(): void {
    this.stopCodexPoll();
  }

  backendLabel(b: ChatBackendName): string {
    return this.backendLabels[b] ?? b;
  }

  modelFor(b: ChatBackendName): string {
    return this.prefs()?.models?.[b] ?? '';
  }

  setModel(b: ChatBackendName, value: string): void {
    const p = this.prefs();
    if (!p) return;
    this.prefs.set({ ...p, models: { ...p.models, [b]: value } });
  }

  saveLlm(): void {
    const p = this.prefs();
    if (!p) return;
    this.llmBusy.set(true);
    this.llmMsg.set(null);
    this.chat
      .setPrefs({
        default_backend: p.default_backend,
        models: p.models,
        hermes_base_url: p.hermes_base_url?.trim() || undefined,
        hermes_model: p.hermes_model?.trim() || undefined,
      })
      .subscribe({
        next: (saved) => {
          this.prefs.set(saved);
          this.llmBusy.set(false);
          this.llmMsg.set('Saved.');
          setTimeout(() => this.llmMsg.set(null), 2500);
        },
        error: (e) => {
          this.llmBusy.set(false);
          this.llmMsg.set(e?.error?.detail ?? 'save failed');
        },
      });
  }

  private refreshAuth(): void {
    this.chat.oauthStatus().subscribe((res) => this.authed.set(res.authenticated ?? {}));
  }

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
        this.loginErr.set(e?.error?.detail ?? 'login failed to complete');
      },
    });
  }

  reloadCatalog(): void {
    this.planService.reload().subscribe((res) => {
      this.reloadMessage.set(`Reloaded — catalog is now ${res.catalog_length} characters.`);
    });
  }

  /** Block N-enroll: kick off a server-driven SSH deploy of a new host.
   * Bossman does all the work (SSH + install + provision + enroll); we just
   * surface progress and the result. */
  deployNewHost(): void {
    const host = this.deployHost.trim();
    if (!host || this.deploying()) return;
    this.deploying.set(true);
    this.deployMessage.set(null);
    this.deployError.set(null);
    this.enrollService.deploy(host).subscribe({
      next: (res) => {
        this.deploying.set(false);
        this.deployHost = '';
        this.deployMessage.set(`Deployed and enrolled "${res.name}"${res.address ? ' (' + res.address + ')' : ''}. It will appear in Hosts shortly.`);
      },
      error: (e) => {
        this.deploying.set(false);
        this.deployError.set(e?.error?.detail ?? 'deploy failed');
      },
    });
  }

  copyCommand(command: string | null): void {
    if (!command) return;
    navigator.clipboard.writeText(command).then(() => {
      this.copied.set(true);
      setTimeout(() => this.copied.set(false), 2000);
    });
  }
}
