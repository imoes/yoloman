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
interface DiskLayout { devices: Device[]; errors: string[]; }

interface Seg { kind: 'part' | 'free'; label: string; pct: number; usedPct: number; color: string; title: string; }

/**
 * The host's Disks view (gparted-style, read-only — Phase 1): a visual bar per
 * disk (partitions coloured by filesystem, FREE gaps, used/avail fill) plus a
 * partition table. Live from GET /agents/{id}/disks. The mutating side (an
 * operation queue + Apply) comes in later phases — see docs/disk-management.md.
 */
@Component({
  selector: 'app-host-disks',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-dk-head">
      <span class="bm-dim">Disks &amp; partitions — read-only view of what is on this host (live). Editing arrives in a later phase.</span>
      <button mat-stroked-button (click)="load()" [disabled]="loading()"><mat-icon>refresh</mat-icon> {{ loading() ? 'Scanning…' : 'Rescan' }}</button>
    </div>

    @if (layout()?.errors?.length) {
      <div class="bm-dk-errs">
        <mat-icon>info</mat-icon>
        <div>@for (e of layout()!.errors; track $index) { <div>{{ e }}</div> }</div>
      </div>
    }

    @if (layout(); as l) {
      @for (d of l.devices; track d.path) {
        <div class="bm-dk-dev">
          <div class="bm-dk-dev-h">
            <mat-icon>{{ d.rotational ? 'album' : 'sd_card' }}</mat-icon>
            <strong>{{ d.path }}</strong>
            <span class="bm-dk-meta">{{ d.model || '—' }} · {{ fmt(d.size_bytes) }} · {{ d.table || 'no table' }}{{ d.rotational ? ' · HDD' : ' · SSD' }}</span>
          </div>

          <!-- visual bar -->
          <div class="bm-dk-bar" [title]="d.path">
            @for (s of segsFor(d); track $index) {
              <div class="bm-dk-seg" [class.free]="s.kind === 'free'" [style.width.%]="s.pct"
                   [style.background]="s.color" [title]="s.title">
                @if (s.kind === 'part' && s.usedPct > 0) {
                  <div class="bm-dk-used" [style.width.%]="s.usedPct"></div>
                }
                <span class="bm-dk-seg-lbl">{{ s.label }}</span>
              </div>
            }
          </div>

          <!-- partition table -->
          <table class="bm-dk-tbl">
            <thead><tr><th>Partition</th><th>FS</th><th>Label</th><th>Size</th><th>Used</th><th>Avail</th><th>Mount</th><th>Flags</th></tr></thead>
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
                </tr>
              }
              @for (f of d.free; track $index) {
                @if ((f.size_bytes || 0) > 1048576) {
                  <tr class="bm-dk-freerow"><td class="bm-dk-mono"><span class="bm-dk-swatch free"></span>free space</td>
                    <td>—</td><td>—</td><td class="bm-dk-num">{{ fmt(f.size_bytes) }}</td><td>—</td><td>—</td><td></td><td></td></tr>
                }
              }
            </tbody>
          </table>
        </div>
      } @empty {
        <p class="bm-empty">{{ loading() ? 'Scanning…' : 'No disks reported (host unreachable, or no lsblk).' }}</p>
      }
    } @else if (error()) { <p class="bm-err">{{ error() }}</p> }
  `,
  styles: [`
    .bm-dk-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
    .bm-dim { opacity: 0.7; font-size: 13px; }
    .bm-err { color: var(--mat-sys-error, #c62828); } .bm-empty { opacity: 0.6; }
    .bm-dk-errs { display: flex; gap: 8px; font-size: 12px; padding: 8px 10px; margin-bottom: 12px; border-radius: 8px;
      background: color-mix(in srgb, var(--bm-gold, #b8860b) 12%, transparent); color: var(--bm-gold, #b8860b); }
    .bm-dk-errs mat-icon { font-size: 17px; height: 17px; width: 17px; }
    .bm-dk-dev { margin-bottom: 22px; }
    .bm-dk-dev-h { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .bm-dk-dev-h mat-icon { font-size: 18px; height: 18px; width: 18px; opacity: 0.8; }
    .bm-dk-meta { font-size: 12px; opacity: 0.65; }
    .bm-dk-bar { display: flex; height: 46px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow: hidden; }
    .bm-dk-seg { position: relative; min-width: 2px; display: flex; align-items: center; justify-content: center;
      border-right: 1px solid color-mix(in srgb, var(--mat-sys-surface) 55%, transparent); overflow: hidden; }
    .bm-dk-seg:last-child { border-right: 0; }
    .bm-dk-seg.free { background: repeating-linear-gradient(45deg, color-mix(in srgb,var(--mat-sys-on-surface) 8%,transparent), color-mix(in srgb,var(--mat-sys-on-surface) 8%,transparent) 6px, transparent 6px, transparent 12px) !important; }
    .bm-dk-used { position: absolute; left: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.28); }
    .bm-dk-seg-lbl { position: relative; z-index: 1; font-size: 10.5px; font-weight: 600; color: #10141a; white-space: nowrap; text-shadow: 0 1px 2px rgba(255,255,255,.35); padding: 0 4px; }
    .bm-dk-tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; margin-top: 8px; }
    .bm-dk-tbl th { text-align: left; font-weight: 600; opacity: 0.6; padding: 4px 8px; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .bm-dk-tbl td { padding: 4px 8px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 45%, transparent); }
    .bm-dk-num { text-align: right; font-variant-numeric: tabular-nums; }
    .bm-dk-mono { font-family: ui-monospace, monospace; }
    .bm-dk-freerow { opacity: 0.6; }
    .bm-dk-swatch { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 7px; vertical-align: -1px; }
    .bm-dk-swatch.free { background: color-mix(in srgb, var(--mat-sys-on-surface) 22%, transparent); }
    .bm-dk-flag { font-size: 10px; padding: 0 6px; border-radius: 10px; margin-right: 3px; background: color-mix(in srgb, var(--mat-sys-primary) 16%, transparent); }
  `],
})
export class HostDisksComponent {
  private http = inject(HttpClient);
  agentId = input.required<string>();
  layout = signal<DiskLayout | null>(null);
  loading = signal(false);
  error = signal('');

  constructor() { effect(() => { const id = this.agentId(); if (id) this.load(); }); }

  load(): void {
    const id = this.agentId();
    if (!id) return;
    this.loading.set(true); this.error.set('');
    this.http.get<DiskLayout>(`${environment.apiUrl}/agents/${id}/disks`).subscribe({
      next: (l) => { this.layout.set(l); this.loading.set(false); },
      error: (e) => { this.error.set(e?.error?.detail ?? 'Failed to read disks.'); this.loading.set(false); },
    });
  }

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

  /** Build the proportional bar segments (top-level partitions + free gaps). */
  segsFor(d: Device): Seg[] {
    const total = d.size_bytes
      || (d.partitions.reduce((a, p) => a + (p.size_bytes || 0), 0)
          + d.free.reduce((a, f) => a + (f.size_bytes || 0), 0)) || 1;
    const segs: Seg[] = [];
    for (const p of d.partitions) {
      const sz = p.size_bytes || 0;
      const usedPct = p.used_bytes != null && sz > 0 ? Math.min(100, (p.used_bytes / sz) * 100) : 0;
      segs.push({
        kind: 'part', label: (p.name || '').replace(/^.*\//, ''), pct: (sz / total) * 100, usedPct,
        color: this.fsColor(p.fstype, p.kind),
        title: `${p.path}\n${p.fstype || p.kind || '?'} · ${this.fmt(sz)}${p.mountpoint ? ' · ' + p.mountpoint : ''}`
          + (p.used_bytes != null ? `\nused ${this.fmt(p.used_bytes)} / avail ${this.fmt(p.avail_bytes)}` : ''),
      });
    }
    for (const f of d.free) {
      if ((f.size_bytes || 0) <= 1048576) continue;
      segs.push({ kind: 'free', label: 'free', pct: ((f.size_bytes || 0) / total) * 100, usedPct: 0,
        color: 'transparent', title: `free space · ${this.fmt(f.size_bytes)}` });
    }
    return segs;
  }

  /** Flatten partitions + their children (LVM LVs, LUKS) for the table, tagged with depth. */
  flatten(parts: Partition[], depth = 0): { row: Partition; depth: number }[] {
    const out: { row: Partition; depth: number }[] = [];
    for (const p of parts) {
      out.push({ row: p, depth });
      if (p.children?.length) out.push(...this.flatten(p.children, depth + 1));
    }
    return out;
  }
}
