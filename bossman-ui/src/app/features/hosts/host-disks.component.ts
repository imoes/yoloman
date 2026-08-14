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
interface ZfsPool { name: string; size_bytes: number | null; alloc_bytes: number | null; free_bytes: number | null; health: string; frag: string | null; cap: string | null; }
interface ZfsDataset { name: string; type: string; used_bytes: number | null; avail_bytes: number | null;
  refer_bytes: number | null; quota_bytes: number | null; refquota_bytes: number | null;
  reservation_bytes: number | null; refreservation_bytes: number | null; mountpoint: string | null; }
interface Zfs { available: boolean; pools?: ZfsPool[]; datasets?: ZfsDataset[]; }
interface DiskLayout { devices: Device[]; vgs?: Vg[]; zfs?: Zfs; errors: string[]; }

interface DiskOp { op: string; device?: string; target?: string; table?: string; fstype?: string;
  start?: string; end?: string; ptype?: string; num?: number; label?: string; mountpoint?: string; size?: string;
  start_mib?: number; size_mib?: number; grow?: boolean;
  name?: string; property?: string; snap?: string; recursive?: boolean; raid?: string; vdevs?: string[]; _desc: string; }
/** One box in the visual disk bar (gparted's DrawingAreaVisualDisk): a partition or
 *  a free gap, drawn proportionally, with nested children (LVM/LUKS) rendered inside
 *  the parent box the way gparted draws an extended partition's container. */
interface Seg {
  kind: 'part' | 'free'; key: string; name: string; fs: string; sizeLabel: string;
  pct: number; usedPct: number; color: string; title: string; children: Seg[];
}
interface FormField { key: string; label: string; type: 'text' | 'number' | 'select'; value: string;
  options?: string[]; hint?: string; placeholder?: string; }
