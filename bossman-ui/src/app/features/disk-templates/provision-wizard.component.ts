import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { DecimalPipe, UpperCasePipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatCheckboxModule } from '@angular/material/checkbox';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { forkJoin } from 'rxjs';
import { DeploymentTemplate, DiskImage, ImageVolume, ImagesService, ProvisionNetwork, VmHost, VmPlacement } from '../../core/services/images.service';
import { OrchestrationService } from '../../core/services/orchestration.service';
import { ResourceService } from '../../core/services/resource.service';

/** Roles whose size a grow policy adjusts; the rest (esp/boot/swap) stay fixed — same set as the page. */
const GROWABLE = new Set(['root', 'var', 'home', 'data']);

interface DeployStepResult { label: string; ok: boolean; error?: string; }

/**
 * The provisioning wizard (docs/provisioning-wizard.md, Plan A) — the same shape as the Roles & Features
 * wizard: a left step list, one panel per step, Previous/Next, a Deploy step at the end.
 *
 * Target → Disk → Virtualization (optional VM target) → Roles → Review → Deploy. Deploy is a fixed
 * sequence over existing services:
 *   0. (optional) createVm on a registered hypervisor — returns the MAC to arm against
 *   1. createPlannedHost  — the target becomes a 'planned' Agent with an id
 *   2. arm                — links that host + the chosen template into a restore job
 *   3. resource.apply(role) per selected role — declares the binding on the planned host
 *
 * Step 3 only DECLARES intent (RoleResource.apply writes an OrchestrationPlanLink + desired state, it does
 * not need the host online). The role workflow converges when the new host first checks in — exactly the
 * operator's model ("assignment happens once the host exists and reports to Bossman"). A deployment template
 * (the Target-step dropdown + "Save template" on Review) bundles the disk + sizing + roles for reuse, so a
 * repeat deployment only needs a hostname/MAC.
 */
