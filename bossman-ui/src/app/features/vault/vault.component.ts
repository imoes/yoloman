import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';

interface SecretRef { source: string; scope_type: string; scope: string; key: string; }
interface VaultInventory { total: number; by_source: Record<string, number>; secrets: SecretRef[]; }

/**
 * Vault — a read-only inventory of the encrypted secrets Bossman holds
 * (`vault:v1:` handles in scope variables and config-policy values). It shows
 * WHERE each secret lives (scope + key) so they can be audited; it never returns
 * or decrypts the plaintext. Editing a secret happens where it is set (the host's
 * Variables editor / the config-policy editor).
 */
@Component({
  selector: 'app-vault',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-page">
      <div class="bm-vault-head">
        <h1><mat-icon>key</mat-icon> Vault</h1>
        <button mat-stroked-button (click)="load()" [disabled]="loading()">
          <mat-icon>refresh</mat-icon> Reload
        </button>
      </div>
      <p class="bm-dim">Encrypted secrets Bossman holds as <code>vault:v1:</code> handles. This is an audit
        view — the plaintext is never shown or exported. Change a secret where it is set (a host's
        Variables editor, or the config-policy editor).</p>

      @if (inv(); as v) {
        <div class="bm-vault-stats">
          <span class="bm-chip">{{ v.total }} secret(s)</span>
          @for (s of sources(v); track s[0]) { <span class="bm-chip bm-chip-src">{{ s[1] }} {{ s[0] }}</span> }
        </div>
        @if (v.secrets.length) {
          <table class="bm-vault-tbl">
            <thead><tr><th>Source</th><th>Scope</th><th>Key</th><th></th></tr></thead>
            <tbody>
              @for (s of v.secrets; track s.source + s.scope + s.key) {
                <tr>
                  <td><span class="bm-src-tag" [attr.data-src]="s.source">{{ s.source }}</span></td>
                  <td>{{ s.scope }} <span class="bm-dim">({{ s.scope_type }})</span></td>
                  <td class="bm-mono">{{ s.key }}</td>
                  <td class="bm-mono bm-masked">••••••••</td>
                </tr>
              }
            </tbody>
          </table>
        } @else {
          <p class="bm-empty"><mat-icon>lock_open</mat-icon> No encrypted secrets stored yet. A secret is created
            when you mark a variable secret, or when a connector wires a provider's password.</p>
        }
      } @else if (loading()) {
        <p class="bm-dim">Loading…</p>
      } @else if (error()) {
        <p class="bm-err">{{ error() }}</p>
      }
    </div>
  `,
  styles: [`
    .bm-page { padding: 20px 24px; max-width: 980px; }
    .bm-vault-head { display: flex; align-items: center; justify-content: space-between; }
    .bm-vault-head h1 { display: flex; align-items: center; gap: 8px; }
    .bm-dim { opacity: 0.7; font-size: 13px; max-width: 760px; line-height: 1.5; }
    .bm-err { color: var(--mat-sys-error, #c62828); }
    .bm-vault-stats { display: flex; gap: 8px; margin: 14px 0; flex-wrap: wrap; }
    .bm-chip { font-size: 12px; padding: 3px 10px; border-radius: 20px; border: 1px solid var(--mat-sys-outline-variant); }
    .bm-chip-src { text-transform: capitalize; opacity: 0.85; }
    .bm-vault-tbl { width: 100%; border-collapse: collapse; font-size: 13px; }
    .bm-vault-tbl th { text-align: left; font-weight: 600; opacity: 0.6; padding: 6px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-vault-tbl td { padding: 6px 8px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 50%, transparent); }
    .bm-mono { font-family: ui-monospace, monospace; }
    .bm-masked { opacity: 0.5; }
    .bm-src-tag { font-size: 11px; padding: 1px 8px; border-radius: 20px; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); }
    .bm-src-tag[data-src="scope-var"] { color: #42a5f5; }
    .bm-src-tag[data-src="config-policy"] { color: #ab47bc; }
    .bm-empty { display: flex; align-items: center; gap: 8px; opacity: 0.7; margin-top: 18px; }
  `],
})
export class VaultComponent implements OnInit {
  private http = inject(HttpClient);
  inv = signal<VaultInventory | null>(null);
  loading = signal(false);
  error = signal('');

  sources(v: VaultInventory): [string, number][] { return Object.entries(v.by_source); }

  ngOnInit(): void { this.load(); }
  load(): void {
    this.loading.set(true); this.error.set('');
    this.http.get<VaultInventory>(`${environment.apiUrl}/vault/secrets`).subscribe({
      next: (v) => { this.inv.set(v); this.loading.set(false); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'Failed to load the vault inventory.'); this.loading.set(false); },
    });
  }
}
