import { Component, OnInit, inject, signal } from '@angular/core';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AuthService } from '../../core/auth/auth.service';
import { PlanService } from '../../core/services/plan.service';
import { EnrollService } from '../../core/services/enroll.service';
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
  imports: [MatCardModule, MatButtonModule, MatIconModule],
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
    </div>
  `,
  styles: [
    `
      .bm-page {
        padding: 24px;
        max-width: 700px;
        margin: 0 auto;
        display: flex;
        flex-direction: column;
        gap: 16px;
      }
      .bm-success {
        color: var(--bm-green);
      }
      .bm-empty {
        opacity: 0.75;
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
    `,
  ],
})
export class SettingsComponent implements OnInit {
  auth = inject(AuthService);
  private planService = inject(PlanService);
  private enrollService = inject(EnrollService);

  reloadMessage = signal<string | null>(null);
  enrollInfo = signal<EnrollInfo | null>(null);
  copied = signal(false);

  ngOnInit(): void {
    this.enrollService.info().subscribe((info) => this.enrollInfo.set(info));
  }

  reloadCatalog(): void {
    this.planService.reload().subscribe((res) => {
      this.reloadMessage.set(`Reloaded — catalog is now ${res.catalog_length} characters.`);
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