@Component({
  selector: 'app-provision-wizard',
  standalone: true,
  imports: [
    FormsModule, MatDialogModule, MatButtonModule, MatIconModule, MatCheckboxModule,
    MatProgressSpinnerModule, DecimalPipe, UpperCasePipe,
  ],
  template: `
    <div class="pw">
      <div class="pw-title">New deployment</div>
      <div class="pw-body">
        <nav class="pw-steps">
          @for (s of STEP_LABELS; track $index) {
            <div class="pw-step" [class.cur]="step() === $index" [class.done]="step() > $index"
                 (click)="goto($index)">
              <span class="pw-step-ic">@if (step() > $index) { <mat-icon>check</mat-icon> } @else { {{ $index + 1 }} }</span>
              {{ s }}
            </div>
          }
        </nav>

        <section class="pw-main">
          @switch (step()) {
            @case (0) {
              <h2>Target</h2>
              <p class="pw-lead">The machine to provision. It is created as a <b>planned</b> host; roles and
                config converge after it first boots and checks in.</p>
              @if (templates().length) {
                <label class="pw-fld"><span>Start from a saved template <span class="pw-opt">(prefills disk + roles)</span></span>
                  <select [ngModel]="fromTemplate()" (ngModelChange)="applyTemplate($event)">
                    <option [ngValue]="null">— none —</option>
                    @for (t of templates(); track t.id) { <option [ngValue]="t.id">{{ t.name }}</option> }
                  </select></label>
              }
              <label class="pw-fld"><span>Hostname</span>
                <input [(ngModel)]="hostname" placeholder="web042" /></label>
              <label class="pw-fld"><span>MAC <span class="pw-opt">(optional — blank = next machine that boots)</span></span>
                <input [(ngModel)]="mac" placeholder="52:54:00:…" /></label>
              <label class="pw-fld"><span>Network</span>
                <select [(ngModel)]="net.mode">
                  <option value="dhcp">DHCP</option>
                  <option value="static">static</option>
                </select></label>
              @if (net.mode === 'static') {
                <label class="pw-fld"><span>Address (CIDR)</span><input [(ngModel)]="net.address" placeholder="192.0.2.60/24" /></label>
                <label class="pw-fld"><span>Gateway</span><input [(ngModel)]="net.gateway" placeholder="192.0.2.1" /></label>
                <label class="pw-fld"><span>DNS (comma)</span><input [(ngModel)]="dnsRaw" placeholder="192.0.2.1, 1.1.1.1" /></label>
              }
            }

            @case (1) {
              <h2>Disk image</h2>
              <p class="pw-lead">Pick the golden template to restore, and size its growable volumes.</p>
              @if (readyImages().length === 0) { <p class="pw-dim">No ready templates. Capture or import one first.</p> }
              <div class="pw-imgs">
                @for (img of readyImages(); track img.id) {
                  <div class="pw-img" [class.sel]="imageId() === img.id" (click)="pickImage(img)">
                    <div class="pw-img-h"><b>{{ img.name }}</b>
                      @if (img.firmware !== 'unknown') {
                        <span class="pw-fw" [class.uefi]="img.firmware === 'uefi'">{{ img.firmware | uppercase }}</span>
                      }
                    </div>
                    <div class="pw-dim">{{ (img.disk_size / 1073741824) | number: '1.0-1' }} GiB · {{ img.volumes.length }} volumes</div>
                  </div>
                }
              </div>
              @if (chosenImage(); as img) {
                @if (growableRoles().length) {
                  <div class="pw-mode">
                    <button [class.on]="growMode() === 'percent'" (click)="growMode.set('percent')">Percent</button>
                    <button [class.on]="growMode() === 'absolute'" (click)="growMode.set('absolute')">GiB</button>
                  </div>
                  @for (v of img.volumes; track v.role + (v.lv || '')) {
                    @if (isGrowable(v)) {
                      <label class="pw-vol"><span>{{ v.mountpoint || v.role }} <span class="pw-dim">{{ v.fs_type }}</span></span>
                        @if (growMode() === 'percent') {
                          <span><input type="number" min="0" max="100" [(ngModel)]="pct[v.role]" /> %</span>
                        } @else {
                          <span><input type="number" min="0" [(ngModel)]="gib[v.role]" /> GiB</span>
                        }
                      </label>
                    }
                  }
                  @if (growMode() === 'percent') {
                    <div class="pw-sum" [class.bad]="sum() !== 100">Sum: {{ sum() }} %@if (sum() !== 100) { — must be 100 }</div>
                  } @else {
                    <p class="pw-dim">Sizes in GiB. Set one volume to <b>0</b> to fill the rest.</p>
                    @if (gibError()) { <div class="pw-sum bad">{{ gibError() }}</div> }
                  }
                } @else {
                  <p class="pw-dim">No growable volumes — the last volume fills the disk.</p>
                }
              }
            }

            @case (2) {
              <h2>Virtualization <span class="pw-dim">(optional)</span></h2>
              <p class="pw-lead">Create the target as a VM on vCenter or Proxmox, or leave off for bare metal
                (the MAC you typed). The environment is detected from the host + credentials.</p>
              <label class="pw-pick">
                <mat-checkbox [checked]="useVm()" (change)="useVm.set(!useVm())" /> Provision onto a VM host
              </label>

              @if (useVm()) {
                <label class="pw-fld"><span>VM host</span>
                  <select [ngModel]="vmHostId()" (ngModelChange)="pickVmHost($event)">
                    <option [ngValue]="null">— select or add below —</option>
                    @for (h of vmHosts(); track h.id) { <option [ngValue]="h.id">{{ h.name }} ({{ h.kind }})</option> }
                  </select>
                </label>

                @if (!vmHostId()) {
                  <div class="pw-addhost">
                    <b>Add a VM host</b>
                    <input [(ngModel)]="newHost.name" placeholder="name, e.g. lab-proxmox" />
                    <input [(ngModel)]="newHost.host" placeholder="host, e.g. pve.example or vc.example" />
                    <input [(ngModel)]="newHost.username" placeholder="user, e.g. root@pam" />
                    <input [(ngModel)]="newHost.password" type="password" placeholder="password" />
                    <button mat-stroked-button [disabled]="!canAddHost() || addingHost()" (click)="addVmHost()">
                      {{ addingHost() ? 'Detecting…' : 'Detect + save' }}
                    </button>
                    @if (hostErr()) { <span class="pw-err">{{ hostErr() }}</span> }
                  </div>
                }

                @if (placement(); as pl) {
                  <label class="pw-fld"><span>Node</span>
                    <select [ngModel]="node()" (ngModelChange)="node.set($event)">
                      @for (n of pl.nodes; track n.node) { <option [ngValue]="n.node">{{ n.node }}</option> }
                    </select>
                  </label>
                  @if (currentNode(); as n) {
                    <label class="pw-fld"><span>Storage</span>
                      <select [ngModel]="storage()" (ngModelChange)="storage.set($event)">
                        @for (s of n.storages; track s.name) { <option [ngValue]="s.name">{{ s.name }} ({{ s.type }})</option> }
                      </select>
                    </label>
                    <label class="pw-fld"><span>Network</span>
                      <select [ngModel]="bridge()" (ngModelChange)="bridge.set($event)">
                        @for (b of n.bridges; track b.name) { <option [ngValue]="b.name">{{ b.name }}{{ b.comment ? ' — ' + b.comment : '' }}</option> }
                      </select>
                    </label>
                  }
                  <div class="pw-vmrow">
                    <label class="pw-fld"><span>vCPU</span><input type="number" min="1" [(ngModel)]="cores" /></label>
                    <label class="pw-fld"><span>RAM (MB)</span><input type="number" min="512" step="512" [(ngModel)]="memoryMb" /></label>
                    <label class="pw-fld"><span>Disk (GiB)</span><input type="number" min="1" [(ngModel)]="diskGib" /></label>
                    <label class="pw-fld"><span>VLAN <span class="pw-opt">(optional)</span></span><input type="number" min="1" max="4094" [(ngModel)]="vlan" /></label>
                  </div>
                  <label class="pw-pick">
                    <mat-checkbox [checked]="uefi()" (change)="uefi.set(!uefi())" /> UEFI (OVMF) — adds an EFI disk + virtio-rng for PXE
                  </label>
                } @else if (vmHostId()) {
                  <p class="pw-dim">Loading placement… @if (placementErr()) { <span class="pw-err">{{ placementErr() }}</span> }</p>
                }
              }
            }

            @case (3) {
              <h2>Roles</h2>
              <p class="pw-lead">Roles to bind to the host. They are declared now and converge after first boot.</p>
              <input class="pw-search" placeholder="Filter roles…" [ngModel]="roleQuery()" (ngModelChange)="roleQuery.set($event)" />
              @if (roles().length === 0) { <p class="pw-dim">No roles defined. Create some under Roles.</p> }
              @for (r of filteredRoles(); track r.id) {
                <label class="pw-pick">
                  <mat-checkbox [checked]="pickedRoles().has(r.name)" (change)="toggleRole(r.name)" />
                  <span><b>{{ r.display_name || r.name }}</b> <span class="pw-dim">{{ r.description }}</span></span>
                </label>
              }
            }

            @case (4) {
              <h2>Review</h2>
              @if (!deploying() && !results().length) {
                <ul class="pw-review">
                  <li><b>Host</b>: {{ hostname || '—' }} <span class="pw-dim">{{ mac || '(wildcard MAC)' }} · {{ net.mode }}</span></li>
                  <li><b>Target</b>: {{ useVm() ? 'VM on ' + vmHostName() + ' — ' + node() + '/' + storage() + '/' + bridge() + (vlan ? ' VLAN ' + vlan : '') : 'bare metal' }}</li>
                  <li><b>Image</b>: {{ chosenImage()?.name || '—' }}
                    <span class="pw-dim">{{ chosenImage()?.firmware | uppercase }} · {{ growMode() }} sizing</span></li>
                  <li><b>Roles</b>: {{ pickedRoles().size ? asArray(pickedRoles()).join(', ') : 'none' }}</li>
                </ul>
                @if (reviewError()) { <p class="pw-err">{{ reviewError() }}</p> }
                <div class="pw-savetmpl">
                  <span>Save these choices (disk + sizing + roles) as a reusable template:</span>
                  <div class="pw-savetmpl-row">
                    <input [(ngModel)]="saveName" placeholder="template name, e.g. web-tier" />
                    <button mat-stroked-button [disabled]="!saveName.trim() || savingTmpl()" (click)="saveTemplate()">Save template</button>
                  </div>
                  @if (savedMsg()) { <span class="pw-ok">{{ savedMsg() }}</span> }
                </div>
              }
              @if (deploying() || results().length) {
                <ul class="pw-progress">
                  @for (r of results(); track r.label) {
                    <li><mat-icon [class.ok]="r.ok" [class.bad]="!r.ok">{{ r.ok ? 'check_circle' : 'error' }}</mat-icon>
                      {{ r.label }} @if (r.error) { <span class="pw-err">{{ r.error }}</span> }</li>
                  }
                  @if (deploying()) { <li><mat-spinner diameter="18" /> working…</li> }
                </ul>
                @if (!deploying() && allOk()) { <p class="pw-ok">Deployment armed. The host will restore on its next PXE boot.</p> }
              }
            }
          }
        </section>
      </div>

      <div class="pw-footer">
        <button mat-stroked-button (click)="close()">{{ done() ? 'Close' : 'Cancel' }}</button>
        <span class="pw-spacer"></span>
        @if (!done()) {
          <button mat-stroked-button [disabled]="step() === 0 || deploying()" (click)="prev()">Previous</button>
          @if (step() < STEP_LABELS.length - 1) {
            <button mat-flat-button color="primary" [disabled]="!canNext()" (click)="next()">Next</button>
          } @else {
            <button mat-flat-button color="primary" [disabled]="deploying() || !canDeploy()" (click)="deploy()">Deploy</button>
          }
        }
      </div>
    </div>
  `,
  styles: [`
    .pw { display: flex; flex-direction: column; width: 100%; height: 100%; }
    .pw-title { font-size: 1.1rem; font-weight: 600; padding: .8rem 1rem; border-bottom: 1px solid var(--mat-sys-outline-variant); }
    .pw-body { display: flex; flex: 1; min-height: 0; }
    .pw-steps { flex: 0 0 170px; border-right: 1px solid var(--mat-sys-outline-variant); padding: .5rem; overflow-y: auto; }
    .pw-step { display: flex; align-items: center; gap: .5rem; padding: .4rem .5rem; border-radius: 6px; cursor: pointer; font-size: .85rem; opacity: .7; }
    .pw-step.cur { opacity: 1; background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); }
    .pw-step.done { opacity: 1; }
    .pw-step-ic { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 50%; background: #8883; font-size: .75rem; }
    .pw-step-ic mat-icon { font-size: 15px; width: 15px; height: 15px; }
    .pw-main { flex: 1; min-width: 0; padding: 1rem; overflow-y: auto; }
    .pw-main h2 { font-size: 1rem; margin: 0 0 .3rem; }
    .pw-lead { color: var(--mat-sys-on-surface-variant, #888); font-size: .85rem; margin: 0 0 .8rem; }
    .pw-dim { color: var(--mat-sys-on-surface-variant, #888); font-size: .8rem; }
    .pw-opt { font-weight: 400; }
    .pw-fld { display: flex; flex-direction: column; gap: .2rem; margin-bottom: .6rem; font-size: .85rem; }
    .pw-fld input, .pw-fld select { padding: .35rem; }
    .pw-imgs { display: flex; flex-wrap: wrap; gap: .5rem; margin-bottom: .8rem; }
    .pw-img { border: 1px solid #3334; border-radius: 8px; padding: .5rem .7rem; cursor: pointer; min-width: 160px; }
    .pw-img.sel { border-color: #4a90d9; background: color-mix(in srgb, #4a90d9 10%, transparent); }
    .pw-img-h { display: flex; align-items: center; gap: .4rem; }
    .pw-fw { font-size: .6rem; font-weight: 600; padding: .05rem .3rem; border-radius: 4px; background: #8883; }
    .pw-fw.uefi { background: color-mix(in srgb, #4a90d9 28%, transparent); }
    .pw-mode { display: inline-flex; border: 1px solid #3335; border-radius: 6px; overflow: hidden; margin-bottom: .5rem; }
    .pw-mode button { border: 0; background: transparent; color: inherit; padding: .25rem .7rem; cursor: pointer; font-size: .8rem; }
    .pw-mode button.on { background: color-mix(in srgb, #4a90d9 28%, transparent); }
    .pw-vol { display: flex; justify-content: space-between; align-items: center; padding: .25rem 0; font-size: .85rem; }
    .pw-vol input { width: 4rem; padding: .2rem; }
    .pw-sum { margin: .4rem 0; font-size: .85rem; } .pw-sum.bad { color: #d9534f; }
    .pw-search { width: 100%; padding: .35rem; margin-bottom: .5rem; box-sizing: border-box; }
    .pw-pick { display: flex; align-items: center; gap: .5rem; padding: .2rem 0; font-size: .85rem; }
    .pw-review { list-style: none; padding: 0; } .pw-review li { padding: .3rem 0; border-bottom: 1px solid #3332; font-size: .9rem; }
    .pw-progress { list-style: none; padding: 0; } .pw-progress li { display: flex; align-items: center; gap: .5rem; padding: .25rem 0; font-size: .85rem; }
    .pw-progress mat-icon.ok { color: #2e7d32; } .pw-progress mat-icon.bad { color: #d9534f; }
    .pw-err { color: #d9534f; font-size: .8rem; } .pw-ok { color: #2e7d32; }
    .pw-footer { display: flex; align-items: center; gap: .5rem; padding: .7rem 1rem; border-top: 1px solid var(--mat-sys-outline-variant); }
    .pw-spacer { flex: 1; }
    .pw-savetmpl { margin-top: 1rem; padding-top: .8rem; border-top: 1px solid #3332; font-size: .85rem; display: flex; flex-direction: column; gap: .4rem; }
    .pw-savetmpl-row { display: flex; gap: .5rem; align-items: center; }
    .pw-savetmpl-row input { flex: 1; padding: .35rem; }
    .pw-addhost { display: flex; flex-direction: column; gap: .4rem; border: 1px solid #3334; border-radius: 8px; padding: .7rem; margin: .4rem 0; }
    .pw-addhost input { padding: .35rem; }
    .pw-vmrow { display: flex; gap: .6rem; flex-wrap: wrap; }
    .pw-vmrow .pw-fld { flex: 1; min-width: 6rem; }
  `],
})
export class ProvisionWizardComponent implements OnInit {
  readonly STEP_LABELS = ['Target', 'Disk image', 'Virtualization', 'Roles', 'Review'];

