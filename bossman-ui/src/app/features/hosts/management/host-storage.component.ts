import { Component, computed, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { StorageResponse } from '../../../core/models/agent.model';

/** Block J4d — the Storage section: a read-only overview (block devices, LVM,
 * VDO, ZFS) from storage_facts + zpool_facts, plus the common LVM write actions
 * (create VG/LV) through the baked community.general modules via the fleet
 * tool router. Destructive actions default to dry-run. Sections whose tooling
 * is absent render as "unavailable" instead of erroring the whole page. */
@Component({
  selector: 'app-host-storage',
  standalone: true,
  imports: [MatButtonModule, MatProgressSpinnerModule],
  template: `
    <div class="bm-mgmt-section">
      <div class="bm-mgmt-toolbar">
        <button mat-stroked-button (click)="reload()" [disabled]="loading()">Reload</button>
        <label class="bm-chk"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
        @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
        @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
      </div>

      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as s) {
        <!-- LVM -->
        <h4>LVM @if (!s.lvm.available) { <span class="bm-na">unavailable</span> }</h4>
        @if (s.lvm.available) {
          <div class="bm-stor-tables">
            <div>
              <div class="bm-stor-h">Volume groups</div>
              <table class="bm-mgmt-table"><thead><tr><th>VG</th><th>Size</th><th>Free</th></tr></thead><tbody>
                @for (vg of s.lvm.vgs || []; track vg.vg_name) { <tr><td class="bm-mgmt-unit">{{ vg.vg_name }}</td><td>{{ human(vg.vg_size) }}</td><td>{{ human(vg.vg_free) }}</td></tr> }
              </tbody></table>
            </div>
            <div>
              <div class="bm-stor-h">Logical volumes</div>
              <table class="bm-mgmt-table"><thead><tr><th>LV</th><th>VG</th><th>Size</th></tr></thead><tbody>
                @for (lv of s.lvm.lvs || []; track lv.lv_name) { <tr><td class="bm-mgmt-unit">{{ lv.lv_name }}</td><td>{{ lv.vg_name }}</td><td>{{ human(lv.lv_size) }}</td></tr> }
              </tbody></table>
            </div>
          </div>
          <div class="bm-stor-forms">
            <div class="bm-acct-new">
              <input type="text" placeholder="new VG name" [value]="vgName()" (input)="vgName.set($any($event.target).value)" />
              <input type="text" placeholder="PVs (space-sep, e.g. /dev/sdb)" [value]="vgPvs()" (input)="vgPvs.set($any($event.target).value)" />
              <button mat-button (click)="createVg()" [disabled]="busy() || !vgName().trim() || !vgPvs().trim()">Create VG</button>
            </div>
            <div class="bm-acct-new">
              <input type="text" placeholder="VG" [value]="lvVg()" (input)="lvVg.set($any($event.target).value)" />
              <input type="text" placeholder="LV name" [value]="lvName()" (input)="lvName.set($any($event.target).value)" />
              <input type="text" placeholder="size (e.g. 1G)" [value]="lvSize()" (input)="lvSize.set($any($event.target).value)" />
              <button mat-button (click)="createLv()" [disabled]="busy() || !lvVg().trim() || !lvName().trim() || !lvSize().trim()">Create LV</button>
            </div>
          </div>
        }

        <!-- ZFS -->
        <h4>ZFS @if (!s.zfs.available) { <span class="bm-na">unavailable</span> }</h4>
        @if (s.zfs.available) {
          <table class="bm-mgmt-table"><thead><tr><th>Pool</th></tr></thead><tbody>
            @for (p of s.zfs.pools || []; track $index) { <tr><td class="bm-mgmt-unit">{{ p.name || p }}</td></tr> }
          </tbody></table>
        }

        <!-- VDO -->
        <h4>VDO @if (!s.vdo.available) { <span class="bm-na">unavailable</span> }</h4>
        @if (s.vdo.available) {
          <pre class="bm-log-view">{{ (s.vdo.raw || []).join('\n') }}</pre>
        }

        <!-- Block devices -->
        <h4>Block devices @if (!s.block_devices.available) { <span class="bm-na">unavailable</span> }</h4>
        @if (s.block_devices.available) {
          <table class="bm-mgmt-table"><thead><tr><th>Name</th><th>Size</th><th>Type</th><th>Mountpoint</th></tr></thead><tbody>
            @for (d of s.block_devices.devices || []; track d.name) {
              <tr><td class="bm-mgmt-unit">{{ d.name }}</td><td>{{ d.size }}</td><td>{{ d.type }}</td><td>{{ d.mountpoint || d.mountpoints }}</td></tr>
            }
          </tbody></table>
        }
      }
    </div>
  `,
  styles: [
    `
      .bm-mgmt-section { padding: 8px 0; }
      .bm-mgmt-toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
      .bm-chk { font-size: 12px; color: var(--bm-muted, #888); display: flex; align-items: center; gap: 4px; }
      .bm-mgmt-loading { display: flex; justify-content: center; padding: 24px; }
      h4 { margin: 18px 0 6px; }
      .bm-na { color: var(--bm-muted, #999); font-size: 12px; font-weight: normal; }
      .bm-stor-tables { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
      @media (max-width: 900px) { .bm-stor-tables { grid-template-columns: 1fr; } }
      .bm-stor-h { font-size: 12px; color: var(--bm-muted, #888); margin-bottom: 4px; }
      .bm-stor-forms { margin-top: 10px; }
      .bm-acct-new { display: flex; gap: 8px; margin-bottom: 8px; flex-wrap: wrap; }
      .bm-acct-new input { flex: 1 1 120px; padding: 6px 8px; border: 1px solid var(--bm-border, #ccc); border-radius: 4px; }
      .bm-mgmt-table { width: 100%; border-collapse: collapse; font-size: 13px; margin-bottom: 6px; }
      .bm-mgmt-table th, .bm-mgmt-table td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--bm-border, #eee); }
      .bm-mgmt-unit { font-family: monospace; }
      .bm-log-view { max-height: 30vh; overflow: auto; background: var(--bm-code-bg, #1e1e1e); color: #d4d4d4; padding: 8px; border-radius: 6px; font-size: 12px; }
      .bm-svc-ok { color: #2e7d32; font-size: 12px; }
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

  /** LVM sizes come back in bytes (--units b --nosuffix); render human-ish. */
  human(v: unknown): string {
    const n = Number(v);
    if (!isFinite(n) || n <= 0) return String(v ?? '');
    const u = ['B', 'K', 'M', 'G', 'T', 'P'];
    let i = 0;
    let x = n;
    while (x >= 1024 && i < u.length - 1) {
      x /= 1024;
      i++;
    }
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
      next: (res) => {
        this.data.set(res);
        this.loading.set(false);
        this.loaded.set(true);
      },
      error: (e) => {
        this.loading.set(false);
        this.loaded.set(true);
        this.loadErr.set(e?.error?.detail ?? 'failed to load storage');
      },
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
      error: (e) => {
        this.busy.set(false);
        this.err.set(e?.error?.detail ?? 'action failed');
      },
    });
  }

  createVg(): void {
    this.run('community.general.lvg', { vg: this.vgName().trim(), pvs: this.vgPvs().trim(), state: 'present' }, `create VG ${this.vgName().trim()}`);
  }

  createLv(): void {
    this.run('community.general.lvol', { vg: this.lvVg().trim(), lv: this.lvName().trim(), size: this.lvSize().trim(), state: 'present' }, `create LV ${this.lvName().trim()}`);
  }
}