interface ActiveForm { title: string; icon: string; fields: FormField[]; submitLabel: string;
  danger?: boolean; note?: string; run: (v: Record<string, string>) => void; }

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
    <!-- gparted's toolbar: actions act on the SELECTED partition; the device chooser
         picks ONE disk at a time (right), and Undo/Apply gate the staged queue. -->
    <div class="bm-gp-toolbar">
      <div class="bm-gp-acts">
        <button class="bm-gp-tb" (click)="tbNew()" [disabled]="!canNew()" title="New partition in the selected unallocated space">
          <mat-icon>add_box</mat-icon><span>New</span></button>
        <button class="bm-gp-tb" (click)="tbDelete()" [disabled]="!canDelete()" title="Delete the selected partition">
          <mat-icon>delete</mat-icon><span>Delete</span></button>
        <button class="bm-gp-tb" (click)="tbResize()" [disabled]="!canResizeSel()" [title]="resizeTip()">
          <mat-icon>unfold_more</mat-icon><span>Resize/Move</span></button>
        <span class="bm-gp-sep"></span>
        <button class="bm-gp-tb" (click)="tbFormat()" [disabled]="!canFormat()" title="Format the selected partition">
          <mat-icon>edit_note</mat-icon><span>Format</span></button>
        <button class="bm-gp-tb" (click)="tbLabel()" [disabled]="!canFormat()" title="Set the filesystem label">
          <mat-icon>sell</mat-icon><span>Label</span></button>
        <button class="bm-gp-tb" (click)="tbMount()" [disabled]="!canMount()" [title]="mountTip()">
          <mat-icon>{{ selBusy() ? 'eject' : 'drive_folder_upload' }}</mat-icon><span>{{ selBusy() ? 'Unmount' : 'Mount' }}</span></button>
        <span class="bm-gp-sep"></span>
        <button class="bm-gp-tb" (click)="undoLast()" [disabled]="!ops().length" title="Undo the last staged operation">
          <mat-icon>undo</mat-icon><span>Undo</span></button>
        <button class="bm-gp-tb bm-gp-apply" (click)="apply()" [disabled]="!ops().length || busy()" title="Apply all staged operations">
          <mat-icon>check</mat-icon><span>{{ applying() ? 'Applying…' : 'Apply' }}</span></button>
      </div>
      <div class="bm-gp-devpick">
        <mat-icon>{{ dev()?.rotational ? 'album' : 'sd_card' }}</mat-icon>
        <select class="bm-gp-devsel" [value]="selDev()" (change)="pickDev(asVal($event))" title="Select a device">
          @for (d of layout()?.devices || []; track d.path) {
            <option [value]="d.path">{{ d.path }} ({{ fmt(d.size_bytes) }})</option>
          }
        </select>
        <button class="bm-gp-tb bm-gp-tb-sm" (click)="load()" [disabled]="busy()" title="Rescan the host's disks">
          <mat-icon>refresh</mat-icon></button>
      </div>
    </div>

    @if (layout()?.errors?.length) {
      <div class="bm-dk-errs"><mat-icon>info</mat-icon><div>@for (e of layout()!.errors; track $index) { <div>{{ e }}</div> }</div></div>
    }

    @if (layout(); as l) {
      @if (dev(); as d) {
        <div class="bm-gp-canvas">
          <!-- the visual disk (gparted's DrawingAreaVisualDisk) -->
          <div class="bm-gp-disk" [title]="d.path + ' · ' + fmt(d.size_bytes) + ' · ' + (d.table || 'no partition table')">
            @for (s of segsFor(d); track s.key) {
              <div class="bm-gp-seg" [class.free]="s.kind === 'free'" [class.sel]="sel() === s.key" [class.haskids]="s.children.length > 0"
                   [style.width.%]="s.pct" [style.borderColor]="s.color"
                   [style.background]="s.kind === 'free' ? '' : tint(s.color)"
                   [title]="s.title" (click)="sel.set(s.key)">
                @if (s.usedPct > 0) { <div class="bm-gp-used" [style.width.%]="s.usedPct" [style.background]="used(s.color)"></div> }
                @if (s.children.length) {
                  <div class="bm-gp-kids">
                    @for (k of s.children; track k.key) {
                      <div class="bm-gp-kid" [class.sel]="sel() === k.key" [style.width.%]="k.pct"
                           [style.borderColor]="k.color" [style.background]="tint(k.color)"
                           [title]="k.title" (click)="sel.set(k.key); $event.stopPropagation()">
                        @if (k.usedPct > 0) { <div class="bm-gp-used" [style.width.%]="k.usedPct" [style.background]="used(k.color)"></div> }
                        <span class="bm-gp-lbl"><b>{{ k.name }}</b><i>{{ k.sizeLabel }}</i></span>
                      </div>
                    }
                  </div>
                }
                <span class="bm-gp-lbl"><b>{{ s.name }}</b><i>{{ s.sizeLabel }}</i></span>
              </div>
            }
          </div>

          <!-- the partition list (gparted's TreeView_Detail) -->
          <div class="bm-gp-tblwrap">
          <table class="bm-gp-tbl">
            <thead><tr>
              <th>Partition</th><th>File System</th><th>Mount Point</th><th>Label</th>
              <th class="bm-dk-num">Size</th><th class="bm-dk-num">Used</th><th class="bm-dk-num">Unused</th><th>Flags</th>
            </tr></thead>
            <tbody>
              @for (p of rowsFor(d); track p.key) {
                <tr [class.sel]="sel() === p.key" [class.bm-gp-freerow]="p.free" (click)="sel.set(p.key)">
                  <td class="bm-dk-mono" [class.bm-gp-child]="p.depth > 0" [style.paddingLeft.px]="8 + p.depth * 18">
                    @if (p.kids) { <span class="bm-gp-exp">▾</span> }
                    <span class="bm-dk-swatch" [style.background]="p.free ? '' : p.color" [class.free]="p.free"></span>{{ p.name }}
                    @if (p.busy) { <mat-icon class="bm-gp-lockic" [title]="'mounted at ' + p.mount + ' — unmount to edit'">lock</mat-icon> }
                  </td>
                  <td>{{ p.fs }}</td>
                  <td class="bm-dk-mono">{{ p.mount }}</td>
                  <td>{{ p.label }}</td>
                  <td class="bm-dk-num">{{ p.size }}</td>
                  <td class="bm-dk-num">{{ p.used }}</td>
                  <td class="bm-dk-num">{{ p.unused }}</td>
                  <td>@for (f of p.flags; track f) { <span class="bm-dk-flag">{{ f }}</span> }</td>
                </tr>
              }
            </tbody>
          </table>
          </div>

          <!-- gparted's statusbar + the device menu equivalents -->
          <div class="bm-gp-status">
            <span>{{ ops().length }} operation{{ ops().length === 1 ? '' : 's' }} pending</span>
            <span class="bm-gp-statusdev">{{ d.model || 'disk' }} · {{ d.table || 'no partition table' }} · {{ d.rotational ? 'HDD' : 'SSD' }}{{ d.sector_size ? ' · ' + d.sector_size + 'B sectors' : '' }}</span>
            <span class="bm-gp-statusacts">
              <button class="bm-gp-lnk" (click)="opMklabel(d, 'gpt')" [disabled]="protectedDev(d)" title="Create a new GPT partition table (discards the layout)">New GPT table</button>
              <button class="bm-gp-lnk" (click)="opMklabel(d, 'msdos')" [disabled]="protectedDev(d)">New MBR table</button>
              <button class="bm-gp-lnk" (click)="addScratch()" [disabled]="busy()">Scratch disk…</button>
            </span>
          </div>
        </div>
      } @else { <p class="bm-empty">{{ loading() ? 'Scanning…' : 'No disks reported.' }}</p> }

      @if (l.vgs?.length) {
        <div class="bm-dk-vgs"><strong>LVM</strong>
          @for (v of l.vgs!; track v.name) { <span class="bm-dk-vg">{{ v.name }} · {{ fmt(v.size_bytes) }} ({{ fmt(v.free_bytes) }} free) · {{ v.lvs.length }} LV</span> }
        </div>
      }

      @if (l.zfs?.available) {
        <div class="bm-dk-zfs">
          <div class="bm-dk-zfs-h">
            <mat-icon>dataset</mat-icon><strong>ZFS</strong>
            <span class="bm-dk-devacts">
              <button mat-button (click)="opZpoolCreate(l)"><mat-icon>add</mat-icon> Create pool</button>
            </span>
          </div>
          @for (pool of l.zfs!.pools || []; track pool.name) {
            <div class="bm-dk-zpool">
              <div class="bm-dk-zpool-h">
                <span class="bm-dk-swatch" [style.background]="poolHealthColor(pool.health)"></span>
                <strong>{{ pool.name }}</strong>
                <span class="bm-dk-meta">{{ fmt(pool.size_bytes) }} · {{ fmt(pool.free_bytes) }} free · {{ pool.health }}{{ pool.cap ? ' · ' + pool.cap + '% used' : '' }}</span>
                <span class="bm-dk-rowacts">
                  <button mat-button (click)="opZfsCreate(pool.name)" title="Create a dataset"><mat-icon>create_new_folder</mat-icon> Dataset</button>
                  <button mat-icon-button (click)="opZpoolDestroy(pool.name)" title="Destroy pool"><mat-icon>delete_forever</mat-icon></button>
                </span>
              </div>
              <table class="bm-dk-tbl">
                <thead><tr><th>Dataset</th><th>Type</th><th>Used</th><th>Avail</th><th>Quota</th><th>Reserv.</th><th>Mount</th><th></th></tr></thead>
                <tbody>
                  @for (ds of datasetsOf(l, pool.name); track ds.name) {
                    <tr>
                      <td class="bm-dk-mono" [style.paddingLeft.px]="8 + zfsDepth(ds.name) * 16">{{ zfsLeaf(ds.name) }}</td>
                      <td>{{ ds.type }}</td>
                      <td class="bm-dk-num">{{ fmt(ds.used_bytes) }}</td>
                      <td class="bm-dk-num">{{ ds.avail_bytes != null ? fmt(ds.avail_bytes) : '—' }}</td>
                      <td class="bm-dk-num">{{ ds.refquota_bytes != null ? fmt(ds.refquota_bytes) : (ds.quota_bytes != null ? fmt(ds.quota_bytes) : '—') }}</td>
                      <td class="bm-dk-num">{{ ds.refreservation_bytes != null ? fmt(ds.refreservation_bytes) : (ds.reservation_bytes != null ? fmt(ds.reservation_bytes) : '—') }}</td>
                      <td class="bm-dk-mono">{{ ds.mountpoint || '' }}</td>
                      <td class="bm-dk-rowacts">
                        @if (ds.type !== 'snapshot') {
                          <button mat-icon-button (click)="opZfsSet(ds)" title="Set quota / reservation (the ZFS resize)"><mat-icon>straighten</mat-icon></button>
                          <button mat-icon-button (click)="opZfsSnapshot(ds.name)" title="Snapshot"><mat-icon>photo_camera</mat-icon></button>
                          <button mat-icon-button (click)="opZfsDestroy(ds.name)" title="Destroy dataset"><mat-icon>delete_outline</mat-icon></button>
                        } @else {
                          <button mat-icon-button (click)="opZfsRollback(ds.name)" title="Roll back to this snapshot"><mat-icon>history</mat-icon></button>
                          <button mat-icon-button (click)="opZfsDestroy(ds.name)" title="Destroy snapshot"><mat-icon>delete_outline</mat-icon></button>
                        }
                      </td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
          } @empty { <p class="bm-dim">No pools. Use “Create pool” to make one from free devices.</p> }
        </div>
      }
    } @else if (error()) { <p class="bm-err">{{ error() }}</p> }

    <!-- inline op form (replaces the old prompt() chain) -->
    @if (form(); as f) {
      <div class="bm-dk-form" [class.danger]="f.danger">
        <div class="bm-dk-form-h"><mat-icon>{{ f.icon }}</mat-icon> {{ f.title }}</div>
        @if (f.note) { <div class="bm-dk-form-note"><mat-icon>warning</mat-icon> {{ f.note }}</div> }
        @if (f.fields.length) {
        <div class="bm-dk-form-grid">
          @for (fld of f.fields; track fld.key) {
            <label class="bm-dk-fld">
              <span class="bm-dk-fld-lbl">{{ fld.label }}</span>
              @if (fld.type === 'select') {
                <select [value]="fld.value" (change)="fld.value = asVal($event)">
                  @for (o of fld.options!; track o) { <option [value]="o">{{ o || '(none)' }}</option> }
                </select>
              } @else {
                <input [type]="fld.type" [value]="fld.value" [placeholder]="fld.placeholder || ''"
                       (input)="fld.value = asVal($event)" (keydown.enter)="submitForm()" />
              }
              @if (fld.hint) { <span class="bm-dk-fld-hint">{{ fld.hint }}</span> }
            </label>
          }
        </div>
        }
        <div class="bm-dk-form-acts">
          <button mat-button (click)="closeForm()">Cancel</button>
          <button mat-flat-button [color]="f.danger ? 'warn' : 'primary'" (click)="submitForm()">{{ f.submitLabel }}</button>
        </div>
      </div>
    }

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
    /* gparted's reading order: toolbar → visual disk + list + statusbar → the
       pending-operations list → the LVM/ZFS extras. The @if blocks render no
       wrapper elements, so the host lays its sections out directly. */
    :host { display: flex; flex-direction: column; }
    .bm-gp-toolbar { order: 1; } .bm-dk-errs { order: 2; } .bm-gp-canvas { order: 3; }
    .bm-dk-form { order: 4; } .bm-dk-queue { order: 5; }
    .bm-dk-vgs { order: 6; } .bm-dk-zfs { order: 7; }
    .bm-empty, .bm-err { order: 8; }
    /* ---- gparted layout (toolbar / visual disk / list / statusbar) ---------- */
    .bm-gp-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap;
      padding: 6px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px 10px 0 0;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-gp-acts, .bm-gp-devpick { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
    .bm-gp-devpick { margin-left: auto; }
    .bm-gp-tb { display: flex; flex-direction: column; align-items: center; gap: 2px; min-width: 58px;
      padding: 6px 8px; border: 1px solid transparent; border-radius: 8px; background: transparent;
      color: var(--mat-sys-on-surface); font: inherit; font-size: 11px; cursor: pointer; }
    .bm-gp-tb mat-icon { font-size: 20px; height: 20px; width: 20px; }
    .bm-gp-tb:hover:not(:disabled) { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent);
      border-color: color-mix(in srgb, var(--mat-sys-primary) 35%, transparent); }
    .bm-gp-tb:disabled { opacity: 0.35; cursor: default; }
    .bm-gp-tb-sm { min-width: 0; } .bm-gp-tb-sm span { display: none; }
    .bm-gp-apply mat-icon { color: #66bb6a; }
    .bm-gp-sep { width: 1px; align-self: stretch; margin: 4px 6px; background: var(--mat-sys-outline-variant); }
    .bm-gp-devsel { font: inherit; font-size: 12.5px; padding: 5px 8px; border-radius: 8px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-gp-devpick mat-icon { opacity: 0.75; font-size: 18px; height: 18px; width: 18px; }
    .bm-gp-canvas { border: 1px solid var(--mat-sys-outline-variant); border-top: 0; border-radius: 0 0 10px 10px; }
    /* the visual disk: proportional boxes, fstype-coloured border, pale interior,
       darker "used" fill — gparted's DrawingAreaVisualDisk */
    .bm-gp-disk { display: flex; gap: 3px; height: 78px; margin: 14px; padding: 3px;
      border: 1px solid var(--mat-sys-outline-variant); border-radius: 4px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-gp-seg { position: relative; min-width: 6px; border: 2px solid; border-radius: 2px; overflow: hidden;
      display: flex; align-items: center; justify-content: center; cursor: pointer; }
    .bm-gp-seg.free { background: repeating-linear-gradient(45deg,
      color-mix(in srgb,var(--mat-sys-on-surface) 9%,transparent), color-mix(in srgb,var(--mat-sys-on-surface) 9%,transparent) 5px,
      transparent 5px, transparent 10px) !important; border-style: dashed; }
    .bm-gp-seg.sel, .bm-gp-kid.sel { outline: 2px solid var(--bm-gold, #b8860b); outline-offset: 1px; }
    .bm-gp-used { position: absolute; left: 0; top: 0; bottom: 0; }
    /* a partition holding children (LVM/LUKS) puts its own label on top and draws the
       children in the lower half — gparted's extended-partition container */
    .bm-gp-seg.haskids { align-items: flex-start; }
    .bm-gp-seg.haskids > .bm-gp-lbl { margin-top: 3px; }
    .bm-gp-kids { position: absolute; left: 2px; right: 2px; bottom: 2px; top: 42%; display: flex; gap: 2px; }
    .bm-gp-kid { position: relative; min-width: 4px; border: 1px solid; border-radius: 2px; overflow: hidden;
      display: flex; align-items: center; justify-content: center; cursor: pointer; }
    .bm-gp-lbl { position: relative; z-index: 1; display: flex; flex-direction: column; align-items: center;
      line-height: 1.25; white-space: nowrap; padding: 0 4px; pointer-events: none; }
    .bm-gp-lbl b { font-size: 11px; font-weight: 600; } .bm-gp-lbl i { font-size: 10.5px; font-style: normal; opacity: 0.8; }
    .bm-gp-kid .bm-gp-lbl b { font-size: 10px; } .bm-gp-kid .bm-gp-lbl i { display: none; }
    .bm-gp-tblwrap { overflow-x: auto; }
    .bm-gp-tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; white-space: nowrap; }
    .bm-gp-tbl th { text-align: left; font-weight: 600; opacity: 0.65; padding: 5px 8px;
      border-top: 1px solid var(--mat-sys-outline-variant); border-bottom: 1px solid var(--mat-sys-outline-variant);
      background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); }
    .bm-gp-tbl td { padding: 3px 8px; border-bottom: 1px solid color-mix(in srgb, var(--mat-sys-outline-variant) 45%, transparent); }
    .bm-gp-tbl tbody tr { cursor: pointer; }
    .bm-gp-tbl tbody tr:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-gp-tbl tbody tr.sel { background: color-mix(in srgb, var(--bm-gold, #b8860b) 18%, transparent); }
    .bm-gp-freerow { opacity: 0.7; font-style: italic; }
    .bm-gp-exp { display: inline-block; width: 12px; margin-left: -13px; opacity: 0.55; font-size: 11px; }
    /* gparted's tree: children sit under their parent with a guide line */
    .bm-gp-tbl td.bm-gp-child { position: relative; }
    .bm-gp-tbl td.bm-gp-child::before { content: ''; position: absolute; left: 14px; top: 0; bottom: 50%;
      border-left: 1px solid var(--mat-sys-outline-variant); border-bottom: 1px solid var(--mat-sys-outline-variant); width: 8px; }
    .bm-gp-lockic { font-size: 13px; height: 13px; width: 13px; vertical-align: -2px; margin-left: 5px; color: var(--bm-gold, #b8860b); }
    .bm-gp-status { display: flex; align-items: center; gap: 12px; padding: 6px 10px; font-size: 12px;
      border-top: 1px solid var(--mat-sys-outline-variant);
      background: color-mix(in srgb, var(--mat-sys-on-surface) 4%, transparent); border-radius: 0 0 10px 10px; }
    .bm-gp-statusdev { opacity: 0.6; } .bm-gp-statusacts { margin-left: auto; display: flex; gap: 10px; }
    .bm-gp-lnk { background: none; border: 0; padding: 0; font: inherit; font-size: 12px; cursor: pointer;
      color: var(--mat-sys-primary); text-decoration: underline; }
    .bm-gp-lnk:disabled { opacity: 0.4; cursor: default; text-decoration: none; }
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
    /* LVM + ZFS live in the same framed card the disk canvas uses, so the panel
       reads as one unit instead of loose strips */
    .bm-dk-vgs, .bm-dk-zfs { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px;
      padding: 8px 12px; margin-top: 12px; }
    .bm-dk-vgs { display: flex; gap: 10px; align-items: center; font-size: 12px; }
    .bm-dk-vgs > strong { opacity: 0.65; font-size: 11.5px; letter-spacing: 0.04em; text-transform: uppercase; }
    .bm-dk-vg { padding: 2px 8px; border: 1px solid var(--mat-sys-outline-variant); border-radius: 20px; opacity: 0.85; }
    .bm-dk-zfs-h { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
    .bm-dk-zfs-h > strong { opacity: 0.65; font-size: 11.5px; letter-spacing: 0.04em; text-transform: uppercase; }
    .bm-dk-zfs-h mat-icon { font-size: 18px; height: 18px; width: 18px; opacity: 0.8; }
    .bm-dk-zpool { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; padding: 8px 10px; margin-bottom: 10px; }
    .bm-dk-zpool-h { display: flex; align-items: center; gap: 8px; }
    .bm-dk-zpool-h .bm-dk-rowacts { margin-left: auto; }
    .bm-dk-form { margin-top: 16px; border: 1px solid var(--mat-sys-primary); border-radius: 10px; padding: 12px 14px;
      background: color-mix(in srgb, var(--mat-sys-primary) 6%, transparent); }
    .bm-dk-form.danger { border-color: var(--mat-sys-error, #c62828); background: color-mix(in srgb, var(--mat-sys-error,#c62828) 7%, transparent); }
    .bm-dk-form-h { display: flex; align-items: center; gap: 6px; font-weight: 600; margin-bottom: 10px; }
    .bm-dk-form-h mat-icon { font-size: 18px; height: 18px; width: 18px; }
    .bm-dk-form-note { display: flex; align-items: center; gap: 6px; font-size: 12.5px; margin-bottom: 10px;
      color: var(--mat-sys-error, #c62828); }
    .bm-dk-form-note mat-icon { font-size: 16px; height: 16px; width: 16px; }
    .bm-dk-form-grid { display: flex; flex-wrap: wrap; gap: 12px; }
    .bm-dk-fld { display: flex; flex-direction: column; gap: 3px; min-width: 160px; flex: 1 1 160px; }
    .bm-dk-fld-lbl { font-size: 12px; font-weight: 600; opacity: 0.75; }
    .bm-dk-fld input, .bm-dk-fld select { font: inherit; font-size: 13px; padding: 6px 8px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-dk-fld-hint { font-size: 11px; opacity: 0.6; }
    .bm-dk-form-acts { display: flex; gap: 8px; justify-content: flex-end; margin-top: 12px; }
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
  /** gparted works on ONE device at a time (the toolbar's device chooser) and acts
   *  on the currently SELECTED partition/unallocated row. */
  selDev = signal<string>('');
  sel = signal<string | null>(null);
  dev = computed<Device | null>(() => {
    const l = this.layout(); if (!l?.devices?.length) return null;
    return l.devices.find((d) => d.path === this.selDev()) ?? l.devices[0];
  });
  form = signal<ActiveForm | null>(null);
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
      next: (l) => {
        this.layout.set(l); this.loading.set(false);
        // keep the chosen device across a rescan; default to the first one
        if (!l.devices?.some((d) => d.path === this.selDev())) this.selDev.set(l.devices?.[0]?.path ?? '');
        if (this.sel() && !this.rowsFor(this.dev() ?? ({ partitions: [], free: [] } as any)).some((r) => r.key === this.sel())) this.sel.set(null);
      },
      error: (e) => { this.error.set(e?.error?.detail ?? 'Failed to read disks.'); this.loading.set(false); },
    });
  }

  pickDev(path: string): void { this.selDev.set(path); this.sel.set(null); }

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

  // ---- inline form plumbing (replaces prompt()) -----------------------------
  asVal(e: Event): string { return (e.target as HTMLInputElement | HTMLSelectElement).value; }
  closeForm(): void { this.form.set(null); }
  private openForm(f: ActiveForm): void { this.previewResult.set(null); this.applyResult.set(null); this.form.set(f); }
  submitForm(): void {
    const f = this.form(); if (!f) return;
    const v: Record<string, string> = {};
    for (const fld of f.fields) v[fld.key] = (fld.value ?? '').trim();
    this.form.set(null);
    f.run(v);
  }
  private static readonly FS_OPTS = ['ext4', 'ext3', 'ext2', 'xfs', 'btrfs', 'vfat', 'swap'];

  // ---- op builders (gparted-style; inline forms) ----------------------------
  opMklabel(d: Device, table: string): void {
    this.openForm({
      title: `Initialise ${d.path} as ${table.toUpperCase()}`, icon: 'dangerous', submitLabel: `Create ${table.toUpperCase()} table`,
      danger: true, fields: [],
      note: `This writes a fresh ${table.toUpperCase()} partition table and discards the current layout of ${d.path}. All partitions on it are lost.`,
      run: () => this.push({ op: 'mklabel', device: d.path, table, _desc: `Create ${table} table on ${d.path}` }),
    });
  }
  opAddPartition(d: Device): void {
    this.openForm({
      title: `New partition on ${d.path}`, icon: 'add', submitLabel: 'Add to queue',
      fields: [
        { key: 'size', label: 'Size', type: 'text', value: '100%', hint: 'e.g. 10GiB, 512MiB, or 100% for the rest' },
        { key: 'fstype', label: 'Filesystem', type: 'select', value: 'ext4', options: [...HostDisksComponent.FS_OPTS, ''] },
        { key: 'label', label: 'Label', type: 'text', value: '', hint: 'optional' },
        { key: 'mount', label: 'Mount point', type: 'text', value: '', placeholder: '/data', hint: 'optional' },
      ],
      run: (v) => {
        const size = v['size']; if (!size) return;
        const fstype = v['fstype'];
        const num = this.nextNum(d.path);
        const tgt = this.partPath(d.path, num);
        const end = size === '100%' ? '100%' : size;
        this.push({ op: 'mkpart', device: d.path, ptype: 'primary', fstype: fstype || 'ext4', start: '1MiB', end,
          _desc: `New ${size} ${fstype || 'ext4'} partition on ${d.path} (→ ${tgt})` });
        if (fstype) this.push({ op: 'mkfs', device: d.path, target: tgt, fstype, _desc: `Format ${tgt} as ${fstype}` });
        if (v['label'] && fstype) this.push({ op: 'label', device: d.path, target: tgt, fstype, label: v['label'], _desc: `Label ${tgt} = "${v['label']}"` });
        if (v['mount']) this.push({ op: 'mount', device: d.path, target: tgt, mountpoint: v['mount'], _desc: `Mount ${tgt} at ${v['mount']}` });
      },
    });
  }
  opFormat(d: Device, p: Partition): void {
    this.openForm({
      title: `Format ${p.path}`, icon: 'edit_note', submitLabel: 'Add to queue', danger: true,
      fields: [{ key: 'fstype', label: 'Filesystem', type: 'select', value: p.fstype && HostDisksComponent.FS_OPTS.includes(p.fstype) ? p.fstype : 'ext4',
        options: HostDisksComponent.FS_OPTS, hint: 'this erases all data on the partition' }],
      run: (v) => {
        const fstype = v['fstype']; if (!fstype) return;
        this.push({ op: 'mkfs', device: d.path, target: p.path, fstype, _desc: `Format ${p.path} as ${fstype}` });
      },
    });
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
    this.openForm({
      title: `Resize ${p.path} (${p.fstype})`, icon: 'open_in_full', submitLabel: 'Add to queue',
      fields: [{ key: 'size', label: 'New size (MiB)', type: 'number', value: String(curMib),
        hint: `current ≈ ${curMib} MiB · smaller shrinks, larger grows` }],
      run: (v) => {
        const sizeMib = Number(v['size']);
        if (!sizeMib || sizeMib <= 0) return;
        if (sizeMib === curMib) { alert('Same size — nothing to do.'); return; }
        const grow = sizeMib > curMib;
        this.push({ op: 'resize', device: d.path, target: p.path, num, fstype: p.fstype!, start_mib: startMib, size_mib: sizeMib, grow,
          _desc: `${grow ? 'Grow' : 'Shrink'} ${p.path} (${p.fstype}) ${curMib} → ${sizeMib} MiB` });
      },
    });
  }
  opLabel(d: Device, p: Partition): void {
    this.openForm({
      title: `Label ${p.path}`, icon: 'sell', submitLabel: 'Add to queue',
      fields: [{ key: 'label', label: 'Label', type: 'text', value: p.label || '', hint: 'filesystem label' }],
      run: (v) => this.push({ op: 'label', device: d.path, target: p.path, fstype: p.fstype || 'ext4', label: v['label'], _desc: `Label ${p.path} = "${v['label']}"` }),
    });
  }
  opMount(d: Device, p: Partition): void {
    this.openForm({
      title: `Mount ${p.path}`, icon: 'drive_folder_upload', submitLabel: 'Add to queue',
      fields: [{ key: 'mount', label: 'Mount point', type: 'text', value: '/mnt/' + p.name, placeholder: '/mnt/data' }],
      run: (v) => { if (v['mount']) this.push({ op: 'mount', device: d.path, target: p.path, mountpoint: v['mount'], _desc: `Mount ${p.path} at ${v['mount']}` }); },
    });
  }
  opDelete(d: Device, p: Partition): void {
    const num = Number((p.name.match(/(\d+)$/) || [])[1]);
    if (!num) { alert('Cannot determine partition number.'); return; }
    this.openForm({
      title: `Delete ${p.path}`, icon: 'delete_forever', submitLabel: 'Delete partition',
      danger: true, fields: [],
      note: `This removes partition ${num} from ${d.path} and erases its contents.`,
      run: () => this.push({ op: 'delete', device: d.path, num, _desc: `Delete ${p.path}` }),
    });
  }
  /** Grow an LVM logical volume ONLINE (lvextend --resizefs) — works while the
   *  filesystem is mounted, so no unmount is needed (unlike a raw partition). */
  opLvextend(p: Partition): void {
    this.openForm({
      title: `Grow LV ${p.path} (online)`, icon: 'unfold_more', submitLabel: 'Add to queue',
      fields: [{ key: 'size', label: 'Grow by', type: 'text', value: '+100%FREE',
        hint: 'e.g. +5G, or +100%FREE for all free VG space · must start with "+"' }],
      run: (v) => {
        const size = v['size']; if (!size) return;
        if (!size.startsWith('+')) { alert('Only online GROW is supported here — the size must start with "+".'); return; }
        this.push({ op: 'lvextend', device: p.path, target: p.path, size, _desc: `Grow LV ${p.path} by ${size} (online, fs kept mounted)` });
      },
    });
  }
  /** Shrink an LVM logical volume (lvreduce --resizefs): the filesystem is shrunk
   *  first, so — unlike the online grow — the LV must be UNMOUNTED. */
  opLvreduce(p: Partition): void {
    const cur = p.size_bytes ? Math.floor(p.size_bytes / 1048576) : 0;
    if (!cur) { alert('Cannot determine current LV size.'); return; }
    this.openForm({
      title: `Shrink LV ${p.path}`, icon: 'unfold_less', submitLabel: 'Add to queue', danger: true,
      fields: [{ key: 'size', label: 'New size (MiB)', type: 'number', value: String(cur),
        hint: `current ≈ ${cur} MiB · must be smaller · fs shrunk first (LV must be unmounted)` }],
      run: (v) => {
        const mib = Number(v['size']);
        if (!mib || mib <= 0) return;
        if (mib >= cur) { alert('Reduce means a smaller size than the current one.'); return; }
        this.push({ op: 'lvreduce', device: p.path, target: p.path, size: `${mib}M`, _desc: `Shrink LV ${p.path} ${cur} → ${mib} MiB (fs first)` });
      },
    });
  }
  // ---- ZFS op builders (pools/datasets; sizing = a property, not geometry) --
  opZpoolCreate(l: DiskLayout): void {
    this.openForm({
      title: 'Create ZFS pool', icon: 'dataset', submitLabel: 'Add to queue', danger: true,
      note: 'The selected block devices are wiped and turned into a ZFS pool.',
      fields: [
        { key: 'name', label: 'Pool name', type: 'text', value: 'tank' },
        { key: 'raid', label: 'Layout', type: 'select', value: '', options: ['', 'mirror', 'raidz', 'raidz2', 'raidz3'], hint: 'empty = stripe' },
        { key: 'vdevs', label: 'Devices', type: 'text', value: '', placeholder: '/dev/sdb /dev/sdc', hint: 'space-separated block devices (vdevs)' },
      ],
      run: (v) => {
        const name = v['name']; const vdevs = (v['vdevs'] || '').split(/\s+/).filter(Boolean);
        if (!name || !vdevs.length) return;
        this.push({ op: 'zpool_create', name, raid: v['raid'] || undefined, vdevs, _desc: `Create pool ${name} (${v['raid'] || 'stripe'}) on ${vdevs.join(', ')}` });
      },
    });
  }
  opZpoolDestroy(name: string): void {
    this.openForm({ title: `Destroy pool ${name}`, icon: 'delete_forever', submitLabel: 'Destroy pool', danger: true, fields: [],
      note: `This destroys the ZFS pool ${name} and every dataset in it.`,
      run: () => this.push({ op: 'zpool_destroy', name, _desc: `Destroy pool ${name}` }) });
  }
  opZfsCreate(pool: string): void {
    this.openForm({
      title: `New dataset in ${pool}`, icon: 'create_new_folder', submitLabel: 'Add to queue',
      fields: [
        { key: 'name', label: 'Name', type: 'text', value: pool + '/', hint: 'full name, e.g. tank/data' },
        { key: 'mountpoint', label: 'Mount point', type: 'text', value: '', placeholder: '/tank/data', hint: 'optional' },
      ],
      run: (v) => {
        const name = v['name']; if (!name || name.endsWith('/')) return;
        this.push({ op: 'zfs_create', name, mountpoint: v['mountpoint'] || undefined, _desc: `Create dataset ${name}` + (v['mountpoint'] ? ` at ${v['mountpoint']}` : '') });
      },
    });
  }
  /** The ZFS "resize": set a size PROPERTY (quota/refquota cap, reservation guarantee)
   *  — online and non-destructive, no unmount. */
  opZfsSet(ds: ZfsDataset): void {
    const cur = ds.refquota_bytes ?? ds.quota_bytes ?? null;
    this.openForm({
      title: `Resize ${ds.name}`, icon: 'straighten', submitLabel: 'Add to queue',
      fields: [
        { key: 'property', label: 'Property', type: 'select', value: 'refquota', options: ['refquota', 'quota', 'refreservation', 'reservation'], hint: 'quota = logical cap · reservation = guaranteed' },
        { key: 'size', label: 'Size', type: 'text', value: cur != null ? this.fmtZ(cur) : '', placeholder: '8G', hint: 'e.g. 8G, 500M' },
      ],
      run: (v) => { const size = v['size']; if (!size) return;
        this.push({ op: 'zfs_set', name: ds.name, property: v['property'], size, _desc: `Set ${v['property']}=${size} on ${ds.name}` }); },
    });
  }
  opZfsSnapshot(name: string): void {
    this.openForm({ title: `Snapshot ${name}`, icon: 'photo_camera', submitLabel: 'Add to queue',
      fields: [{ key: 'snap', label: 'Snapshot name', type: 'text', value: 'snap1', hint: `becomes ${name}@<name>` }],
      run: (v) => { if (v['snap']) this.push({ op: 'zfs_snapshot', name, snap: v['snap'], _desc: `Snapshot ${name}@${v['snap']}` }); } });
  }
  opZfsRollback(snap: string): void {
    this.openForm({ title: `Roll back to ${snap}`, icon: 'history', submitLabel: 'Roll back', danger: true, fields: [],
      note: `Rolls the dataset back to ${snap} and destroys any newer snapshots.`,
      run: () => this.push({ op: 'zfs_rollback', name: snap, _desc: `Roll back to ${snap}` }) });
  }
  opZfsDestroy(name: string): void {
    const isSnap = name.includes('@');
    this.openForm({ title: `Destroy ${name}`, icon: 'delete_forever', submitLabel: 'Destroy', danger: true, fields: [],
      note: `This destroys ${isSnap ? 'snapshot ' + name : 'dataset ' + name + ' and all its children/snapshots'}.`,
      run: () => this.push({ op: 'zfs_destroy', name, recursive: !isSnap, _desc: `Destroy ${name}` }) });
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
    this.openForm({
      title: 'Scratch loopback test disk', icon: 'science', submitLabel: 'Create',
      fields: [{ key: 'mb', label: 'Size (MB)', type: 'number', value: '256', hint: 'a throwaway loop device for safe testing' }],
      run: (v) => {
        const mb = Number(v['mb']); if (!mb) return;
        this.scratchMsg.set('Creating scratch disk…');
        this.http.post<any>(`${this.base()}/disks/scratch`, { action: 'create', size_mb: mb }).subscribe({
          next: (r) => { this.scratchMsg.set(r?.ok ? `Scratch disk ${r.device} created — Rescan to see it. (Destroy later via losetup -d.)` : ('scratch failed: ' + (r?.error || ''))); this.load(); },
          error: (e) => this.scratchMsg.set(e?.error?.detail ?? 'scratch failed'),
        });
      },
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
  /** Compact ZFS-style size (e.g. 8G) for prefilling a quota/reservation form. */
  fmtZ(bytes: number): string {
    const u = ['', 'K', 'M', 'G', 'T', 'P']; let i = 0; let n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${Math.round(n)}${u[i]}`;
  }
  datasetsOf(l: DiskLayout, pool: string): ZfsDataset[] {
    return (l.zfs?.datasets || []).filter((d) => d.name === pool || d.name.startsWith(pool + '/') || d.name.startsWith(pool + '@'));
  }
  zfsDepth(name: string): number { return (name.split('@')[0].match(/\//g) || []).length; }
  zfsLeaf(name: string): string {
    if (name.includes('@')) return '@' + name.split('@')[1];
    const parts = name.split('/'); return parts.length > 1 ? parts[parts.length - 1] : name;
  }
  poolHealthColor(h: string): string { return h === 'ONLINE' ? '#3fae6b' : (h === 'DEGRADED' ? '#d0a03c' : '#d05656'); }
  /** The visual disk: proportional boxes for partitions + unallocated gaps, with
   *  nested children drawn INSIDE their parent (gparted's extended-container look). */
  segsFor(d: Device): Seg[] {
    const total = d.size_bytes
      || (d.partitions.reduce((a, p) => a + (p.size_bytes || 0), 0) + d.free.reduce((a, f) => a + (f.size_bytes || 0), 0)) || 1;
    const seg = (p: Partition, of: number): Seg => {
      const sz = p.size_bytes || 0;
      return {
        kind: 'part', key: p.path, name: (p.name || '').replace(/^.*\//, ''),
        fs: p.fstype || p.kind || '?', sizeLabel: this.fmt(sz),
        pct: (sz / (of || 1)) * 100,
        usedPct: p.used_bytes != null && sz > 0 ? Math.min(100, (p.used_bytes / sz) * 100) : 0,
        color: this.fsColor(p.fstype, p.kind),
        title: `${p.path}\n${p.fstype || p.kind || '?'} · ${this.fmt(sz)}${p.mountpoint ? ' · ' + p.mountpoint : ''}`
          + (p.used_bytes != null ? `\nused ${this.fmt(p.used_bytes)} · unused ${this.fmt(this.unusedBytes(p))}` : ''),
        children: (p.children || []).map((c) => seg(c, sz)),
      };
    };
    const segs: Seg[] = d.partitions.map((p) => seg(p, total));
    for (const f of this.freeOf(d)) {
      segs.push({ kind: 'free', key: f.key, name: 'unallocated', fs: 'unallocated',
        sizeLabel: this.fmt(f.size_bytes), pct: ((f.size_bytes || 0) / total) * 100, usedPct: 0,
        color: 'var(--mat-sys-outline-variant)', title: `unallocated · ${this.fmt(f.size_bytes)}`, children: [] });
    }
    return segs;
  }

  /** Unallocated space. A disk with no partition table reports no gaps, but gparted
   *  still draws the WHOLE disk as one unallocated area — so synthesize that. */
  private freeOf(d: Device): { key: string; size_bytes: number | null }[] {
    const gaps = (d.free || [])
      .map((f, i) => ({ key: `free:${i}`, size_bytes: f.size_bytes }))
      .filter((f) => (f.size_bytes || 0) > 1048576);
    if (!gaps.length && !(d.partitions || []).length) return [{ key: 'free:whole', size_bytes: d.size_bytes }];
    return gaps;
  }

  /** The partition list rows: partitions (nested) then the unallocated gaps — the
   *  gparted column set (Partition / File System / Mount / Label / Size / Used / Unused / Flags). */
  rowsFor(d: Device): { key: string; name: string; fs: string; mount: string; label: string; size: string;
    used: string; unused: string; flags: string[]; depth: number; color: string; free: boolean;
    busy: boolean; kids: boolean }[] {
    const out: any[] = [];
    const walk = (p: Partition, depth: number) => {
      out.push({
        key: p.path, name: p.path, fs: p.fstype || (p.kind !== 'part' ? p.kind : '—'),
        mount: p.mountpoint || '', label: p.label || '', size: this.fmt(p.size_bytes),
        used: p.used_bytes != null ? this.fmt(p.used_bytes) : '—',
        unused: p.used_bytes != null ? this.fmt(this.unusedBytes(p)) : '—',
        flags: p.flags || [], depth, color: this.fsColor(p.fstype, p.kind), free: false,
        busy: p.busy, kids: !!(p.children || []).length,
      });
      for (const c of p.children || []) walk(c, depth + 1);
    };
    for (const p of d.partitions) walk(p, 0);
    for (const f of this.freeOf(d)) {
      out.push({ key: f.key, name: 'unallocated', fs: 'unallocated', mount: '', label: '',
        size: this.fmt(f.size_bytes), used: '—', unused: this.fmt(f.size_bytes), flags: [], depth: 0,
        color: '', free: true, busy: false, kids: false });
    }
    return out;
  }
  private unusedBytes(p: Partition): number {
    if (p.used_bytes == null) return 0;
    return Math.max(0, (p.size_bytes || 0) - p.used_bytes);
  }

  // ---- selection-driven toolbar (gparted acts on the selected partition) -----
  /** Pale interior of a partition box; `used` is the darker filled part. */
  tint(color: string): string { return `color-mix(in srgb, ${color} 13%, transparent)`; }
  used(color: string): string { return `color-mix(in srgb, ${color} 55%, transparent)`; }

  /** The selected row resolved back to its Partition (null for unallocated/none). */
  selPart(): Partition | null {
    const key = this.sel(); const d = this.dev();
    if (!key || !d || key.startsWith('free:')) return null;
    const find = (ps: Partition[]): Partition | null => {
      for (const p of ps) { if (p.path === key) return p; const c = find(p.children || []); if (c) return c; }
      return null;
    };
    return find(d.partitions);
  }
  selFree(): boolean { return (this.sel() || '').startsWith('free:'); }
  selBusy(): boolean { return !!this.selPart()?.busy; }

  /** New needs unallocated space AND a partition table — on a blank disk gparted
   *  greys it out until you create a table (the statusbar's "New GPT table"), so a
   *  queued mklabel for this device counts too. */
  canNew(): boolean {
    const d = this.dev(); if (!d || this.protectedDev(d)) return false;
    const hasTable = !!d.table || this.ops().some((o) => o.op === 'mklabel' && o.device === d.path);
    return hasTable && (this.selFree() || !d.partitions.length);
  }
  canDelete(): boolean { const p = this.selPart(); return !!p && p.kind === 'part' && !p.busy; }
  canFormat(): boolean { const p = this.selPart(); return !!p && (p.kind === 'part' || p.kind === 'crypt') && !p.busy; }
  canMount(): boolean { const p = this.selPart(); return !!p && (p.busy || !!p.fstype); }
  canResizeSel(): boolean {
    const p = this.selPart(); if (!p) return false;
    if (p.kind === 'lvm') return true;                       // LVM: grow online, shrink unmounted
    return this.canResize(p);                                 // raw partition: ext + unmounted
  }
  resizeTip(): string {
    const p = this.selPart(); if (!p) return 'Select a partition to resize';
    if (p.kind === 'lvm') return 'Resize this logical volume (grow works online, shrink needs it unmounted)';
    return this.resizeHint(p);
  }
  mountTip(): string {
    const p = this.selPart();
    if (!p) return 'Select a partition';
    return p.busy ? `Unmount ${p.path} (mounted at ${p.mountpoint})` : `Mount ${p.path}`;
  }

  tbNew(): void { const d = this.dev(); if (d) this.opAddPartition(d); }
  tbDelete(): void { const d = this.dev(); const p = this.selPart(); if (d && p) this.opDelete(d, p); }
  tbFormat(): void { const d = this.dev(); const p = this.selPart(); if (d && p) this.opFormat(d, p); }
  tbLabel(): void { const d = this.dev(); const p = this.selPart(); if (d && p) this.opLabel(d, p); }
  tbMount(): void {
    const d = this.dev(); const p = this.selPart(); if (!d || !p) return;
    if (p.busy) this.unmount(d, p); else this.opMount(d, p);
  }
  tbResize(): void {
    const d = this.dev(); const p = this.selPart(); if (!d || !p) return;
    if (p.kind !== 'lvm') { this.opResize(d, p); return; }
    // LVM: one dialog, grow (online) or shrink (needs unmount) decided by the size
    const cur = p.size_bytes ? Math.floor(p.size_bytes / 1048576) : 0;
    this.openForm({
      title: `Resize LV ${p.path}`, icon: 'unfold_more', submitLabel: 'Add to queue',
      fields: [{ key: 'size', label: 'New size (MiB)', type: 'number', value: String(cur),
        hint: `current ≈ ${cur} MiB · larger grows ONLINE · smaller shrinks (LV must be unmounted)` }],
      run: (v) => {
        const mib = Number(v['size']); if (!mib || mib === cur) return;
        if (mib > cur) {
          this.push({ op: 'lvextend', device: p.path, target: p.path, size: `+${mib - cur}M`,
            _desc: `Grow LV ${p.path} ${cur} → ${mib} MiB (online)` });
        } else {
          this.push({ op: 'lvreduce', device: p.path, target: p.path, size: `${mib}M`,
            _desc: `Shrink LV ${p.path} ${cur} → ${mib} MiB (fs first)` });
        }
      },
    });
  }
  /** gparted's Undo: drop the LAST staged operation (Undo all lives in the queue). */
  undoLast(): void { this.ops.update((l) => l.slice(0, -1)); this.previewResult.set(null); this.applyResult.set(null); }
}