  private svc = inject(ImagesService);
  private orch = inject(OrchestrationService);
  private resources = inject(ResourceService);
  private ref = inject(MatDialogRef<ProvisionWizardComponent>);

  step = signal(0);

  // Target
  hostname = '';
  mac = '';
  net: ProvisionNetwork = { mode: 'dhcp' };
  dnsRaw = '';

  // Disk
  images = signal<DiskImage[]>([]);
  imageId = signal<string | null>(null);
  growMode = signal<'percent' | 'absolute'>('percent');
  pct: Record<string, number> = {};
  gib: Record<string, number> = {};

  // Virtualization (optional VM target)
  useVm = signal(false);
  vmHosts = signal<VmHost[]>([]);
  vmHostId = signal<string | null>(null);
  newHost = { name: '', host: '', username: '', password: '' };
  addingHost = signal(false);
  hostErr = signal('');
  placement = signal<VmPlacement | null>(null);
  placementErr = signal('');
  node = signal<string | null>(null);
  storage = signal<string | null>(null);
  bridge = signal<string | null>(null);
  cores = 2;
  memoryMb = 2048;
  diskGib = 32;
  vlan: number | null = null;
  uefi = signal(false);

  // Roles + config
  roles = signal<{ id: string; name: string; display_name: string; description: string }[]>([]);
  roleQuery = signal('');
  pickedRoles = signal<Set<string>>(new Set());

