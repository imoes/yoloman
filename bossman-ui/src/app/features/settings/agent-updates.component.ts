import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { DatePipe } from '@angular/common';
import { MatCardModule } from '@angular/material/card';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { environment } from '../../../environments/environment';

interface Asset { name: string; sha256: string; url: string; }
interface ReleaseLatest { version: string; tag: string; html_url: string; published_at: string | null; deb: Asset | null; rpm: Asset | null; }
interface OutdatedAgent { id: string; name: string; agent_version: string; address: string; kind: string; updatable: boolean; }
interface ReleaseView { enabled: boolean; checked_at: string | null; error: string | null; latest: ReleaseLatest | null; outdated: OutdatedAgent[]; }
interface RolloutResult { version: string; pushed: number; results: { agent_id: string; name: string; ok?: boolean; error?: string; kind?: string; asset?: string }[]; }

/**
 * Agent updates — the release channel view. Bossman polls the yoloman-agent
 * GitHub release (version + per-asset SHA-256 from its manifest) on the poller's
 * cadence; this card shows the latest package, which enrolled hosts are behind,
 * and a one-click rollout that verifies the package hash before pushing the
 * self-update over mTLS. Detection + explicit rollout — never an unattended push.
 */
@Component({
  selector: 'app-agent-updates',
  standalone: true,
  imports: [DatePipe, MatCardModule, MatButtonModule, MatIconModule],
  template: `
    <mat-card class="bm-au-card">
      <mat-card-header>
        <mat-card-title>Agent updates</mat-card-title>
        <mat-card-subtitle>yoloman-agent release channel — hash-verified rollout</mat-card-subtitle>
      </mat-card-header>
      <mat-card-content>
        @if (view(); as v) {
          <div class="bm-au-latest">
            @if (v.latest; as l) {
              <div class="bm-au-line">
                <mat-icon class="bm-au-ic">inventory_2</mat-icon>
                <span>Latest package: <strong>{{ l.version }}</strong>
                  <a [href]="l.html_url" target="_blank" rel="noopener" class="bm-au-tag">{{ l.tag }}</a></span>
              </div>
              <div class="bm-au-assets">
                @if (l.deb) { <span class="bm-au-asset" [title]="l.deb.sha256">deb · {{ shortSha(l.deb.sha256) }}</span> }
                @if (l.rpm) { <span class="bm-au-asset" [title]="l.rpm.sha256">rpm · {{ shortSha(l.rpm.sha256) }}</span> }
              </div>
            } @else {
              <p class="bm-au-dim">No release detected yet.</p>
            }
            <p class="bm-au-dim">
              @if (v.checked_at) { Last checked {{ v.checked_at | date: 'short' }}. } @else { Not checked yet. }
              @if (v.error) { <span class="bm-au-err">· {{ v.error }}</span> }
            </p>
          </div>

          <div class="bm-au-actions">
            <button mat-stroked-button (click)="check()" [disabled]="busy()">
              <mat-icon>refresh</mat-icon> {{ busy() ? 'Checking…' : 'Check now' }}
            </button>
            @if (outdated().length) {
              <button mat-flat-button color="primary" (click)="rolloutAll()" [disabled]="busy() || !anyUpdatable()">
                <mat-icon>system_update_alt</mat-icon> Roll out {{ l1() }} to {{ updatableCount() }} host(s)
              </button>
            }
          </div>

          @if (outdated().length) {
            <h4 class="bm-au-h">Hosts behind {{ v.latest?.version }} ({{ outdated().length }})</h4>
            <table class="bm-au-tbl">
              <thead><tr><th>Host</th><th>Installed</th><th></th><th>Latest</th><th>Pkg</th><th></th></tr></thead>
              <tbody>
                @for (a of outdated(); track a.id) {
                  <tr>
                    <td class="bm-au-mono">{{ a.name }}</td>
                    <td class="bm-au-mono">{{ a.agent_version || '—' }}</td>
                    <td class="bm-au-arrow">→</td>
                    <td class="bm-au-mono">{{ v.latest?.version }}</td>
                    <td><span class="bm-au-kind">{{ a.kind }}</span></td>
                    <td>
                      @if (a.updatable) {
                        <button mat-button (click)="rolloutOne(a)" [disabled]="busy()">Update</button>
                      } @else {
                        <span class="bm-au-dim" title="No direct address — push it through its proxy or set an address">not reachable</span>
                      }
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else if (v.latest) {
            <p class="bm-au-ok"><mat-icon>verified</mat-icon> All enrolled hosts are on {{ v.latest.version }}.</p>
          }

          @if (rollout(); as r) {
            <div class="bm-au-rollout">
              <strong>Rollout {{ r.version }}: {{ r.pushed }}/{{ r.results.length }} pushed</strong>
              @for (res of r.results; track res.agent_id) {
                <div class="bm-au-rres" [class.bad]="!res.ok">
                  <mat-icon>{{ res.ok ? 'check_circle' : 'error' }}</mat-icon>
                  {{ res.name }} @if (!res.ok) { — {{ res.error }} }
                </div>
              }
            </div>
          }
        } @else {
          <p class="bm-au-dim">Loading…</p>
        }
      </mat-card-content>
    </mat-card>
  `,
  styles: [`
    .bm-au-card { margin-top: 16px; }
    .bm-au-line { display: flex; align-items: center; gap: 8px; }
    .bm-au-ic { opacity: 0.8; }
    .bm-au-tag { margin-left: 8px; font-size: 12px; opacity: 0.7; }
    .bm-au-assets { display: flex; gap: 8px; margin: 6px 0 2px 30px; }
    .bm-au-asset { font-family: ui-monospace, monospace; font-size: 11.5px; padding: 2px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 20px; opacity: 0.8; }
    .bm-au-dim { opacity: 0.65; font-size: 13px; margin: 6px 0; }
    .bm-au-err { color: var(--mat-sys-error, #c62828); }
    .bm-au-actions { display: flex; gap: 10px; margin: 12px 0; }
    .bm-au-h { margin: 14px 0 6px; font-size: 13px; }
    .bm-au-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-au-tbl th { text-align: left; font-weight: 600; opacity: 0.6; padding: 4px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-au-tbl td { padding: 4px 8px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); }
    .bm-au-mono { font-family: ui-monospace, monospace; }
    .bm-au-arrow { opacity: 0.5; }
    .bm-au-kind { font-size: 11px; padding: 1px 7px; border-radius: 20px; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    .bm-au-ok { display: flex; align-items: center; gap: 6px; color: #66bb6a; font-size: 13px; }
    .bm-au-rollout { margin-top: 12px; padding: 10px; border-radius: 8px; background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); font-size: 13px; }
    .bm-au-rres { display: flex; align-items: center; gap: 6px; margin-top: 4px; }
    .bm-au-rres mat-icon { font-size: 16px; height: 16px; width: 16px; color: #66bb6a; }
    .bm-au-rres.bad mat-icon { color: var(--mat-sys-error, #c62828); }
  `],
})
export class AgentUpdatesComponent implements OnInit {
  private http = inject(HttpClient);
  private base = environment.apiUrl;
  view = signal<ReleaseView | null>(null);
  rollout = signal<RolloutResult | null>(null);
  busy = signal(false);

