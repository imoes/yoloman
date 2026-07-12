import { Component, computed, inject, input, signal } from '@angular/core';
import { lastValueFrom, Observable } from 'rxjs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { StorageResponse } from '../../../core/models/agent.model';
import { ConfigDialogService } from '../../../shared/config-dialog/config-dialog.service';
import { UsageBarComponent, fmtBytes } from '../../../shared/config-dialog/usage-bar.component';
import { FieldValues } from '../../../shared/config-dialog/config-dialog.types';

/** A flattened lsblk device row carrying its nesting depth. */
interface DevRow {
  name: string;
  path: string;
  type: string;
  size: number;
  fstype?: string;
  mountpoint?: string;
  fssize?: number;
  fsused?: number;
  depth: number;
}

/** Block J4d, Cockpit-adaptation — the Storage section rebuilt like Cockpit's
 * storaged (../cockpit/pkg/storaged): a single hierarchical device table
 * (disk → partition → LVM → filesystem) with per-filesystem usage bars, and
 * per-object kebab actions (Format, Mount/Unmount, Create/Delete partition,
 * partition table) that open pre-filled dialogs on the shared config-dialog
 * framework — replacing the old shared free-text forms and confirm()/prompt().
 * LVM volume groups keep their capacity bar; create-VG/LV and LV resize/delete
 * are framework dialogs (SizeSlider + selectSpaces). */