  // Deploy
  deploying = signal(false);
  results = signal<DeployStepResult[]>([]);
  reviewError = signal('');

  // Deployment templates (reuse)
  templates = signal<DeploymentTemplate[]>([]);
  fromTemplate = signal<string | null>(null);
  saveName = '';
  savingTmpl = signal(false);
  savedMsg = signal('');

  readyImages = computed(() => this.images().filter((i) => i.status === 'ready'));
  chosenImage = computed(() => this.images().find((i) => i.id === this.imageId()) ?? null);
  growableRoles = computed(() => (this.chosenImage()?.volumes ?? []).filter((v) => this.isGrowable(v)).map((v) => v.role));
  sum = computed(() => this.growableRoles().reduce((a, r) => a + (Number(this.pct[r]) || 0), 0));
  gibError = computed(() => {
    if (this.growMode() !== 'absolute') return '';
    const vals = this.growableRoles().map((r) => Number(this.gib[r]) || 0);
    if (vals.some((v) => v < 0)) return 'Sizes must be non-negative';
    if (vals.filter((v) => v === 0).length > 1) return 'Only one volume can be 0 (fills the rest)';
    return '';
  });
  filteredRoles = computed(() => {
    const q = this.roleQuery().trim().toLowerCase();
    return this.roles().filter((r) => !q || r.name.toLowerCase().includes(q) || (r.display_name || '').toLowerCase().includes(q));
  });
  done = computed(() => !this.deploying() && this.results().length > 0 && this.allOk());
  allOk = computed(() => this.results().length > 0 && this.results().every((r) => r.ok));
  currentNode = computed(() => this.placement()?.nodes.find((n) => n.node === this.node()) ?? null);
  vmHostName = computed(() => this.vmHosts().find((h) => h.id === this.vmHostId())?.name ?? '');

