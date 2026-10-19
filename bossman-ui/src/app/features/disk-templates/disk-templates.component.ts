import { Component, OnInit, OnDestroy, computed, inject, signal } from '@angular/core';
import { DecimalPipe, UpperCasePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { RouterLink } from '@angular/router';
import { MatDialog, MatDialogModule } from '@angular/material/dialog';
import { DeployVmWizardComponent, DeployWizardData } from '../vm-deploy/deploy-vm-wizard.component';
import { DiskImage, ImagesService, RestoreJob, Vm } from '../../core/services/images.service';
import { GROWABLE_ROLES, GrowSizing, GrowSizingComponent } from '../../shared/grow-sizing/grow-sizing.component';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';

/** Roles whose size a grow policy can adjust; the rest (esp/boot/swap/bios_boot) stay fixed. */

/**
 * Disk templates / bare-metal provisioning. Left: captured templates (mark one active). Middle: the
 * active template's disk — fixed volumes locked, growable ones (root/var/home, LVM-aware) as percentage
 * inputs that must sum to 100. Right: the deployment wizard (target, disk, optional VM host, roles — it
 * creates the planned host and arms the install) and the live restore-jobs list. Roles are assigned in the
 * wizard or afterwards through the host's Management tab (link per job). See docs/pxe-baremetal-imaging.md.
 */
@Component({
  selector: 'app-disk-templates',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, MatDialogModule, RouterLink, DecimalPipe, UpperCasePipe, GrowSizingComponent, BlockedReasonDirective],
  template: `
    <div class="dt-wrap">
      <!-- ── Templates ────────────────────────────────────────────── -->
      <section class="dt-col">
        <h2>Disk templates</h2>

        <!-- Import an existing disk image (vmdk/qcow2/raw) staged in the lab as a golden template. -->
        <div class="dt-import">
          @if (!importOpen()) {
            <button mat-button (click)="openImport()"><mat-icon>upload_file</mat-icon> Import existing image</button>
          } @else {
            <div class="dt-import-form">
              <b>Import image</b>
              <label class="dt-fld"><span>Source file (in /srv/templates)</span>
                <select [(ngModel)]="imp.source_file">
                  <option value="" disabled>— select —</option>
                  @for (s of sources(); track s) { <option [value]="s">{{ s }}</option> }
                </select>
              </label>
              <label class="dt-fld"><span>Template name</span><input [(ngModel)]="imp.name" placeholder="e.g. debian13-base" /></label>
              <div class="dt-row">
<button mat-flat-button color="primary" [disabled]="importing()" [bmBlocked]="importing() ? '' : importBlocked()" (click)="doImport()">Import</button>
                <button mat-button (click)="importOpen.set(false)">Cancel</button>
              </div>
              @if (sources().length === 0) { <p class="dt-muted">No images found in /srv/templates (.vmdk/.qcow2/.raw/.img).</p> }
              @if (importErr()) { <p class="dt-err">{{ importErr() }}</p> }
            </div>
          }
        </div>

        @if (images().length === 0) { <p class="dt-muted">No captured templates yet.</p> }
        @for (img of images(); track img.id) {
          <div class="dt-card" [class.dt-sel]="selected()?.id === img.id" (click)="select(img)">
            <div class="dt-row">
              <mat-icon>{{ img.is_active ? 'star' : 'save' }}</mat-icon>
              <b>{{ img.name }}</b>
              <span class="dt-badge" [class.ready]="img.status === 'ready'">{{ img.status }}</span>
            </div>
            <div class="dt-sub">
              {{ (img.disk_size / 1073741824) | number: '1.0-1' }} GiB · {{ img.volumes.length }} Volumes
              @if (img.firmware !== 'unknown') {
                <span class="dt-fw" [class.uefi]="img.firmware === 'uefi'">{{ img.firmware | uppercase }}</span>
              }
            </div>
            @if (img.status === 'capturing') {
              <div class="dt-prog">
                <div class="dt-prog-bar"><span [style.width.%]="progressPct(img)"></span></div>
                <div class="dt-sub">{{ img.progress || 'Import running…' }}</div>
              </div>
            }
            @if (img.status === 'failed' && img.error) { <div class="dt-err">{{ img.error }}</div> }
            <span class="bm-why" [attr.title]="img.status === 'ready' ? null : 'The template is ' + img.status + ' — only a ready one can be activated'"><button
                mat-button [bmBlocked]="img.status !== 'ready' ? 'Only a ready image can be the active template' : ''" bmBlockedMode="tip" (click)="toggleActive(img, $event)">
              {{ img.is_active ? 'Active' : 'Mark active' }}
            </button></span>
          </div>
        }
      </section>

      <!-- ── Disk / grow policy of the selected template ──────────── -->
      <section class="dt-col">
        <h2>Disk geometry</h2>
        @if (!selected()) { <p class="dt-muted">Select a template.</p> }
        @if (selected(); as img) {
          <p class="dt-muted">Layout comes from the image (partclone). Only the sizes of the growable volumes are editable.</p>
          <bm-grow-sizing [volumes]="img.volumes" [policy]="img.grow_policy" [mode]="img.grow_mode === 'absolute' ? 'absolute' : 'percent'"
                          (changed)="grow.set($event)" />
          @if (hasGrowable()) {
            <button mat-button [bmBlocked]="growBlocked()" (click)="saveGrow()">Save grow policy</button>
            @if (err()) { <p class="dt-err">{{ err() }}</p> }
          }
        }
      </section>

      <!-- ── Provision a target + jobs ────────────────────────────── -->
      <section class="dt-col">
        <h2>Provision</h2>
        <button mat-flat-button color="primary" class="dt-wizard-btn" (click)="openWizard()">
          <mat-icon>auto_awesome</mat-icon> New deployment (wizard)
        </button>
        <p class="dt-muted">The one install wizard (also under Deploy ▸ Install hosts), opened on
          {{ selected()?.name || 'the chosen image' }}: VM or bare metal, this deployment's own volume sizing, network,
          roles and a playbook — every check runs before anything is created.</p>

        <h3>Restore jobs</h3>
        @for (j of jobs(); track j.id) {
          <div class="dt-job">
            <span class="dt-badge" [class.ready]="j.status === 'done'" [class.bad]="j.status === 'failed'">{{ j.status }}</span>
            <b>{{ j.target_hostname }}</b> <span class="dt-muted">{{ j.target_mac || '(wildcard)' }}</span> · step {{ j.step_index }}
            @if (j.agent_id) { <a mat-button [routerLink]="['/hosts', j.agent_id]">Management</a> }
            @if (j.status === 'pending' || j.status === 'running') {
              <button mat-button (click)="cancelJob(j)">Cancel</button>
            } @else {
              <button mat-icon-button title="Delete" (click)="deleteJob(j)"><mat-icon>delete</mat-icon></button>
            }
            @if (j.error) { <div class="dt-err">{{ j.error }}</div> }
          </div>
        }
      </section>
    </div>

    <!-- ── Nested-virt lab (QEMU im pxe-Container) ──────────────────────── -->
    <section class="dt-lab">
      <h2>Lab (nested virt)</h2>
      <p class="dt-muted">Build a template from an ISO, or end-to-end test the active template via a diskless PXE target — QEMU runs in the pxe container, console over noVNC.</p>
      @if (lab(); as l) {
        @if (!l.available) {
          <p class="dt-err">Lab unavailable — {{ l.reason }}
            <button mat-button (click)="checkLab()">Check again</button></p>
        }
      } @else {
        <p class="dt-muted">Checking whether the lab is available…</p>
      }
      <div class="dt-lab-actions">
        <div class="dt-lab-form">
          <b>Install template from ISO</b>
          <input [(ngModel)]="inst.name" placeholder="VM name (e.g. tmpl-deb12)" aria-label="VM name" />
          <input [(ngModel)]="inst.iso" placeholder="ISO file (in the ISO dir)" aria-label="ISO file" />
          <input [(ngModel)]="inst.disk" placeholder="Disk file (e.g. tmpl-deb12.raw)" aria-label="Disk file" />
          <button mat-flat-button color="primary" [bmBlocked]="installBlocked()" (click)="startInstall()">Install + console</button>
        </div>
        <div class="dt-lab-form">
          <b>PXE-test the active template</b>
          <p class="dt-muted">Creates a diskless VM on the ens19 segment that PXE-restores the active template.</p>
          <button mat-flat-button [bmBlocked]="pxeTestBlocked()" (click)="startPxeTest()">Start PXE test</button>
        </div>
      </div>
      @if (labErr()) { <p class="dt-err">{{ labErr() }}</p> }
      <h3>Running VMs</h3>
      <!-- "No running VMs" is only a claim while the lab answers; an unavailable lab is said above, not as an empty list. -->
      @if (lab()?.available && vms().length === 0) { <p class="dt-muted">No running lab VMs.</p> }
      @for (v of vms(); track v.name) {
        <div class="dt-job">
          <span class="dt-badge ready">{{ v.kind }}</span>
          <b>{{ v.name }}</b> <span class="dt-muted">Display :{{ v.display }} · {{ v.disk }}</span>
          <button mat-button (click)="openConsole(v.name)">Console</button>
          <button mat-button (click)="stopVm(v.name)">Stop</button>
        </div>
      }
    </section>

    <!-- ── Finished deployments: a closable log box ─────────────────────── -->
    @if (logOpen() && finishedJobs().length) {
      <section class="dt-logbox">
        <div class="dt-logbox-head">
          <h2>Finished deployments <span class="dt-muted">({{ finishedJobs().length }})</span></h2>
          <button mat-icon-button title="Close" (click)="closeLog()"><mat-icon>close</mat-icon></button>
        </div>
        @for (j of finishedJobs(); track j.id) {
          <details class="dt-logentry">
            <summary>
              <span class="dt-badge" [class.ready]="j.status === 'done'" [class.bad]="j.status === 'failed'">{{ j.status }}</span>
              <b>{{ j.target_hostname }}</b>
              <span class="dt-muted">{{ j.target_mac || '(wildcard)' }}</span>
              @if (j.error) { <span class="dt-err">{{ j.error }}</span> }
            </summary>
            <pre class="dt-log">{{ j.log || '(no log captured)' }}</pre>
          </details>
        }
      </section>
    }
  `,
  styles: [`
    .dt-wrap { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1rem; padding: 1rem; }
    .dt-lab { padding: 0 1rem 1.5rem; } .dt-lab h2 { font-size: 1rem; margin: .5rem 0; }
    .dt-lab-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: .5rem 0; }
    .dt-lab-form { display: flex; flex-direction: column; gap: .35rem; border: 1px solid #3334; border-radius: 8px; padding: .7rem; }
    .dt-lab-form input { padding: .3rem; }
    .dt-wizard-btn { margin-bottom: .4rem; }
    .dt-logbox { margin: 0 1rem 1.5rem; border: 1px solid #3334; border-radius: 8px; padding: .5rem .8rem; }
    .dt-logbox-head { display: flex; align-items: center; justify-content: space-between; }
    .dt-logbox-head h2 { font-size: 1rem; margin: .3rem 0; }
    .dt-logentry { border-top: 1px solid #3332; padding: .3rem 0; }
    .dt-logentry summary { cursor: pointer; display: flex; align-items: center; gap: .5rem; font-size: .85rem; }
    .dt-log { margin: .4rem 0 0; padding: .5rem; background: #0002; border-radius: 6px; font-size: .75rem;
      max-height: 260px; overflow: auto; white-space: pre-wrap; }
    .dt-import { margin-bottom: .6rem; }
    .dt-import-form { display: flex; flex-direction: column; gap: .35rem; border: 1px solid #4a90d9; border-radius: 8px; padding: .7rem; }
    .dt-import-form select, .dt-import-form input { padding: .3rem; }
    .dt-opt { color: var(--mat-sys-on-surface-variant); font-weight: 400; font-size: .8em; }
    .dt-prog { margin: .3rem 0; }
    .dt-prog-bar { height: 6px; background: #8883; border-radius: 3px; overflow: hidden; }
    .dt-prog-bar span { display: block; height: 100%; background: #4a90d9; transition: width .4s ease; }
    .dt-col h2 { font-size: 1rem; margin: 0 0 .5rem; }
    .dt-muted { color: var(--mat-sys-on-surface-variant, #888); font-size: .85rem; }
    .dt-card { border: 1px solid #3334; border-radius: 8px; padding: .6rem; margin-bottom: .5rem; cursor: pointer; }
    .dt-sel { border-color: #4a90d9; }
    .dt-row { display: flex; align-items: center; gap: .4rem; }
    .dt-sub { font-size: .8rem; color: var(--mat-sys-on-surface-variant); margin: .2rem 0; }
    .dt-badge { font-size: .7rem; padding: .1rem .4rem; border-radius: 4px; background: #8883; }
    .dt-badge.ready { background: #2e7d3244; } .dt-badge.bad { background: #c6282844; }
    .dt-vol { display: flex; justify-content: space-between; align-items: center; padding: .3rem 0; border-bottom: 1px solid #3332; }
    .dt-vol-name { display: flex; align-items: center; gap: .35rem; }
    .dt-lvm { font-size: .7rem; color: #4a90d9; } .dt-fs { font-size: .7rem; color: var(--mat-sys-on-surface-variant); }
    .dt-fw { font-size: .65rem; font-weight: 600; letter-spacing: .04em; padding: .05rem .3rem;
      border-radius: 4px; margin-left: .4rem; background: #8883; color: var(--mat-sys-on-surface); }
    .dt-fw.uefi { background: color-mix(in srgb, #4a90d9 28%, transparent); }
    .dt-pct input { width: 3.5rem; } .dt-fixed { font-size: .8rem; color: var(--mat-sys-on-surface-variant); }
    .dt-sum { margin: .5rem 0; } .dt-sum.bad { color: #d9534f; }
    .dt-mode { display: inline-flex; border: 1px solid #3335; border-radius: 6px; overflow: hidden; margin-bottom: .5rem; }
    .dt-mode button { border: 0; background: transparent; color: inherit; padding: .25rem .7rem; cursor: pointer; font-size: .8rem; }
    .dt-mode button.on { background: color-mix(in srgb, #4a90d9 28%, transparent); }
    .dt-fld { display: flex; flex-direction: column; margin-bottom: .4rem; font-size: .85rem; }
    .dt-fld input, .dt-fld select { padding: .3rem; }
    .dt-err { color: #d9534f; } .dt-job { padding: .3rem 0; border-bottom: 1px solid #3332; font-size: .85rem; }
    code { font-family: ui-monospace, monospace; }
  `],
})
export class DiskTemplatesComponent implements OnInit, OnDestroy {
  private svc = inject(ImagesService);
  private dialog = inject(MatDialog);