  outdated = computed(() => this.view()?.outdated ?? []);
  anyUpdatable = computed(() => this.outdated().some((a) => a.updatable));
  updatableCount = computed(() => this.outdated().filter((a) => a.updatable).length);
  l1 = computed(() => this.view()?.latest?.version ?? '');

  shortSha(s: string): string { return s ? s.slice(0, 12) + '…' : '—'; }

  ngOnInit(): void { this.load(); }
  private load(): void {
    this.http.get<ReleaseView>(`${this.base}/agent-release`).subscribe((v) => this.view.set(v));
  }
  check(): void {
    this.busy.set(true);
    this.http.post<ReleaseView>(`${this.base}/agent-release/check`, {}).subscribe({
      next: (v) => { this.view.set(v); this.busy.set(false); },
      error: () => this.busy.set(false),
    });
  }
  rolloutAll(): void { this.doRollout({ all_outdated: true }); }
  rolloutOne(a: OutdatedAgent): void { this.doRollout({ agent_ids: [a.id] }); }
  private doRollout(body: Record<string, unknown>): void {
    this.busy.set(true);
    this.rollout.set(null);
    this.http.post<RolloutResult>(`${this.base}/agent-release/rollout`, body).subscribe({
      next: (r) => { this.rollout.set(r); this.busy.set(false); this.load(); },
      error: (e) => { this.busy.set(false); this.rollout.set({ version: '', pushed: 0, results: [{ agent_id: '', name: e?.error?.detail ?? 'rollout failed', ok: false, error: e?.error?.detail }] }); },
    });
  }
}