  ngOnInit(): void {
    this.svc.list().subscribe((imgs) => {
      this.images.set(imgs);
      const active = imgs.find((i) => i.is_active && i.status === 'ready') ?? imgs.find((i) => i.status === 'ready');
      if (active) this.pickImage(active);
    });
    this.orch.listPlans().subscribe({
      next: (plans) => this.roles.set(
        plans.filter((p) => p.plan_type === 'role')
          .map((p) => ({ id: p.id, name: p.name, display_name: p.display_name, description: p.description }))),
      error: () => this.roles.set([]),
    });
    this.svc.listTemplates().subscribe({ next: (t) => this.templates.set(t), error: () => this.templates.set([]) });
    this.svc.listVmHosts().subscribe({ next: (h) => this.vmHosts.set(h), error: () => this.vmHosts.set([]) });
  }

  isGrowable(v: ImageVolume): boolean { return GROWABLE.has(v.role); }
  asArray(s: Set<string>): string[] { return [...s]; }

  // ── Virtualization step ─────────────────────────────────────────────────
  canAddHost(): boolean {
    return !!(this.newHost.name.trim() && this.newHost.host.trim()
              && this.newHost.username.trim() && this.newHost.password);
  }

  addVmHost(): void {
    if (!this.canAddHost()) return;
    this.addingHost.set(true);
    this.hostErr.set('');
    this.svc.createVmHost({
      name: this.newHost.name.trim(), host: this.newHost.host.trim(),
      username: this.newHost.username.trim(), password: this.newHost.password,
    }).subscribe({
      next: (h) => {
        this.addingHost.set(false);
        this.vmHosts.set([...this.vmHosts().filter((x) => x.id !== h.id), h]);
        this.newHost = { name: '', host: '', username: '', password: '' };
        this.pickVmHost(h.id);   // auto-select the just-added host and load its placement
      },
      error: (e) => { this.addingHost.set(false); this.hostErr.set(e?.error?.detail ?? 'detection failed'); },
    });
  }