@Component({
  selector: 'app-host-storage',
  standalone: true,
  imports: [MatButtonModule, MatIconModule, MatMenuModule, MatProgressSpinnerModule, UsageBarComponent],
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

        <!-- Storage: one hierarchical device table (Cockpit's overview) -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Storage</h3>
            @if (!s.block_devices.available) { <span class="bm-na">unavailable</span> }
            <span class="bm-spacer"></span>
            <button mat-icon-button [matMenuTriggerFor]="createMenu" [disabled]="busy()" title="Create storage device"><mat-icon>add</mat-icon></button>
            <mat-menu #createMenu="matMenu">
              <button mat-menu-item (click)="createVg()"><mat-icon>dns</mat-icon> Create LVM volume group</button>
              <button mat-menu-item (click)="createZpool()"><mat-icon>waves</mat-icon> Create ZFS pool</button>
              <button mat-menu-item (click)="wizard()"><mat-icon>auto_awesome</mat-icon> Create storage (thin/VDO/ZFS)…</button>
            </mat-menu>
          </header>
          @if (s.block_devices.available) {
            <table class="bm-ct">
              <thead><tr><th>Device</th><th>Type</th><th>Size</th><th>Usage / mount</th><th></th></tr></thead>
              <tbody>
                @for (d of rows(); track d.path) {
                  <tr>
                    <td class="bm-dev" [style.padding-left.px]="14 + d.depth * 20">
                      <mat-icon class="bm-dev-ic">{{ devIcon(d) }}</mat-icon>{{ d.name }}
                    </td>
                    <td><span class="bm-type">{{ d.fstype || d.type }}</span></td>
                    <td class="bm-mono">{{ bytes(d.size) }}</td>
                    <td>
                      @if (d.mountpoint && d.fssize) {
                        <app-usage-bar [used]="d.fsused || 0" [total]="d.fssize" [critical]="0.95" [short]="true" />
                        <span class="bm-mnt">{{ d.mountpoint }}</span>
                      } @else if (d.mountpoint) {
                        <span class="bm-chip">{{ d.mountpoint }}</span>
                      } @else { <span class="bm-muted">—</span> }
                    </td>
                    <td class="bm-right">
                      <button mat-icon-button [matMenuTriggerFor]="devMenu" [disabled]="busy()"><mat-icon>more_vert</mat-icon></button>
                      <mat-menu #devMenu="matMenu">
                        @if (d.type === 'disk') {
                          <button mat-menu-item (click)="createPartTable(d)"><mat-icon>grid_on</mat-icon> Create partition table…</button>
                          <button mat-menu-item (click)="createPartition(d)"><mat-icon>add_box</mat-icon> Create partition…</button>
                        }
                        @if (d.type === 'part' || d.type === 'lvm' || d.type === 'crypt') {
                          <button mat-menu-item (click)="format(d)"><mat-icon>build</mat-icon> Format…</button>
                          @if (d.mountpoint) {
                            <button mat-menu-item (click)="unmount(d)"><mat-icon>eject</mat-icon> Unmount</button>
                          } @else {
                            <button mat-menu-item (click)="mount(d)"><mat-icon>save</mat-icon> Mount…</button>
                          }
                        }
                        @if (d.type === 'part') {
                          <button mat-menu-item class="bm-danger" (click)="deletePartition(d)"><mat-icon>delete</mat-icon> Delete partition</button>
                        }
                      </mat-menu>
                    </td>
                  </tr>
                }
                @if (!rows().length) { <tr><td colspan="5" class="bm-empty">No storage found.</td></tr> }
              </tbody>
            </table>
          }
        </section>

        <!-- LVM volume groups (with capacity bars + object-bound LV actions) -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Volume groups (LVM)</h3>
            @if (!s.lvm.available) { <span class="bm-na">unavailable</span> }
          </header>
          @if (s.lvm.available) {
            @for (vg of s.lvm.vgs || []; track vg.vg_name) {
              <div class="bm-vg">
                <div class="bm-vg-top">
                  <span class="bm-dev"><mat-icon class="bm-dev-ic">dns</mat-icon>{{ vg.vg_name }}</span>
                  <span class="bm-spacer"></span>
                  <span class="bm-vg-cap">{{ bytes(usedBytes(vg)) }} / {{ bytes(num(vg.vg_size)) }} used</span>
                  <button mat-icon-button [matMenuTriggerFor]="vgMenu" [disabled]="busy()"><mat-icon>more_vert</mat-icon></button>
                  <mat-menu #vgMenu="matMenu">
                    <button mat-menu-item (click)="createLv(vg.vg_name, num(vg.vg_free))"><mat-icon>add</mat-icon> Create logical volume…</button>
                    <button mat-menu-item (click)="pvresizeVg(vg.vg_name)"><mat-icon>open_in_full</mat-icon> Grow VG (resize PVs)</button>
                    <button mat-menu-item class="bm-danger" (click)="deleteVg(vg.vg_name)"><mat-icon>delete</mat-icon> Delete volume group</button>
                  </mat-menu>
                </div>
                <div class="bm-bar"><span class="bm-bar-fill" [style.width.%]="usedPct(vg)" [class.bm-bar-warn]="usedPct(vg) >= 80" [class.bm-bar-crit]="usedPct(vg) >= 90"></span></div>
                @if (lvsOf(s, vg.vg_name).length) {
                  <table class="bm-ct bm-lv-t">
                    <tbody>
                      @for (lv of lvsOf(s, vg.vg_name); track lv.lv_name) {
                        <tr>
                          <td class="bm-dev bm-lv-name"><mat-icon class="bm-dev-ic">layers</mat-icon>{{ lv.lv_name }}</td>
                          <td class="bm-right bm-mono">{{ bytes(num(lv.lv_size)) }}</td>
                          <td class="bm-right">
                            <button mat-icon-button [matMenuTriggerFor]="lvMenu" [disabled]="busy()"><mat-icon>more_vert</mat-icon></button>
                            <mat-menu #lvMenu="matMenu">
                              <button mat-menu-item (click)="resizeLv(vg.vg_name, lv.lv_name, num(lv.lv_size), num(vg.vg_free))"><mat-icon>open_in_full</mat-icon> Resize…</button>
                              <button mat-menu-item class="bm-danger" (click)="deleteLv(vg.vg_name, lv.lv_name)"><mat-icon>delete</mat-icon> Delete</button>
                            </mat-menu>
                          </td>
                        </tr>
                      }
                    </tbody>
                  </table>
                }
              </div>
            }
            @if (!(s.lvm.vgs || []).length) { <p class="bm-empty">No volume groups.</p> }
          }
        </section>

        <!-- ZFS: always listed (even without tooling/pools) so it's discoverable. -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>ZFS pools</h3>
            @if (!s.zfs.available) { <span class="bm-na">zfs tooling not installed</span> }
            <span class="bm-spacer"></span>
            <button mat-icon-button (click)="createZpool()" [disabled]="busy()" title="Create ZFS pool"><mat-icon>add</mat-icon></button>
          </header>
          @if ((s.zfs.pools || []).length) {
            <table class="bm-ct">
              <tbody>
                @for (p of s.zfs.pools || []; track $index) {
                  <tr>
                    <td class="bm-dev"><mat-icon class="bm-dev-ic">waves</mat-icon>{{ p.name || p }}</td>
                    <td class="bm-right">
                      <button mat-icon-button [matMenuTriggerFor]="zpMenu" [disabled]="busy()"><mat-icon>more_vert</mat-icon></button>
                      <mat-menu #zpMenu="matMenu">
                        <button mat-menu-item (click)="createDataset(p.name || p)"><mat-icon>add</mat-icon> Create dataset…</button>
                      </mat-menu>
                    </td>
                  </tr>
                }
              </tbody>
            </table>
          } @else {
            <p class="bm-empty">No ZFS pools. Use “Create ZFS pool” to make one from free devices.</p>
          }
        </section>
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
      .bm-dev { font-family: monospace; font-weight: 600; display: flex; align-items: center; gap: 6px; }
      .bm-dev-ic { font-size: 17px; width: 17px; height: 17px; opacity: 0.6; }
      .bm-mono { font-family: monospace; font-variant-numeric: tabular-nums; }
      .bm-type { font-size: 11.5px; padding: 1px 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
      .bm-chip { display: inline-block; font-family: monospace; font-size: 12px; padding: 1px 8px; border-radius: 6px; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
      .bm-mnt { font-family: monospace; font-size: 11.5px; opacity: 0.7; margin-left: 8px; }
      .bm-muted { opacity: 0.5; }
      .bm-vg { padding: 12px 14px; border-top: 1px solid var(--mat-sys-outline-variant); }
      .bm-vg:first-of-type { border-top: none; }
      .bm-vg-top { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
      .bm-vg-cap { font-size: 12px; opacity: 0.7; font-variant-numeric: tabular-nums; }
      .bm-bar { height: 8px; border-radius: 999px; background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); overflow: hidden; }
      .bm-bar-fill { display: block; height: 100%; background: var(--bm-green, #2e7d32); border-radius: 999px; }
      .bm-bar-fill.bm-bar-warn { background: var(--bm-gold, #caa300); }
      .bm-bar-fill.bm-bar-crit { background: var(--bm-red, #d32f2f); }
      .bm-lv-t { margin-top: 8px; }
      .bm-lv-t td { border-top: 1px dashed var(--mat-sys-outline-variant); padding: 4px 0; }
      .bm-lv-name { font-weight: 500; opacity: 0.9; padding-left: 12px; }
      .bm-empty { opacity: 0.6; padding: 10px 14px; font-size: 13px; }
      .bm-chk { font-size: 12.5px; opacity: 0.85; display: flex; align-items: center; gap: 5px; }
      .bm-danger { color: #c62828; }
      .bm-svc-ok { color: var(--bm-green, #2e7d32); font-size: 12px; }
      .bm-svc-err { color: #c62828; font-size: 12px; }
    `,
  ],
})
export class HostStorageComponent {
  private agentService = inject(AgentService);
  private dialogs = inject(ConfigDialogService);

  agentId = input.required<string>();

  data = signal<StorageResponse | null>(null);
  dryRun = signal(true);
  loading = signal(false);
  loaded = signal(false);
  loadErr = signal<string | null>(null);
  busy = signal(false);
  msg = signal<string | null>(null);
  err = signal<string | null>(null);

  /** Flatten the lsblk device tree (children) into indented rows. */
  rows = computed<DevRow[]>(() => {
    const out: DevRow[] = [];
    const walk = (nodes: any[], depth: number) => {
      for (const n of nodes || []) {
        out.push({
          name: n.name, path: n.path || `/dev/${n.name}`, type: n.type ?? '',
          size: this.num(n.size), fstype: n.fstype ?? undefined,
          mountpoint: n.mountpoint ?? (Array.isArray(n.mountpoints) ? n.mountpoints.filter(Boolean)[0] : undefined),
          fssize: n.fssize != null ? this.num(n.fssize) : undefined,
          fsused: n.fsused != null ? this.num(n.fsused) : undefined,
          depth,
        });
        if (n.children) walk(n.children, depth + 1);
      }
    };
    walk(this.data()?.block_devices.devices || [], 0);
    return out;
  });

  num(v: unknown): number { const n = Number(v); return isFinite(n) ? n : 0; }
  bytes(n: number): string { return fmtBytes(n); }

  devIcon(d: DevRow): string {
    if (d.type === 'disk') return 'storage';
    if (d.type === 'lvm') return 'layers';
    if (d.type === 'crypt') return 'lock';
    if (d.fstype) return 'folder';
    return 'subdirectory_arrow_right';
  }

  usedBytes(vg: { vg_size?: unknown; vg_free?: unknown }): number {
    return Math.max(0, this.num(vg.vg_size) - this.num(vg.vg_free));
  }
  usedPct(vg: { vg_size?: unknown; vg_free?: unknown }): number {
    const size = this.num(vg.vg_size);
    return size > 0 ? Math.min(100, Math.round((this.usedBytes(vg) / size) * 100)) : 0;
  }
  lvsOf(s: StorageResponse, vgName: string): { lv_name: string; vg_name: string; lv_size: unknown }[] {
    return (s.lvm.lvs || []).filter((lv: { vg_name?: string }) => lv.vg_name === vgName);
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

  /** Run a write-gated tool through the config-dialog action contract: returns
   * a promise that resolves on success (dialog closes) or rejects with the
   * error detail (surfaced in the dialog). Honors the page-level dry-run. */
  private tool(name: string, params: Record<string, unknown>) {
    return this.agentService.callTool(this.agentId(), name, { ...params, dry_run: this.dryRun() });
  }

  private applied(r: unknown): void {
    if (r) { this.msg.set(this.dryRun() ? 'previewed (dry-run)' : 'applied'); if (!this.dryRun()) this.reload(); }
  }

  // ---- object-bound device dialogs (via the framework) ----

  format(d: DevRow): void {
    this.dialogs
      .open({
        title: `Format ${d.name}`,
        danger: 'Formatting erases all data on the device.',
        dangerButton: true,
        fields: [
          { tag: 'fstype', title: 'Type', type: 'select', initial: 'ext4',
            choices: ['xfs', 'ext4', 'btrfs', 'vfat', 'ntfs', 'swap'].map((t) => ({ value: t, title: t })) },
          { tag: 'mount', title: 'Mount point', type: 'text', placeholder: '/mnt/data (optional)', visible: (v) => v['fstype'] !== 'swap' },
        ],
        variants: [
          { title: 'Format only', variant: 'format' },
          { title: 'Format and mount', variant: 'mount', primary: true },
        ],
        action: (v, variant) => this.doFormat(d, v, variant),
      })
      .subscribe((r) => this.applied(r));
  }

  private async doFormat(d: DevRow, v: FieldValues, variant?: string) {
    const fstype = String(v['fstype']);
    await lastValue(this.tool('community.general.filesystem', { fstype, dev: d.path }));
    const mp = String(v['mount'] || '').trim();
    if (variant === 'mount' && mp && fstype !== 'swap') {
      await lastValue(this.tool('posix.mount', { path: mp, src: d.path, fstype, state: 'mounted' }));
    }
    return true;
  }

  mount(d: DevRow): void {
    this.dialogs
      .open({
        title: `Mount ${d.name}`,
        fields: [
          { tag: 'path', title: 'Mount point', type: 'text', placeholder: '/mnt/data',
            validate: (val) => (String(val || '').trim().startsWith('/') ? null : 'Absolute path required') },
          { tag: 'fstype', title: 'Filesystem', type: 'select', initial: d.fstype || 'auto',
            choices: ['auto', 'xfs', 'ext4', 'btrfs', 'vfat', 'ntfs'].map((t) => ({ value: t, title: t })) },
        ],
        action: (v) => this.tool('posix.mount', { path: String(v['path']).trim(), src: d.path, fstype: String(v['fstype']), state: 'mounted' }),
      })
      .subscribe((r) => this.applied(r));
  }

  unmount(d: DevRow): void {
    if (!d.mountpoint) return;
    this.busyRun(this.tool('posix.mount', { path: d.mountpoint, state: 'unmounted' }), `unmounted ${d.mountpoint}`);
  }

  createPartTable(d: DevRow): void {
    this.dialogs
      .open({
        title: `Create partition table on ${d.name}`,
        danger: 'Initializing erases all data on the disk.',
        dangerButton: true,
        fields: [
          { tag: 'label', title: 'Type', type: 'radio', initial: 'gpt',
            choices: [
              { value: 'gpt', title: 'GPT', explanation: 'Modern systems and disks > 2 TB' },
              { value: 'msdos', title: 'MBR (msdos)', explanation: 'Compatible with all systems' },
            ] },
        ],
        submitLabel: 'Initialize',
        action: (v) => this.tool('community.general.parted', { device: d.path, label: String(v['label']), state: 'present' }),
      })
      .subscribe((r) => this.applied(r));
  }

  createPartition(d: DevRow): void {
    this.dialogs
      .open({
        title: `Create partition on ${d.name}`,
        fields: [
          { tag: 'number', title: 'Number', type: 'text', initial: '1', validate: (v) => (/^\d+$/.test(String(v || '')) ? null : 'Number required') },
          { tag: 'start', title: 'Start', type: 'text', initial: '0%' },
          { tag: 'end', title: 'End', type: 'text', initial: '100%' },
          { tag: 'label', title: 'Table type (if none)', type: 'select', initial: 'gpt', choices: [{ value: 'gpt', title: 'gpt' }, { value: 'msdos', title: 'msdos' }] },
        ],
        submitLabel: 'Create',
        action: (v) => this.tool('community.general.parted', {
          device: d.path, number: Number(v['number']), label: String(v['label']),
          part_start: String(v['start'] || '0%'), part_end: String(v['end'] || '100%'), state: 'present',
        }),
      })
      .subscribe((r) => this.applied(r));
  }

  deletePartition(d: DevRow): void {
    // Partition number is the trailing digits of the name (e.g. sdb1 -> 1).
    const m = d.name.match(/(\d+)$/);
    const number = m ? Number(m[1]) : 0;
    const parent = d.path.replace(/p?\d+$/, '');
    this.dialogs
      .open({
        title: `Delete ${d.name}`,
        danger: 'All data on this partition is lost.',
        dangerButton: true,
        fields: [{ tag: 'c', title: '', type: 'message', text: `Deletes partition #${number} on ${parent}.` }],
        submitLabel: 'Delete',
        action: () => this.tool('community.general.parted', { device: parent, number, state: 'absent' }),
      })
      .subscribe((r) => this.applied(r));
  }

  // ---- LVM dialogs ----

  createVg(): void {
    const spaces = this.rows().filter((d) => (d.type === 'disk' || d.type === 'part') && !d.mountpoint && !d.fstype)
      .map((d) => ({ value: d.path, title: d.path, size: d.size }));
    this.dialogs
      .open({
        title: 'Create volume group',
        fields: [
          { tag: 'name', title: 'Name', type: 'text', placeholder: 'vg0', validate: (v) => (String(v || '').trim() ? null : 'Name required') },
          { tag: 'pvs', title: 'Disks', type: 'selectSpaces', spaces, minSelected: 1, emptyWarning: 'Select at least one disk' },
        ],
        submitLabel: 'Create',
        action: (v) => this.tool('community.general.lvg', { vg: String(v['name']).trim(), pvs: (v['pvs'] as string[]).join(','), state: 'present' }),
      })
      .subscribe((r) => this.applied(r));
  }

  deleteVg(vg: string): void {
    this.dialogs
      .open({
        title: `Delete volume group ${vg}`,
        danger: 'Removes the group and its metadata.',
        dangerButton: true,
        fields: [{ tag: 'c', title: '', type: 'message', text: `Delete ${vg}?` }],
        submitLabel: 'Delete',
        action: () => this.tool('community.general.lvg', { vg, state: 'absent', force: true }),
      })
      .subscribe((r) => this.applied(r));
  }

  createLv(vg: string, freeBytes: number): void {
    this.dialogs
      .open({
        title: `Create logical volume in ${vg}`,
        fields: [
          { tag: 'name', title: 'Name', type: 'text', placeholder: 'data', validate: (v) => (String(v || '').trim() ? null : 'Name required') },
          { tag: 'size', title: 'Size', type: 'sizeSlider', min: 1024 * 1024, max: freeBytes || 1024 * 1024 * 1024, round: 4 * 1024 * 1024, initial: Math.min(freeBytes, 1024 * 1024 * 1024) },
        ],
        submitLabel: 'Create',
        action: (v) => this.tool('community.general.lvol', { vg, lv: String(v['name']).trim(), size: `${Math.round(this.num(v['size']) / (1024 * 1024))}M`, state: 'present' }),
      })
      .subscribe((r) => this.applied(r));
  }

  resizeLv(vg: string, lv: string, currentBytes: number, freeBytes: number): void {
    this.dialogs
      .open({
        title: `Resize ${vg}/${lv}`,
        fields: [
          { tag: 'size', title: 'New size', type: 'sizeSlider', min: 1024 * 1024, max: currentBytes + (freeBytes || 0), round: 4 * 1024 * 1024, initial: currentBytes },
        ],
        submitLabel: 'Resize',
        // resizefs → lvresize --resizefs, so the filesystem grows/shrinks with the LV.
        action: (v) => this.tool('community.general.lvol', { vg, lv, size: `${Math.round(this.num(v['size']) / (1024 * 1024))}M`, resizefs: true }),
      })
      .subscribe((r) => this.applied(r));
  }

  deleteLv(vg: string, lv: string): void {
    this.dialogs
      .open({
        title: `Delete ${vg}/${lv}`,
        danger: 'Data on the logical volume is lost.',
        dangerButton: true,
        fields: [{ tag: 'c', title: '', type: 'message', text: `Delete logical volume ${vg}/${lv}?` }],
        submitLabel: 'Delete',
        action: () => this.tool('community.general.lvol', { vg, lv, state: 'absent', force: true }),
      })
      .subscribe((r) => this.applied(r));
  }

  /** Grow a VG by resizing its PVs to fill their (enlarged) devices — via the
   * lvg module's pvresize option (not raw shell), non-destructive. */
  pvresizeVg(vg: string): void {
    this.dialogs
      .open({
        title: `Grow volume group — ${vg}`,
        fields: [{ tag: 'c', title: '', type: 'message', text: `Runs pvresize on ${vg}'s physical volumes so LVM uses the full size of the (grown) devices.` }],
        submitLabel: 'Resize PVs',
        action: () => this.tool('community.general.lvg', { vg, pvresize: true }),
      })
      .subscribe((r) => this.applied(r));
  }

  /** Create a ZFS pool from free devices (zpool create). */
  createZpool(): void {
    const spaces = this.rows().filter((d) => (d.type === 'disk' || d.type === 'part') && !d.mountpoint && !d.fstype)
      .map((d) => ({ value: d.path, title: d.path, size: d.size }));
    this.dialogs
      .open({
        title: 'Create ZFS pool',
        danger: 'The selected devices are wiped and added to the new pool.',
        dangerButton: true,
        fields: [
          { tag: 'name', title: 'Pool name', type: 'text', placeholder: 'tank', validate: (v) => (String(v || '').trim() ? null : 'Name required') },
          { tag: 'devs', title: 'Devices', type: 'selectSpaces', spaces, minSelected: 1, emptyWarning: 'Select at least one device' },
        ],
        submitLabel: 'Create pool',
        action: (v) => this.tool('shell', { cmd: `zpool create -f ${shq(String(v['name']).trim())} ${(v['devs'] as string[]).map(shq).join(' ')}` }),
      })
      .subscribe((r) => this.applied(r));
  }

  /** Create a dataset inside an existing ZFS pool (community.general.zfs). */
  createDataset(pool: string): void {
    this.dialogs
      .open({
        title: `Create dataset in ${pool}`,
        fields: [{ tag: 'name', title: 'Dataset name', type: 'text', placeholder: 'data', validate: (v) => (String(v || '').trim() ? null : 'Name required') }],
        submitLabel: 'Create',
        action: (v) => this.tool('community.general.zfs', { name: `${pool}/${String(v['name']).trim()}`, state: 'present' }),
      })
      .subscribe((r) => this.applied(r));
  }

  wizard(): void {
    this.dialogs
      .open({
        title: 'Create storage',
        fields: [
          { tag: 'kind', title: 'Backend', type: 'radio', initial: 'lvm-thin',
            choices: [
              { value: 'lvm-thin', title: 'LVM thin provisioning' },
              { value: 'vdo', title: 'VDO (dedup/compression)' },
              { value: 'zfs', title: 'ZFS pool + dataset' },
            ] },
          { tag: 'vg', title: 'Volume group', type: 'text', placeholder: 'vg0 (existing)', visible: (v) => v['kind'] === 'lvm-thin' },
          { tag: 'pool', title: 'Thin pool name', type: 'text', placeholder: 'thinpool', visible: (v) => v['kind'] === 'lvm-thin' },
          { tag: 'poolSize', title: 'Pool size', type: 'text', initial: '100%FREE', visible: (v) => v['kind'] === 'lvm-thin' },
          { tag: 'vdoName', title: 'VDO name', type: 'text', placeholder: 'vdo0', visible: (v) => v['kind'] === 'vdo' },
          { tag: 'vdoDev', title: 'Backing device', type: 'text', placeholder: '/dev/sdb', visible: (v) => v['kind'] === 'vdo' },
          { tag: 'zpool', title: 'Pool name', type: 'text', placeholder: 'tank', visible: (v) => v['kind'] === 'zfs' },
          { tag: 'zdevs', title: 'Devices (space-sep)', type: 'text', placeholder: '/dev/sdb /dev/sdc', visible: (v) => v['kind'] === 'zfs' },
        ],
        submitLabel: 'Create',
        action: (v) => this.doWizard(v),
      })
      .subscribe((r) => this.applied(r));
  }

  private async doWizard(v: FieldValues) {
    const kind = v['kind'];
    if (kind === 'lvm-thin') {
      await lastValue(this.tool('community.general.lvol', { vg: String(v['vg']).trim(), thinpool: String(v['pool']).trim(), size: String(v['poolSize'] || '100%FREE') }));
    } else if (kind === 'vdo') {
      await lastValue(this.tool('community.general.vdo', { name: String(v['vdoName']).trim(), device: String(v['vdoDev']).trim(), state: 'present' }));
    } else {
      await lastValue(this.tool('shell', { cmd: `zpool create -f ${shq(String(v['zpool']).trim())} ${String(v['zdevs']).trim()}` }));
    }
    return true;
  }

  private busyRun(obs: any, ok: string): void {
    this.busy.set(true);
    this.msg.set(null);
    this.err.set(null);
    obs.subscribe({
      next: () => { this.busy.set(false); this.msg.set(`${ok}${this.dryRun() ? ' (dry-run)' : ''}`); if (!this.dryRun()) this.reload(); },
      error: (e: any) => { this.busy.set(false); this.err.set(e?.error?.detail ?? 'action failed'); },
    });
  }
}

function lastValue(o: Observable<unknown>): Promise<unknown> { return lastValueFrom(o); }
function shq(v: string): string { return "'" + v.replace(/'/g, "'\\''") + "'"; }
