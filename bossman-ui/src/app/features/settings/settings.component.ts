import { Component, inject, signal } from '@angular/core';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { AuthService } from '../../core/auth/auth.service';
import { PlanService } from '../../core/services/plan.service';

/**
 * v1 scope, deliberately small: Bossman's REST API has no user-management
 * or trusted-key-management endpoints yet (see docs/plan.md's Bossman
 * Block B6 "known gap" note — no seed script/CLI/API for
 * bossman_users/api_tokens exists beyond direct DB access or
 * services.auth calls). This page only surfaces what's actually backed
 * by a real endpoint today: the logged-in identity, and the plan-catalog
 * reload action from Block B8's prompt-caching design.
 */
@Component({
  selector: 'app-settings',
  standalone: true,
  imports: [MatCardModule, MatButtonModule],
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
    `,
  ],
})
export class SettingsComponent {
  auth = inject(AuthService);
  private planService = inject(PlanService);

  reloadMessage = signal<string | null>(null);

  reloadCatalog(): void {
    this.planService.reload().subscribe((res) => {
      this.reloadMessage.set(`Reloaded — catalog is now ${res.catalog_length} characters.`);
    });
  }
}