  /** Select a VM host and load its placement (nodes/storage/networks); default node/storage/bridge. */
  pickVmHost(id: string | null): void {
    this.vmHostId.set(id);
    this.placement.set(null);
    this.placementErr.set('');
    this.node.set(null); this.storage.set(null); this.bridge.set(null);
    if (!id) return;
    // UEFI defaults from the chosen image's firmware — a UEFI image needs a UEFI VM to boot.
    this.uefi.set(this.chosenImage()?.firmware === 'uefi');
    // Size the VM disk to at least the image's disk (GiB), so the restore fits.
    const bytes = this.chosenImage()?.disk_size ?? 0;
    if (bytes) this.diskGib = Math.max(this.diskGib, Math.ceil(bytes / 1073741824));
    this.svc.vmHostPlacement(id).subscribe({
      next: (pl) => {
        this.placement.set(pl);
        const n = pl.nodes[0];
        if (n) {
          this.node.set(n.node);
          this.storage.set(n.storages[0]?.name ?? null);
          this.bridge.set(n.bridges[0]?.name ?? null);
        }
      },
      error: (e) => this.placementErr.set(e?.error?.detail ?? 'could not load placement'),
    });
  }

  /** Prefill every step except the target from a saved template. The image must still exist; if it was
   *  deleted since the template was saved we keep the rest and leave the image unpicked (the Disk step then
   *  asks for one) rather than silently dropping the whole template. */
  applyTemplate(id: string | null): void {
    this.fromTemplate.set(id);
    if (!id) return;
    const t = this.templates().find((x) => x.id === id);
    if (!t) return;
    const img = t.image_id ? this.images().find((i) => i.id === t.image_id) : null;
    if (img) {
      this.pickImage(img);
      this.growMode.set(t.grow_mode);
      for (const [role, v] of Object.entries(t.grow_policy || {})) {
        if (t.grow_mode === 'absolute') this.gib[role] = v; else this.pct[role] = v;
      }
    }
    if (t.network?.mode) {
      this.net = { mode: t.network.mode };
      if (t.network.mode === 'static') {
        this.net.address = t.network.address;
        this.net.gateway = t.network.gateway;
        this.dnsRaw = (t.network.dns || []).join(', ');
      }
    }
    this.pickedRoles.set(new Set(t.roles || []));
  }