  images = signal<DiskImage[]>([]);
  jobs = signal<RestoreJob[]>([]);
  vms = signal<Vm[]>([]);
  /** The lab's availability (null = not asked yet). Unavailable is a named state with its reason, never an empty list. */
  lab = signal<{ available: boolean; reason: string | null } | null>(null);
  selected = signal<DiskImage | null>(null);
  err = signal('');
  labErr = signal('');
  /** The sizing as the shared editor reports it (one value per volume, mode, and why it cannot be saved). */
  grow = signal<GrowSizing | null>(null);
  hasGrowable = computed(() => (this.selected()?.volumes ?? []).some((v) => GROWABLE_ROLES.has(v.role)));

  // Finished-deployments log box. Closable — but a dismiss only hides the deployments finished SO FAR; when
  // a new one finishes (the count grows past what was dismissed) the box comes back, because a permanent
  // "never show again" would defeat the point of a live log.
  finishedJobs = computed(() => this.jobs().filter((j) => j.status === 'done' || j.status === 'failed'));
  private dismissedAt = signal(0);
  logOpen = computed(() => this.finishedJobs().length > this.dismissedAt());
  closeLog(): void { this.dismissedAt.set(this.finishedJobs().length); }

  inst = { name: '', iso: '', disk: '' };
  activeImage = computed(() => this.images().find((i) => i.is_active) ?? null);

