import { Component, computed, inject, input, signal } from '@angular/core';
import { lastValueFrom, Observable } from 'rxjs';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { AgentService } from '../../../core/services/agent.service';
import { ConfigResource, StorageResponse } from '../../../core/models/agent.model';

/** One /etc/fstab mount line, decoded via the fstab codec. */
interface FstabEntry { device: string; mountpoint: string; fstype: string; options: string; dump: string; pass: string; }
import { ConfigDialogService } from '../../../shared/config-dialog/config-dialog.service';
import { UsageBarComponent, fmtBytes } from '../../../shared/config-dialog/usage-bar.component';
import { FieldValues } from '../../../shared/config-dialog/config-dialog.types';
import { HostDisksComponent } from '../host-disks.component';

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
  imports: [MatButtonModule, MatIconModule, MatMenuModule, MatProgressSpinnerModule, UsageBarComponent, HostDisksComponent],
  template: `
    <div class="bm-mgmt-section">
      @if (loading()) {
        <div class="bm-mgmt-loading"><mat-spinner diameter="28" /></div>
      } @else if (loadErr()) {
        <p class="bm-svc-err">{{ loadErr() }}</p>
      } @else if (data(); as s) {
        @if (msg() || err()) {
          <div class="bm-topbar">
            <span class="bm-spacer"></span>
            @if (msg()) { <span class="bm-svc-ok">{{ msg() }}</span> }
            @if (err()) { <span class="bm-svc-err">{{ err() }}</span> }
          </div>
        }

        <!-- The partition editor IS the Storage snapin now: visual disk + a
             selection-driven toolbar + a staged op queue, covering disks,
             partitions, LVM and ZFS (docs/disk-management.md). It replaced the
             old lsblk device table and the LVM/ZFS cards; /etc/fstab stays below. -->
        <app-host-disks [agentId]="agentId()" />


        <!-- /etc/fstab: the columnar mount table, decoded via the fstab codec
             and edited as values — applied through state/apply (versioned +
             roll-backable). Dry run only affects THIS card now (the partition
             editor above has its own Preview/Apply), so the toggle lives here. -->
        <section class="bm-card">
          <header class="bm-card-head"><h3>Mounts (/etc/fstab)</h3>
            @if (!fstabAvail()) { <span class="bm-na">unavailable</span> }
            <span class="bm-spacer"></span>
            @if (fstabMsg()) { <span class="bm-svc-ok">{{ fstabMsg() }}</span> }
            @if (fstabErr()) { <span class="bm-svc-err">{{ fstabErr() }}</span> }
            <label class="bm-chk" title="Preview the rendered /etc/fstab instead of writing it">
              <input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> Dry run</label>
            <button mat-icon-button (click)="reload()" [disabled]="loading()" title="Reload"><mat-icon>refresh</mat-icon></button>
            <button mat-stroked-button (click)="addMount()" [disabled]="busy() || !fstabAvail()"><mat-icon>add</mat-icon> Add mount</button>
            <button mat-flat-button color="primary" (click)="saveFstab()" [disabled]="busy() || !fstabDirty()">{{ dryRun() ? 'Preview' : 'Apply' }}</button>
          </header>
          @if (fstabAvail()) {
            <table class="bm-ct bm-fstab">
              <thead><tr><th>Device / source</th><th>Mount point</th><th>Type</th><th>Options</th><th>Dump</th><th>Pass</th><th></th></tr></thead>
              <tbody>
                @for (e of fstab(); track $index) {
                  <tr>
                    <td><input class="bm-fi bm-fi-wide" [value]="e.device" (input)="setFstab($index, 'device', $any($event.target).value)" /></td>
                    <td><input class="bm-fi" [value]="e.mountpoint" (input)="setFstab($index, 'mountpoint', $any($event.target).value)" /></td>
                    <td><input class="bm-fi bm-fi-sm" [value]="e.fstype" (input)="setFstab($index, 'fstype', $any($event.target).value)" /></td>
                    <td><input class="bm-fi bm-fi-wide" [value]="e.options" (input)="setFstab($index, 'options', $any($event.target).value)" /></td>
                    <td><input class="bm-fi bm-fi-xs" [value]="e.dump" (input)="setFstab($index, 'dump', $any($event.target).value)" /></td>
                    <td><input class="bm-fi bm-fi-xs" [value]="e.pass" (input)="setFstab($index, 'pass', $any($event.target).value)" /></td>
                    <td class="bm-right"><button mat-icon-button class="bm-danger" (click)="removeMount($index)" [disabled]="busy()"><mat-icon>delete</mat-icon></button></td>
                  </tr>
                }
                @if (!fstab().length) { <tr><td colspan="7" class="bm-empty">No fstab entries.</td></tr> }
              </tbody>
            </table>
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
      .bm-fstab td { padding: 5px 8px; }
      .bm-fi { width: 100%; box-sizing: border-box; font-family: monospace; font-size: 12px; padding: 4px 6px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 5px; background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
      .bm-fi:focus { outline: none; border-color: var(--mat-sys-primary); }
      .bm-fi-wide { min-width: 180px; }
      .bm-fi-sm { min-width: 64px; }
      .bm-fi-xs { width: 48px; text-align: center; }
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

  // /etc/fstab mount table (decoded via the fstab codec on the agent).
  fstab = signal<FstabEntry[]>([]);
  fstabAvail = signal(false);
  fstabDirty = signal(false);
  fstabMsg = signal<string | null>(null);
  fstabErr = signal<string | null>(null);

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
    this.loadFstab();
  }

  /** Load /etc/fstab from the observed state (decoded to entries by the fstab
   * codec). Best-effort: an older agent / missing codec just hides the panel. */
  private loadFstab(): void {
    this.fstabMsg.set(null);
    this.fstabErr.set(null);
    this.agentService.observedState(this.agentId()).subscribe({
      next: (res) => {
        const cfg = (res?.observed?.config ?? []).find((c) => c.path === '/etc/fstab');
        const raw = (cfg?.values as { entries?: unknown[] } | undefined)?.entries;
        if (cfg?.format === 'fstab' && Array.isArray(raw)) {
          this.fstab.set(raw.map((e) => this.normEntry(e as Record<string, unknown>)));
          this.fstabAvail.set(true);
        } else {
          this.fstabAvail.set(false);
        }
        this.fstabDirty.set(false);
      },
      error: () => { this.fstabAvail.set(false); },
    });
  }

  private normEntry(e: Record<string, unknown>): FstabEntry {
    const s = (k: string, d = '') => (e[k] == null ? d : String(e[k]));
    return { device: s('device'), mountpoint: s('mountpoint'), fstype: s('fstype'), options: s('options', 'defaults'), dump: s('dump', '0'), pass: s('pass', '0') };
  }

  setFstab(i: number, key: keyof FstabEntry, value: string): void {
    this.fstab.update((rows) => rows.map((r, idx) => (idx === i ? { ...r, [key]: value } : r)));
    this.fstabDirty.set(true);
  }

  addMount(): void {
    this.fstab.update((rows) => [...rows, { device: '', mountpoint: '', fstype: 'ext4', options: 'defaults', dump: '0', pass: '0' }]);
    this.fstabDirty.set(true);
  }

  removeMount(i: number): void {
    this.fstab.update((rows) => rows.filter((_, idx) => idx !== i));
    this.fstabDirty.set(true);
  }

  /** Apply the edited mount table via the fstab codec (state/apply — versioned
   * + roll-backable), honoring the Dry-run toggle. */
  saveFstab(): void {
    this.busy.set(true);
    this.fstabMsg.set(null);
    this.fstabErr.set(null);
    const resource: ConfigResource = {
      type: 'config', path: '/etc/fstab', format: 'fstab',
      values: { entries: this.fstab() },
    };
    this.agentService.stateApply(this.agentId(), [resource], this.dryRun()).subscribe({
      next: () => {
        this.busy.set(false);
        this.fstabMsg.set(this.dryRun() ? 'previewed (dry-run)' : 'applied');
        if (!this.dryRun()) { this.fstabDirty.set(false); this.loadFstab(); }
      },
      error: (e) => { this.busy.set(false); this.fstabErr.set(e?.error?.detail ?? 'apply failed'); },
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