  saveTemplate(): void {
    const name = this.saveName.trim();
    if (!name) return;
    this.savingTmpl.set(true);
    this.savedMsg.set('');
    const network: ProvisionNetwork = { mode: this.net.mode };
    if (this.net.mode === 'static') {
      network.address = this.net.address;
      network.gateway = this.net.gateway;
      network.dns = this.dnsRaw.split(',').map((s) => s.trim()).filter(Boolean);
    }
    const { grow_mode, grow_policy } = this.growPolicy();
    this.svc.saveTemplate({
      name, image_id: this.imageId(), grow_mode, grow_policy, network, roles: [...this.pickedRoles()],
    }).subscribe({
      next: (t) => {
        this.savingTmpl.set(false);
        this.savedMsg.set(`Saved as “${t.name}”.`);
        this.svc.listTemplates().subscribe((all) => this.templates.set(all));
      },
      error: (e) => { this.savingTmpl.set(false); this.savedMsg.set((e as { error?: { detail?: string } })?.error?.detail ?? 'Save failed'); },
    });
  }

  pickImage(img: DiskImage): void {
    this.imageId.set(img.id);
    this.growMode.set(img.grow_mode === 'absolute' ? 'absolute' : 'percent');
    const roles = img.volumes.filter((v) => this.isGrowable(v)).map((v) => v.role);
    const stored = img.grow_policy || {};
    const even = roles.length ? Math.floor(100 / roles.length) : 0;
    this.pct = {}; this.gib = {};
    roles.forEach((r, i) => {
      this.pct[r] = (img.grow_mode !== 'absolute' && stored[r] != null) ? stored[r]
        : (i === roles.length - 1 ? 100 - even * (roles.length - 1) : even);
      this.gib[r] = (img.grow_mode === 'absolute' && stored[r] != null) ? stored[r] : 0;
    });
  }

  toggleRole(name: string): void {
    const s = new Set(this.pickedRoles());
    s.has(name) ? s.delete(name) : s.add(name);
    this.pickedRoles.set(s);
  }

  goto(i: number): void { if (i <= this.step() && !this.deploying() && !this.done()) this.step.set(i); }
  prev(): void { if (this.step() > 0) this.step.set(this.step() - 1); }
  next(): void { if (this.canNext()) this.step.set(this.step() + 1); }

  canNext(): boolean {
    switch (this.step()) {
      case 0: return !!this.hostname.trim();
      case 1: return !!this.imageId() && (this.growableRoles().length === 0
        || (this.growMode() === 'percent' ? this.sum() === 100 : !this.gibError()));
      case 2: return this.vmReady();   // Virtualization: off is fine; on needs node+storage+bridge
      default: return true;
    }
  }
  /** A VM target is either not used, or fully specified (host + node + storage + bridge chosen). */
  vmReady(): boolean {
    return !this.useVm() || !!(this.vmHostId() && this.node() && this.storage() && this.bridge());
  }
  canDeploy(): boolean { return !!this.hostname.trim() && !!this.imageId() && this.vmReady(); }