  // Import an existing disk image staged in the lab.
  importOpen = signal(false);
  sources = signal<string[]>([]);
  imp = { name: '', source_file: '' };
  importing = signal(false);
  importErr = signal('');

  private timer?: ReturnType<typeof setInterval>;

  ngOnInit(): void {
    this.reload();
    this.checkLab();
    this.timer = setInterval(() => {
      this.svc.jobs().subscribe((j) => this.jobs.set(j));
      // Re-list images so an import's capturing → ready (or failed) shows up live.
      this.svc.list().subscribe((imgs) => this.images.set(imgs));
      this.pollVms();
    }, 3000);
  }

  openImport(): void {
    this.importOpen.set(true);
    this.importErr.set('');
    this.svc.importSources().subscribe({
      next: (s) => this.sources.set(s),
      error: (e) => this.importErr.set(e?.error?.detail || 'Could not load sources'),
    });
  }

  doImport(): void {
    this.importErr.set('');
    this.importing.set(true);
    this.svc.importImage({ name: this.imp.name.trim(), source_file: this.imp.source_file }).subscribe({
      next: () => {
        this.importing.set(false);
        this.importOpen.set(false);
        this.imp = { name: '', source_file: '' };
        this.reload();   // the new image shows as 'capturing' and the poll flips it to 'ready'
      },
      error: (e) => { this.importing.set(false); this.importErr.set(e?.error?.detail || 'Import failed'); },
    });
  }
  ngOnDestroy(): void { if (this.timer) clearInterval(this.timer); }

