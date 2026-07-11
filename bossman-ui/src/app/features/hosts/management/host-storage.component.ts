import { Component, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { StorageResponse } from '../../../core/models/agent.model';

/** Block J4d — the Storage section, redesigned in a RHEL-Cockpit style:
 * card-based, block devices as a drives table, LVM volume groups with a
 * used/free capacity bar (Cockpit's hallmark), and inline create-VG / create-LV
 * forms. Destructive actions default to dry-run; sections whose tooling is
 * absent render as "unavailable" instead of erroring the page. */
@Component({
  selector: 'app-host-storage',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as s) {
        <div class="bm-topbar">
          <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run (preview only)</label>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
          <button mat-stroked-button (click)="reload()" [disabled]="loading()"><mat-icon>refresh</mat-icon> Reload</button>
        </div>

        <!-- Drives / block devices -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Drives &amp; block devices</h3>
            @if (!s.block_devices.available) { <span class="bm-na">unavailable</span> }
          </header>
          @if (s.block_devices.available) {
            <table class="bm-ct">
              <thead><tr><th>Device</th><th>Size</th><th>Type</th><th>Mounted at</th></tr></thead>
              <tbody>
                @for (d of s.block_devices.devices || []; track d.name) {
                  <tr>
                    <td class="bm-dev"><mat-icon class="bm-dev-ic">{{ d.type === 'disk' ? 'storage' : 'subdirectory_arrow_right' }}</mat-icon>{{ d.name }}</td>
                    <td>{{ d.size }}</td>
                    <td><span class="bm-type">{{ d.type }}</span></td>
                    <td>@if (d.mountpoint || d.mountpoints) { <span class="bm-chip">{{ d.mountpoint || d.mountpoints }}</span> } @else { <span class="bm-muted">—</span> }</td>
                  </tr>
                }
              </tbody>
            </table>
          }
        </section>

        <!-- LVM volume groups (with capacity bars) -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Volume groups (LVM)</h3>
            @if (!s.lvm.available) { <span class="bm-na">unavailable</span> }
          </header>
          @if (s.lvm.available) {
            @for (vg of s.lvm.vgs || []; track vg.vg_name) {
              <div class="bm-vg">
                <div class="bm-vg-top">
                  <span class="bm-dev"><mat-icon class="bm-dev-ic">dns</mat-icon>{{ vg.vg_name }}</span>
                  <span class="bm-vg-cap">{{ human(usedBytes(vg)) }} / {{ human(vg.vg_size) }} used</span>
                </div>
                <div class="bm-bar"><span class="bm-bar-fill" [style.width.%]="usedPct(vg)" [class.bm-bar-warn]="usedPct(vg) >= 80" [class.bm-bar-crit]="usedPct(vg) >= 90"></span></div>
                @if (lvsOf(s, vg.vg_name).length) {
                  <table class="bm-ct bm-lv-t">
                    <tbody>
                      @for (lv of lvsOf(s, vg.vg_name); track lv.lv_name) {
                        <tr><td class="bm-dev bm-lv-name"><mat-icon class="bm-dev-ic">layers</mat-icon>{{ lv.lv_name }}</td><td class="bm-right">{{ human(lv.lv_size) }}</td></tr>
                      }
                    </tbody>
                  </table>
                }
              </div>
            }
            @if (!(s.lvm.vgs || []).length) { <p class="bm-empty">No volume groups.</p> }

            <div class="bm-forms">
              <div class="bm-inline-form">
                <mat-icon class="bm-dev-ic">add</mat-icon>
                <input type="text" placeholder="new VG name" [value]="vgName()" (input)="vgName.set($any($event.target).value)" />
                <input type="text" placeholder="PVs (space-sep, e.g. /dev/sdb)" [value]="vgPvs()" (input)="vgPvs.set($any($event.target).value)" />
                <button mat-stroked-button (click)="createVg()" [disabled]="busy() || !vgName().trim() || !vgPvs().trim()">Create VG</button>
              </div>
              <div class="bm-inline-form">
                <mat-icon class="bm-dev-ic">add</mat-icon>
                <input type="text" placeholder="VG" [value]="lvVg()" (input)="lvVg.set($any($event.target).value)" />
                <input type="text" placeholder="LV name" [value]="lvName()" (input)="lvName.set($any($event.target).value)" />
                <input type="text" placeholder="size (e.g. 1G)" [value]="lvSize()" (input)="lvSize.set($any($event.target).value)" />
                <button mat-stroked-button (click)="createLv()" [disabled]="busy() || !lvVg().trim() || !lvName().trim() || !lvSize().trim()">Create LV</button>
              </div>
            </div>
          }
        </section>

        <!-- ZFS / VDO (only meaningful when present) -->
        @if (s.zfs.available) {
          <section class="bm-card">
            <header class="bm-card-head"><h3>ZFS pools</h3></header>
            <table class="bm-ct"><tbody>
              @for (p of s.zfs.pools || []; track $index) { <tr><td class="bm-dev"><mat-icon class="bm-dev-ic">waves</mat-icon>{{ p.name || p }}</td></tr> }
            </tbody></table>
          </section>
        }
        @if (s.vdo.available) {
          <section class="bm-card">
            <header class="bm-card-head"><h3>VDO</h3></header>
            <pre class="bm-raw">{{ (s.vdo.raw || []).join('\n') }}</pre>
          </section>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 4px 0; display: flex; flex-direction: column; gap: 16px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      .bm-topbar { display: flex; align-items: center; gap: 12px; }
      .bm-spacer { flex: 1; }
      .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; background: var(--mat-sys-surface); }
      .bm-card-head { display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
      .bm-card-head h3 { margin: 0; font-size: 14px; font-weight: 600; }
      .bm-na { color: var(--mat-sys-on-surface); opacity: 0.5; font-size: 12px; }
      .bm-ct { width: 100%; border-collapse: collapse; font-size: 13px; }
      .bm-ct th { text-align: left; font-weight: 500; opacity: 0.6; padding: 6px 14px; font-size: 12px; }
      .bm-ct td { padding: 8px 14px; border-top: 1px solid var(--mat-sys-outline-variant); vertical-align: middle; }
      .bm-right { text-align: right; }
      .bm-dev { font-family: monospace; font-weight: 600; display: inline-flex; align-items: center; gap: 6px; }
      .bm-dev-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.6; }
      .bm-type { font-size: 11.5px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-chip { display: inline-block; font-family: monospace; font-size: 12px; padding: 1px 8px; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-muted { opacity: 0.5; }
      .bm-vg { padding: 12px 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-vg:first-of-type { border-top: none; }
      .bm-vg-top { display: flex; align-items: baseline; justify-content: space-between; margin-bottom: 6px; }
      .bm-vg-cap { font-size: 12px; opacity: 0.7; font-variant-numeric: tabular-nums; }
      .bm-bar { height: 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); overflow: hidden; }
      .bm-bar-fill { display: block; height: 100%; background: var(--bm-green, #2e7d32); border-radius: 999px; }
      .bm-bar-fill.bm-bar-warn { background: var(--bm-gold, #caa300); }
      .bm-bar-fill.bm-bar-crit { background: var(--bm-red, #d32f2f); }
      .bm-lv-t { margin-top: 8px; }
      .bm-lv-t td { border-top: 1px dashed var(--mat-sys-outline-variant); padding: 4px 0; }
      .bm-lv-name { font-weight: 500; opacity: 0.9; padding-left: 12px; }
      .bm-forms { padding: 10px 14px; border-top: 1px solid var(--mat-sys-outline-variant); display: flex; flex-direction: column; gap: 8px; }
      .bm-inline-form { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
      .bm-inline-form input { flex: 1 1 130px; padding: 6px 9px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 6px; background: var(--mat-sys-surface); color: inherit; }
      .bm-empty { opacity: 0.6; padding: 10px 14px; font-size: 13px; }
      .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
      .bm-raw { max-height: 30vh; overflow: auto; background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); padding: 10px 12px; border-radius: 6px; font-size: 12px; margin: 12px 14px; }
      .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostStorageComponent {
  private agentService = inject(AgentService);

  agentId = input.required<string>();

  data = signal<StorageResponse | null>(null);
  dryRun = signal(true);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  vgName = signal('');
  vgPvs = signal('');
  lvVg = signal('');
  lvName = signal('');
  lvSize = signal('');

  usedBytes(vg: { vg_size?: unknown; vg_free?: unknown }): number {
    return Math.max(0, Number(vg.vg_size) - Number(vg.vg_free));
  }
  usedPct(vg: { vg_size?: unknown; vg_free?: unknown }): number {
    const size = Number(vg.vg_size);
    if (!isFinite(size) || size <= 0) return 0;
    return Math.min(100, Math.round((this.usedBytes(vg) / size) * 100));
  }
  lvsOf(s: StorageResponse, vgName: string): { lv_name: string; vg_name: string; lv_size: unknown }[] {
    return (s.lvm.lvs || []).filter((lv: { vg_name?: string }) => lv.vg_name === vgName);
  }

  /** LVM sizes come back in bytes (--units b --nosuffix); render human-ish. */
  human(v: unknown): string {
    const n = Number(v);
    if (!isFinite(n) || n <= 0) return String(v ?? '0');
    const u = ['B', 'K', 'M', 'G', 'T', 'P'];
    let i = 0;
    let x = n;
    while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
    return x.toFixed(x < 10 && i > 0 ? 1 : 0) + u[i];
  }

  loadOnce(): void {
    if (this.loaded() || this.loading()) return;
    this.reload();
  }

  reload(): void {
    this.loading.set(true);
    this.loadErr.set(null);
    this.agentService.storage(this.agentId()).subscribe({
      next: (res) => { this.data.set(res); this.loading.set(false); this.loaded.set(true); },
      error: (e) => { this.loading.set(false); this.loaded.set(true); this.loadErr.set(e?.error?.detail ?? 'failed to load storage'); },
    });
  }

  private run(name: string, params: Record<string, unknown>, ok: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    this.agentService.callTool(this.agentId(), name, { ...params, dry_run: this.dryRun() }).subscribe({
      next: (res) => {
        this.busy.set(false);
        const r = res.result as { changed?: boolean; msg?: string } | undefined;
        this.msg.set(`${ok}: ${r?.msg ?? 'ok'}${this.dryRun() ? ' (dry-run)' : ''}`);
        if (!this.dryRun()) this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'action failed'); },
    });
  }

  createVg(): void {
    this.run('community.general.lvg', { vg: this.vgName().trim(), pvs: this.vgPvs().trim(), state: 'present' }, `create VG ${this.vgName().trim()}`);
  }

  createLv(): void {
    this.run('community.general.lvol', { vg: this.lvVg().trim(), lv: this.lvName().trim(), size: this.lvSize().trim(), state: 'present' }, `create LV ${this.lvName().trim()}`);
  }
}