  private growPolicy(): { grow_mode: 'percent' | 'absolute'; grow_policy: Record<string, number> } {
    const mode = this.growMode();
    const src = mode === 'percent' ? this.pct : this.gib;
    const policy: Record<string, number> = {};
    for (const r of this.growableRoles()) policy[r] = Number(src[r]) || 0;
    return { grow_mode: mode, grow_policy: policy };
  }

  deploy(): void {
    if (!this.canDeploy()) return;
    this.deploying.set(true);
    this.reviewError.set('');
    this.results.set([]);
    const push = (r: DeployStepResult) => this.results.set([...this.results(), r]);

    const network: ProvisionNetwork = { mode: this.net.mode };
    if (this.net.mode === 'static') {
      network.address = this.net.address;
      network.gateway = this.net.gateway;
      network.dns = this.dnsRaw.split(',').map((s) => s.trim()).filter(Boolean);
    }
    const hostname = this.hostname.trim();
    const imageId = this.imageId()!;
    const { grow_mode, grow_policy } = this.growPolicy();

    // The rest of the flow runs against a MAC. Bare metal uses the typed one (may be blank = wildcard); a VM
    // target has none yet, so we create the VM first and use the MAC the hypervisor assigned it — that MAC
    // is what the PXE check-in identifies the machine by, so it MUST be the one armed on the restore job.
    const proceed = (mac: string) => {
      this.svc.patch(imageId, { grow_mode, grow_policy }).subscribe({
        next: () => this.svc.createPlannedHost({ hostname, mac, network }).subscribe({
          next: (host) => {
            push({ label: `Host ${hostname} created`, ok: true });
            this.svc.arm({ image_id: imageId, target_mac: mac, target_hostname: hostname }).subscribe({
              next: () => { push({ label: 'Restore job armed', ok: true }); this.bindAll(host.id, push); },
              error: (e) => this.fail(push, 'Arming failed', e),
            });
          },
          error: (e) => this.fail(push, 'Creating host failed', e),
        }),
        error: (e) => this.fail(push, 'Saving grow policy failed', e),
      });
    };

    if (this.useVm()) {
      this.svc.createVm(this.vmHostId()!, {
        node: this.node()!, name: hostname, storage: this.storage()!, bridge: this.bridge()!,
        cores: this.cores, memory_mb: this.memoryMb, disk_gib: this.diskGib,
        uefi: this.uefi(), vlan: this.vlan || null,
      }).subscribe({
        next: (vm) => { push({ label: `VM created (vmid ${vm.vmid}, ${vm.mac})`, ok: true }); proceed(vm.mac); },
        error: (e) => this.fail(push, 'VM creation failed', e),
      });
    } else {
      proceed(this.mac.trim());
    }
  }

  /** Declare every selected role on the new host. Independent applies, so one failure is reported without
   *  aborting the others — the host is already created and armed by this point. RoleResource.apply only
   *  writes the binding + desired state; it converges when the host first checks in. */
  private bindAll(hostId: string, push: (r: DeployStepResult) => void): void {
    const roleNames = [...this.pickedRoles()];
    if (!roleNames.length) { this.deploying.set(false); return; }
    const calls = roleNames.map((name) => this.resources.apply({ agentId: hostId, kind: 'role', name }, {}, false));
    forkJoin(calls).subscribe({
      next: (res) => {
        (res as { ok?: boolean; error?: string }[]).forEach((r, i) =>
          push({ label: `Role ${roleNames[i]}`, ok: r?.ok !== false, error: r?.error }));
        this.deploying.set(false);
      },
      error: (e) => this.fail(push, 'Binding roles failed', e),
    });
  }

  private fail(push: (r: DeployStepResult) => void, label: string, e: unknown): void {
    const msg = (e as { error?: { detail?: string } })?.error?.detail ?? 'failed';
    push({ label, ok: false, error: msg });
    this.deploying.set(false);
  }

  close(): void { this.ref.close(this.done()); }
}