  openWizard(): void {
    const data: DeployWizardData = { image: this.selected()?.name };
    this.dialog.open(DeployVmWizardComponent, { data, width: '1040px', maxWidth: '96vw', disableClose: true, autoFocus: false })
      .afterClosed().subscribe((deployed) => { if (deployed) this.reload(); });
  }

  /** Ask whether the lab can be used; only an available lab is polled for VMs. */
  checkLab(): void {
    this.lab.set(null);
    this.svc.labStatus().subscribe({
      next: (s) => { this.lab.set(s); if (s.available) this.pollVms(); },
      error: (e) => this.lab.set({ available: false, reason: e?.error?.detail || 'the status endpoint did not answer' }),
    });
  }

  private pollVms(): void {
    // The lab is optional and its container may stop at any time: polling only runs while it is available,
    // and a failing poll turns into the named unavailable state (with the server's reason), not an empty list.
    if (!this.lab()?.available) return;
    this.svc.listVms().subscribe({
      next: (v) => this.vms.set(v),
      error: (e) => { this.vms.set([]); this.lab.set({ available: false, reason: e?.error?.detail || 'listing VMs failed' }); },
    });
  }

  private slug(): string { return Math.random().toString(36).slice(2, 8); }
  private randMac(): string {
    // Locally-administered QEMU-style MAC (52:54:00 prefix) with a random tail.
    const b = () => Math.floor(Math.random() * 256).toString(16).padStart(2, '0');
    return `52:54:00:${b()}:${b()}:${b()}`;
  }

