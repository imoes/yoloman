import { Component, computed, effect, inject, input, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { environment } from '../../../environments/environment';

interface Partition {
  name: string; path: string; kind: string; size_bytes: number | null;
  fstype: string | null; label: string | null; uuid: string | null;
  mountpoint: string | null; used_bytes: number | null; avail_bytes: number | null;
  flags: string[]; busy: boolean; start_s: number | null; end_s: number | null;
  children: Partition[];
}
interface FreeSeg { start_s: number | null; end_s: number | null; size_bytes: number | null; }
interface Device {
  name: string; path: string; size_bytes: number | null; model: string;
  rotational: boolean; transport: string | null; table: string | null;
  sector_size: number | null; partitions: Partition[]; free: FreeSeg[];
}
interface Vg { name: string; size_bytes: number | null; free_bytes: number | null; lvs: { name: string }[]; }
interface DiskLayout { devices: Device[]; vgs?: Vg[]; errors: string[]; }

interface DiskOp { op: string; device?: string; target?: string; table?: string; fstype?: string;
  start?: string; end?: string; ptype?: string; num?: number; label?: string; mountpoint?: string; size?: string;
  start_mib?: number; size_mib?: number; grow?: boolean; _desc: string; }
interface Seg { kind: 'part' | 'free'; label: string; pct: number; usedPct: number; color: string; title: string; }

/**
 * The host's Disks view (gparted-style): a visual bar + partition table per disk,
 * PLUS a staged operation queue (create table / partition / format / label / mount
 * / delete) applied in one go — the gparted comfort, over the agent. A scratch
 * loopback disk can be created for safe testing. See docs/disk-management.md.
 */
@Component({
  selector: 'app-host-disks',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-dk-head">
      <span class="bm-dim">Disks &amp; partitions (live). Stage operations, then Apply — like gparted, over the agent.</span>
      <span class="bm-dk-tools">
        <button mat-stroked-button (click)="addScratch()" [disabled]="busy()"><mat-icon>science</mat-icon> Scratch test disk</button>
        <button mat-stroked-button (click)="load()" [disabled]="busy()"><mat-icon>refresh</mat-icon> {{ loading() ? 'Scanning…' : 'Rescan' }}</button>
      </span>
    </div>

    @if (layout()?.errors?.length) {
      <div class="bm-dk-errs"><mat-icon>info</mat-icon><div>@for (e of layout()!.errors; track $index) { <div>{{ e }}</div> }</div></div>
    }

    @if (layout(); as l) {
      @for (d of l.devices; track d.path) {
        <div class="bm-dk-dev">
          <div class="bm-dk-dev-h">
            <mat-icon>{{ d.rotational ? 'album' : 'sd_card' }}</mat-icon>
            <strong>{{ d.path }}</strong>
            <span class="bm-dk-meta">{{ d.model || '—' }} · {{ fmt(d.size_bytes) }} · {{ d.table || 'no table' }}{{ d.rotational ? ' · HDD' : ' · SSD' }}</span>
            <span class="bm-dk-devacts">
              <button mat-button (click)="opMklabel(d, 'gpt')" [disabled]="protectedDev(d)" title="Create a new GPT partition table (wipes the disk)">Init GPT</button>
              <button mat-button (click)="opMklabel(d, 'msdos')" [disabled]="protectedDev(d)">Init MBR</button>
              <button mat-button (click)="opAddPartition(d)" [disabled]="protectedDev(d)"><mat-icon>add</mat-icon> Partition</button>
            </span>
          </div>

          <div class="bm-dk-bar" [title]="d.path">
            @for (s of segsFor(d); track $index) {
              <div class="bm-dk-seg" [class.free]="s.kind === 'free'" [style.width.%]="s.pct" [style.background]="s.color" [title]="s.title">
                @if (s.kind === 'part' && s.usedPct > 0) { <div class="bm-dk-used" [style.width.%]="s.usedPct"></div> }
                <span class="bm-dk-seg-lbl">{{ s.label }}</span>
              </div>
            }
          </div>

          <table class="bm-dk-tbl">
            <thead><tr><th>Partition</th><th>FS</th><th>Label</th><th>Size</th><th>Used</th><th>Avail</th><th>Mount</th><th>Flags</th><th></th></tr></thead>
            <tbody>
              @for (p of flatten(d.partitions); track p.row.path) {
                <tr>
                  <td class="bm-dk-mono" [style.paddingLeft.px]="8 + p.depth * 16">
                    <span class="bm-dk-swatch" [style.background]="fsColor(p.row.fstype, p.row.kind)"></span>{{ p.row.path }}
                  </td>
                  <td>{{ p.row.fstype || (p.row.kind !== 'part' ? p.row.kind : '—') }}</td>
                  <td>{{ p.row.label || '—' }}</td>
                  <td class="bm-dk-num">{{ fmt(p.row.size_bytes) }}</td>
                  <td class="bm-dk-num">{{ p.row.used_bytes != null ? fmt(p.row.used_bytes) : '—' }}</td>
                  <td class="bm-dk-num">{{ p.row.avail_bytes != null ? fmt(p.row.avail_bytes) : '—' }}</td>
                  <td class="bm-dk-mono">{{ p.row.mountpoint || '' }}</td>
                  <td>@for (f of p.row.flags; track f) { <span class="bm-dk-flag">{{ f }}</span> }</td>
                  <td class="bm-dk-rowacts">
                    @if (p.row.kind === 'lvm') {
                      <!-- LVM: grow works ONLINE (lvextend --resizefs), no unmount needed -->
                      <button mat-button (click)="opLvextend(p.row)" title="Grow this logical volume online (no unmount needed)"><mat-icon>unfold_more</mat-icon> Extend</button>
                    } @else if (p.row.kind === 'part' || p.row.kind === 'crypt') {
                      @if (p.row.busy) {
                        <span class="bm-dk-lock" title="Mounted at {{ p.row.mountpoint }} — a filesystem must be unmounted before it can be edited">
                          <mat-icon>lock</mat-icon>unmount to edit</span>
                        <button mat-button (click)="unmount(d, p.row)" [disabled]="busy()">Unmount</button>
                      } @else if (p.depth === 0 && p.row.kind === 'part') {
                        <button mat-icon-button (click)="opFormat(d, p.row)" title="Format"><mat-icon>edit_note</mat-icon></button>
                        <button mat-icon-button (click)="opResize(d, p.row)" [disabled]="!canResize(p.row)" [title]="resizeHint(p.row)"><mat-icon>open_in_full</mat-icon></button>
                        <button mat-icon-button (click)="opMount(d, p.row)" [disabled]="!p.row.fstype" title="Mount"><mat-icon>drive_folder_upload</mat-icon></button>
                        <button mat-icon-button (click)="opDelete(d, p.row)" title="Delete"><mat-icon>delete_outline</mat-icon></button>
                      }
                    }
                  </td>
                </tr>
              }
              @for (f of d.free; track $index) {
                @if ((f.size_bytes || 0) > 1048576) {
                  <tr class="bm-dk-freerow"><td class="bm-dk-mono"><span class="bm-dk-swatch free"></span>free space</td>
                    <td>—</td><td>—</td><td class="bm-dk-num">{{ fmt(f.size_bytes) }}</td><td>—</td><td>—</td><td></td><td></td>
                    <td class="bm-dk-rowacts"><button mat-icon-button (click)="opAddPartition(d)" [disabled]="protectedDev(d)" title="New partition"><mat-icon>add</mat-icon></button></td></tr>
                }
              }
            </tbody>
          </table>
        </div>
      } @empty { <p class="bm-empty">{{ loading() ? 'Scanning…' : 'No disks reported.' }}</p> }

      @if (l.vgs?.length) {
        <div class="bm-dk-vgs"><strong>LVM</strong>
          @for (v of l.vgs!; track v.name) { <span class="bm-dk-vg">{{ v.name }} · {{ fmt(v.size_bytes) }} ({{ fmt(v.free_bytes) }} free) · {{ v.lvs.length }} LV</span> }
        </div>
      }
    } @else if (error()) { <p class="bm-err">{{ error() }}</p> }

    <!-- pending operations queue (gparted's HBoxOperations) -->
    @if (ops().length) {
      <div class="bm-dk-queue">
        <div class="bm-dk-queue-h"><mat-icon>playlist_add_check</mat-icon> Pending operations ({{ ops().length }})</div>
        @for (o of ops(); track $index) {
          <div class="bm-dk-qop"><span class="bm-dk-qnum">{{ $index + 1 }}</span><span class="bm-dk-qdesc">{{ o._desc }}</span>
            <button mat-icon-button (click)="removeOp($index)" title="Remove"><mat-icon>close</mat-icon></button></div>
        }
        <div class="bm-dk-queue-acts">
          <button mat-button (click)="clearOps()">Undo all</button>
          <button mat-stroked-button (click)="preview()" [disabled]="busy()"><mat-icon>visibility</mat-icon> Preview</button>
          <button mat-flat-button color="warn" (click)="apply()" [disabled]="busy()"><mat-icon>play_arrow</mat-icon> {{ applying() ? 'Applying…' : 'Apply' }}</button>
        </div>
        @if (previewResult(); as pv) {
          <div class="bm-dk-preview">
            @for (p of pv.problems; track $index) { <div class="bm-dk-pr" [class.err]="p.severity==='error'">{{ p.severity }}: {{ p.message }}</div> }
            @for (s of pv.steps; track $index) { <div class="bm-dk-cmd"><code>{{ (s.argv || []).join(' ') || s.desc }}</code></div> }
          </div>
        }
        @if (applyResult(); as ar) {
          <div class="bm-dk-preview">
            <div [class.bm-dk-ok]="ar.ok" [class.bm-dk-bad]="!ar.ok">{{ ar.ok ? 'Applied.' : (ar.refused ? 'Refused (safety).' : 'Failed.') }}
              @if (ar.tools_installed?.length) { <span class="bm-dim">· installed {{ ar.tools_installed.join(', ') }}</span> }</div>
            @for (p of ar.problems || []; track $index) { <div class="bm-dk-pr err">{{ p.message }}</div> }
            @for (s of ar.steps || []; track $index) { <div class="bm-dk-cmd" [class.err]="!s.ok"><mat-icon>{{ s.ok ? 'check' : 'error' }}</mat-icon> {{ s.desc }} <span class="bm-dim">{{ s.output }}</span></div> }
          </div>
        }
      </div>
    }
    @if (scratchMsg()) { <p class="bm-dim">{{ scratchMsg() }}</p> }
  `,
  styles: [`
    .bm-dk-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
    .bm-dk-tools { display: flex; gap: 8px; }
    .bm-dim { opacity: 0.7; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); } .bm-empty { opacity: 0.6; }
    .bm-dk-errs { display: flex; gap: 8px; font-size: 12px; padding: 8px 10px; margin-bottom: 12px; border-radius: 8px;
      background: color-mix(in srgb, var(--bm-gold, #b8860b) 12%, transparent); color: var(--bm-gold, #b8860b); }
    .bm-dk-errs mat-icon { font-size: 17px; height: 17px; width: 17px; }
    .bm-dk-dev { margin-bottom: 22px; }
    .bm-dk-dev-h { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .bm-dk-dev-h mat-icon { font-size: 18px; height: 18px; width: 18px; opacity: 0.8; }
    .bm-dk-meta { font-size: 12px; opacity: 0.65; }
    .bm-dk-devacts { margin-left: auto; display: flex; gap: 2px; }
    .bm-dk-devacts button { font-size: 12px; min-width: 0; }
    .bm-dk-bar { display: flex; height: 46px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
    .bm-dk-seg { position: relative; min-width: 2px; display: flex; align-items: center; justify-content: center;
      border-right: 1px solid color-mix(in srgb, var(--mat-sys-surface) 55%, transparent); overflow: hidden; }
    .bm-dk-seg:last-child { border-right: 0; }
    .bm-dk-seg.free { background: repeating-linear-gradient(45deg, color-mix(in srgb,var(--mat-sys-on-surface) 8%,transparent), color-mix(in srgb,var(--mat-sys-on-surface) 8%,transparent) 6px, transparent 6px, transparent 12px) !important; }
    .bm-dk-used { position: absolute; left: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.28); }
    .bm-dk-seg-lbl { position: relative; z-index: 1; font-size: 10.5px; font-weight: 600; color: #10141a; white-space: nowrap; text-shadow: 0 1px 2px rgba(255,255,255,.35); padding: 0 4px; }
    .bm-dk-tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; margin-top: 8px; }
    .bm-dk-tbl th { text-align: left; font-weight: 600; opacity: 0.6; padding: 4px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-dk-tbl td { padding: 2px 8px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 45%, transparent); }
    .bm-dk-num { text-align: right; font-variant-numeric: tabular-nums; }
    .bm-dk-mono { font-family: ui-monospace, monospace; }
    .bm-dk-rowacts { text-align: right; white-space: nowrap; }
    .bm-dk-rowacts button { min-width: 0; } .bm-dk-rowacts mat-icon { font-size: 16px; height: 16px; width: 16px; }
    .bm-dk-lock { display: inline-flex; align-items: center; gap: 3px; font-size: 11px; color: var(--bm-gold, #b8860b); margin-right: 6px; }
    .bm-dk-lock mat-icon { font-size: 14px; height: 14px; width: 14px; }
    .bm-dk-freerow { opacity: 0.75; }
    .bm-dk-swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 7px; vertical-align: -1px; }
    .bm-dk-swatch.free { background: color-mix(in srgb, var(--mat-sys-on-surface) 22%, transparent); }
    .bm-dk-flag { font-size: 10px; padding: 0 6px; border-radius: 10px; margin-right: 3px; background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
    .bm-dk-vgs { display: flex; gap: 10px; align-items: center; font-size: 12px; opacity: 0.8; margin: 4px 0 16px; }
    .bm-dk-vg { padding: 2px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 20px; }
    .bm-dk-queue { margin-top: 16px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 10px 12px; }
    .bm-dk-queue-h { display: flex; align-items: center; gap: 6px; font-weight: 600; margin-bottom: 6px; }
    .bm-dk-qop { display: flex; align-items: center; gap: 8px; font-size: 13px; padding: 2px 0; }
    .bm-dk-qnum { width: 20px; opacity: 0.5; } .bm-dk-qdesc { flex: 1; }
    .bm-dk-queue-acts { display: flex; gap: 8px; justify-content: flex-end; margin-top: 8px; }
    .bm-dk-preview { margin-top: 8px; font-size: 12px; }
    .bm-dk-cmd { display: flex; align-items: center; gap: 6px; font-family: ui-monospace, monospace; padding: 1px 0; opacity: 0.9; }
    .bm-dk-cmd mat-icon { font-size: 15px; height: 15px; width: 15px; color: #66bb6a; } .bm-dk-cmd.err mat-icon { color: var(--mat-sys-error,#c62828); }
    .bm-dk-pr { padding: 2px 0; } .bm-dk-pr.err { color: var(--mat-sys-error, #c62828); }
    .bm-dk-ok { color: #66bb6a; font-weight: 600; } .bm-dk-bad { color: var(--mat-sys-error, #c62828); font-weight: 600; }
  `],
})
export class HostDisksComponent {
  private http = inject(HttpClient);
  agentId = input.required<string>();
  layout = signal<DiskLayout | null>(null);
  loading = signal(false);
  error = signal('');
  ops = signal<DiskOp[]>([]);
  previewResult = signal<any>(null);
  applyResult = signal<any>(null);
  applying = signal(false);
  scratchMsg = signal('');
  busy = computed(() => this.loading() || this.applying());

  constructor() { effect(() => { const id = this.agentId(); if (id) this.load(); }); }

  private base(): string { return `${environment.apiUrl}/agents/${this.agentId()}`; }

  load(): void {
    if (!this.agentId()) return;
    this.loading.set(true); this.error.set('');
    this.http.get<DiskLayout>(`${this.base()}/disks`).subscribe({
      next: (l) => { this.layout.set(l); this.loading.set(false); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'Failed to read disks.'); this.loading.set(false); },
    });
  }

  // ---- a disk with mounted filesystems is protected (mirrors the backend guard)
  protectedDev(d: Device): boolean {
    const anyBusy = (p: Partition): boolean => p.busy || (p.children || []).some(anyBusy);
    return (d.partitions || []).some(anyBusy);
  }

  private partPath(dev: string, num: number): string {
    return /(?:loop\d+|nvme\d+n\d+|mmcblk\d+)$/.test(dev) ? `${dev}p${num}` : `${dev}${num}`;
  }
  /** Predicted next partition number = existing top-level parts + queued mkparts on that device + 1. */
  private nextNum(dev: string): number {
    const d = this.layout()?.devices.find((x) => x.path === dev);
    const existing = (d?.partitions || []).filter((p) => p.kind === 'part').length;
    const queued = this.ops().filter((o) => o.op === 'mkpart' && o.device === dev).length;
    return existing + queued + 1;
  }
  private push(o: DiskOp): void { this.ops.update((l) => [...l, o]); this.previewResult.set(null); this.applyResult.set(null); }

  // ---- op builders (gparted-style; prompts keep it compact) -----------------
  opMklabel(d: Device, table: string): void {
    if (!confirm(`Create a new ${table.toUpperCase()} partition table on ${d.path}? This discards its current layout.`)) return;
    this.push({ op: 'mklabel', device: d.path, table, _desc: `Create ${table} table on ${d.path}` });
  }
  opAddPartition(d: Device): void {
    const size = (prompt('Partition size (e.g. 10GiB, 512MiB, or 100% for the rest):', '100%') || '').trim();
    if (!size) return;
    const fstype = (prompt('Filesystem (ext4, xfs, btrfs, vfat, swap):', 'ext4') || 'ext4').trim();
    const label = (prompt('Label (optional):', '') || '').trim();
    const mp = (prompt('Mount point (optional, e.g. /data):', '') || '').trim();
    const num = this.nextNum(d.path);
    const tgt = this.partPath(d.path, num);
    const end = size === '100%' ? '100%' : size;
    this.push({ op: 'mkpart', device: d.path, ptype: 'primary', fstype, start: '1MiB', end,
      _desc: `New ${size} ${fstype} partition on ${d.path} (→ ${tgt})` });
    if (fstype) this.push({ op: 'mkfs', device: d.path, target: tgt, fstype, _desc: `Format ${tgt} as ${fstype}` });
    if (label) this.push({ op: 'label', device: d.path, target: tgt, fstype, label, _desc: `Label ${tgt} = "${label}"` });
    if (mp) this.push({ op: 'mount', device: d.path, target: tgt, mountpoint: mp, _desc: `Mount ${tgt} at ${mp}` });
  }
  opFormat(d: Device, p: Partition): void {
    const fstype = (prompt(`Format ${p.path} as (ext4, xfs, btrfs, vfat, swap):`, p.fstype || 'ext4') || '').trim();
    if (!fstype) return;
    if (!confirm(`Format ${p.path} as ${fstype}? This erases its data.`)) return;
    this.push({ op: 'mkfs', device: d.path, target: p.path, fstype, _desc: `Format ${p.path} as ${fstype}` });
  }
  /** Resize (grow OR shrink) an unmounted ext* partition + its filesystem, gparted-style.
   *  ext only (xfs/others can't shrink); must be unmounted (enforced by the backend too). */
  canResize(p: Partition): boolean { return !p.busy && !!p.fstype && p.fstype.startsWith('ext') && p.start_s != null; }
  resizeHint(p: Partition): string {
    if (p.busy) return 'Unmount first to resize';
    if (!p.fstype || !p.fstype.startsWith('ext')) return 'Resize supported for ext2/3/4 only';
    if (p.start_s == null) return 'Partition geometry unknown (parted needed)';
    return 'Resize filesystem + partition (grow or shrink)';
  }
  opResize(d: Device, p: Partition): void {
    const num = Number((p.name.match(/(\d+)$/) || [])[1]);
    const sector = d.sector_size || 512;
    const curMib = p.size_bytes ? Math.floor(p.size_bytes / 1048576) : 0;
    const startMib = p.start_s != null ? Math.max(1, Math.round((p.start_s * sector) / 1048576)) : 1;
    if (!num || !curMib) { alert('Cannot determine partition geometry.'); return; }
    const ans = (prompt(`New size for ${p.path} in MiB (current ≈ ${curMib} MiB). Smaller shrinks, larger grows:`, String(curMib)) || '').trim();
    const sizeMib = Number(ans);
    if (!sizeMib || sizeMib <= 0) return;
    if (sizeMib === curMib) { alert('Same size — nothing to do.'); return; }
    const grow = sizeMib > curMib;
    if (!grow && !confirm(`Shrink ${p.path} to ${sizeMib} MiB? The filesystem is checked and shrunk first, then the partition. Back up important data.`)) return;
    this.push({ op: 'resize', device: d.path, target: p.path, num, fstype: p.fstype!, start_mib: startMib, size_mib: sizeMib, grow,
      _desc: `${grow ? 'Grow' : 'Shrink'} ${p.path} (${p.fstype}) ${curMib} → ${sizeMib} MiB` });
  }
  opLabel(d: Device, p: Partition): void {
    const label = (prompt(`Label for ${p.path}:`, p.label || '') || '').trim();
    this.push({ op: 'label', device: d.path, target: p.path, fstype: p.fstype || 'ext4', label, _desc: `Label ${p.path} = "${label}"` });
  }
  opMount(d: Device, p: Partition): void {
    const mp = (prompt(`Mount ${p.path} at:`, '/mnt/' + p.name) || '').trim();
    if (!mp) return;
    this.push({ op: 'mount', device: d.path, target: p.path, mountpoint: mp, _desc: `Mount ${p.path} at ${mp}` });
  }
  opDelete(d: Device, p: Partition): void {
    const num = Number((p.name.match(/(\d+)$/) || [])[1]);
    if (!num) { alert('Cannot determine partition number.'); return; }
    if (!confirm(`Delete ${p.path}? This erases it.`)) return;
    this.push({ op: 'delete', device: d.path, num, _desc: `Delete ${p.path}` });
  }
  /** Grow an LVM logical volume ONLINE (lvextend --resizefs) — works while the
   *  filesystem is mounted, so no unmount is needed (unlike a raw partition). */
  opLvextend(p: Partition): void {
    const size = (prompt(`Grow ${p.path} by (e.g. +5G, or +100%FREE for all free VG space):`, '+100%FREE') || '').trim();
    if (!size) return;
    if (!size.startsWith('+')) { alert('Only online GROW is supported here — the size must start with "+".'); return; }
    this.push({ op: 'lvextend', device: p.path, target: p.path, size, _desc: `Grow LV ${p.path} by ${size} (online, fs kept mounted)` });
  }
  /** Immediate unmount (the "free it for editing" workflow) — not staged. */
  unmount(d: Device, p: Partition): void {
    if (!confirm(`Unmount ${p.path} (mounted at ${p.mountpoint})?\nA filesystem must be unmounted before it can be formatted, resized or deleted.`)) return;
    this.applying.set(true); this.applyResult.set(null);
    this.http.post<any>(`${this.base()}/disks/apply`, { ops: [{ op: 'umount', device: d.path, target: p.path }], allow_nonloop: true }).subscribe({
      next: (r) => { this.applying.set(false); if (r?.ok) this.load(); else this.applyResult.set(r); },
      error: (e) => { this.applying.set(false); this.applyResult.set({ ok: false, problems: [{ message: e?.error?.detail ?? 'unmount failed' }] }); },
    });
  }
  removeOp(i: number): void { this.ops.update((l) => l.filter((_, x) => x !== i)); this.previewResult.set(null); this.applyResult.set(null); }
  clearOps(): void { this.ops.set([]); this.previewResult.set(null); this.applyResult.set(null); }

  private body() { return { ops: this.ops().map(({ _desc, ...o }) => o), allow_nonloop: true }; }
  preview(): void {
    this.http.post(`${this.base()}/disks/preview`, this.body()).subscribe({
      next: (r) => this.previewResult.set(r), error: (e) => this.error.set(e?.error?.detail ?? 'preview failed'),
    });
  }
  apply(): void {
    if (!confirm('Apply these operations on the host? Disk operations can destroy data.')) return;
    this.applying.set(true); this.previewResult.set(null); this.applyResult.set(null);
    this.http.post(`${this.base()}/disks/apply`, this.body()).subscribe({
      next: (r: any) => { this.applyResult.set(r); this.applying.set(false); if (r?.ok) { this.ops.set([]); this.load(); } },
      error: (e) => { this.applyResult.set({ ok: false, problems: [{ message: e?.error?.detail ?? 'apply failed' }] }); this.applying.set(false); },
    });
  }

  addScratch(): void {
    const mb = Number(prompt('Scratch loopback disk size in MB (for safe testing):', '256') || 0);
    if (!mb) return;
    this.scratchMsg.set('Creating scratch disk…');
    this.http.post<any>(`${this.base()}/disks/scratch`, { action: 'create', size_mb: mb }).subscribe({
      next: (r) => { this.scratchMsg.set(r?.ok ? `Scratch disk ${r.device} created — Rescan to see it. (Destroy later via losetup -d.)` : ('scratch failed: ' + (r?.error || ''))); this.load(); },
      error: (e) => this.scratchMsg.set(e?.error?.detail ?? 'scratch failed'),
    });
  }

  // ---- rendering helpers ----------------------------------------------------
  private static readonly FS_COLORS: Record<string, string> = {
    ext2: '#5b8def', ext3: '#5b8def', ext4: '#4a7fe0', xfs: '#3fae6b', btrfs: '#e08a3c',
    ntfs: '#a06bd0', vfat: '#3fb6c0', fat16: '#3fb6c0', fat32: '#3fb6c0', exfat: '#3fb6c0',
    f2fs: '#7aa93c', swap: '#d05656', 'linux-swap': '#d05656',
    lvm2_member: '#8a94a6', LVM2_member: '#8a94a6', crypto_luks: '#c0607a', lvm: '#8a94a6', crypt: '#c0607a',
  };
  fsColor(fstype: string | null, kind?: string): string {
    if (fstype && HostDisksComponent.FS_COLORS[fstype]) return HostDisksComponent.FS_COLORS[fstype];
    if (kind && HostDisksComponent.FS_COLORS[kind]) return HostDisksComponent.FS_COLORS[kind];
    return '#9aa0aa';
  }
  fmt(bytes: number | null | undefined): string {
    if (bytes == null) return '—';
    const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']; let i = 0; let n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)} ${u[i]}`;
  }
  segsFor(d: Device): Seg[] {
    const total = d.size_bytes
      || (d.partitions.reduce((a, p) => a + (p.size_bytes || 0), 0) + d.free.reduce((a, f) => a + (f.size_bytes || 0), 0)) || 1;
    const segs: Seg[] = [];
    for (const p of d.partitions) {
      const sz = p.size_bytes || 0;
      const usedPct = p.used_bytes != null && sz > 0 ? Math.min(100, (p.used_bytes / sz) * 100) : 0;
      segs.push({ kind: 'part', label: (p.name || '').replace(/^.*\//, ''), pct: (sz / total) * 100, usedPct,
        color: this.fsColor(p.fstype, p.kind),
        title: `${p.path}\n${p.fstype || p.kind || '?'} · ${this.fmt(sz)}${p.mountpoint ? ' · ' + p.mountpoint : ''}`
          + (p.used_bytes != null ? `\nused ${this.fmt(p.used_bytes)} / avail ${this.fmt(p.avail_bytes)}` : '') });
    }
    for (const f of d.free) {
      if ((f.size_bytes || 0) <= 1048576) continue;
      segs.push({ kind: 'free', label: 'free', pct: ((f.size_bytes || 0) / total) * 100, usedPct: 0, color: 'transparent', title: `free space · ${this.fmt(f.size_bytes)}` });
    }
    return segs;
  }
  flatten(parts: Partition[], depth = 0): { row: Partition; depth: number }[] {
    const out: { row: Partition; depth: number }[] = [];
    for (const p of parts) { out.push({ row: p, depth }); if (p.children?.length) out.push(...this.flatten(p.children, depth + 1)); }
    return out;
  }
}