  openConsole(name: string): void {
    window.open(`/vm-console/${encodeURIComponent(name)}`, `vmc-${name}`, 'width=1024,height=768');
  }

  startInstall(): void {
    this.labErr.set('');
    this.svc.install({ name: this.inst.name.trim(), iso: this.inst.iso.trim(), disk: this.inst.disk.trim() }).subscribe({
      next: () => { const n = this.inst.name.trim(); this.inst = { name: '', iso: '', disk: '' }; this.pollVms(); this.openConsole(n); },
      error: (e) => this.labErr.set(e?.error?.detail || 'Install failed'),
    });
  }

  startPxeTest(): void {
    this.labErr.set('');
    const name = `pxe-test-${this.slug()}`;
    this.svc.pxeTest({ name, mac: this.randMac(), disk: `${name}.raw` }).subscribe({
      next: () => { this.pollVms(); this.openConsole(name); },
      error: (e) => this.labErr.set(e?.error?.detail || 'PXE test failed'),
    });
  }

  stopVm(name: string): void {
    this.svc.stopVm(name).subscribe({ next: () => this.pollVms(), error: (e) => this.labErr.set(e?.error?.detail || 'Stop failed') });
  }

  cancelJob(j: RestoreJob): void {
    this.svc.cancelJob(j.id).subscribe({ next: () => this.svc.jobs().subscribe((x) => this.jobs.set(x)), error: (e) => this.err.set(e?.error?.detail || 'Cancel failed') });
  }
  deleteJob(j: RestoreJob): void {
    this.svc.deleteJob(j.id).subscribe({ next: () => this.svc.jobs().subscribe((x) => this.jobs.set(x)), error: (e) => this.err.set(e?.error?.detail || 'Delete failed') });
  }

  private reload(): void {
    this.svc.list().subscribe((imgs) => {
      this.images.set(imgs);
      const active = imgs.find((i) => i.is_active) ?? imgs[0];
      if (active && !this.selected()) this.select(active);
    });
    this.svc.jobs().subscribe((j) => this.jobs.set(j));
  }

  /** Percent parsed from the trailing "· NN%" of the progress string (0 if none), for the bar width. */
  progressPct(img: DiskImage): number {
    const m = (img.progress || '').match(/(\d+)\s*%\s*$/);
    return m ? Math.max(0, Math.min(100, +m[1])) : 0;
  }

  select(img: DiskImage): void {
    this.selected.set(img);
    this.grow.set(null);
  }

  canSaveGrow(): boolean { return !this.growBlocked(); }

  // Why each action is refused ('' = allowed) — the button's [disabled] and its tooltip read this one answer.
  growBlocked(): string { return this.grow()?.error ?? ''; }
  importBlocked(): string {
    if (this.importing()) return 'Importing…';
    if (!this.imp.source_file) return 'Select a source file';
    return this.imp.name.trim() ? '' : 'Name the template';
  }
  private labBlocked(): string {
    const l = this.lab();
    if (!l) return 'Checking whether the lab is available…';
    return l.available ? '' : `Lab unavailable — ${l.reason}`;
  }
  installBlocked(): string {
    const missing = [['VM name', this.inst.name], ['ISO file', this.inst.iso], ['disk file', this.inst.disk]]
      .filter(([, v]) => !v.trim()).map(([k]) => k);
    return this.labBlocked() || (missing.length ? `Fill in ${missing.join(', ')} first` : '');
  }
  pxeTestBlocked(): string {
    return this.labBlocked() || (this.activeImage() ? '' : 'Mark a ready template active first');
  }

  toggleActive(img: DiskImage, ev: Event): void {
    ev.stopPropagation();
    this.svc.patch(img.id, { is_active: !img.is_active }).subscribe({
      next: () => this.reload(),
      error: (e) => this.err.set(e?.error?.detail || 'Activation failed'),
    });
  }

  saveGrow(): void {
    const img = this.selected();
    const g = this.grow();
    if (!img || !g || !this.canSaveGrow()) return;
    this.svc.patch(img.id, { grow_policy: g.policy, grow_mode: g.mode }).subscribe({
      next: (updated) => { this.selected.set(updated); this.reload(); },
      error: (e) => this.err.set(e?.error?.detail || 'Save failed'),
    });
  }


}
