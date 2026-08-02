import { Component, OnInit, OnDestroy, computed, inject, signal } from '@angular/core';
import { DecimalPipe } from '@angular/common';
import { FormsModule } from '@angular/forms';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { RouterLink } from '@angular/router';
import { DiskImage, ImageVolume, ImagesService, ProvisionNetwork, RestoreJob, Vm } from '../../core/services/images.service';

/** Roles whose size a grow policy can adjust; the rest (esp/boot/swap/bios_boot) stay fixed. */
const GROWABLE = new Set(['root', 'var', 'home', 'data']);

/**
 * Disk-Templates / bare-metal provisioning. Left: captured templates (mark one active). Middle: the
 * active template's disk — fixed volumes locked, growable ones (root/var/home, LVM-aware) as percentage
 * inputs that must sum to 100. Right: plan a target host (hostname/MAC/network) + arm the install, and
 * the live restore-jobs list. Roles are assigned through the host's Management tab (link per job).
 * See docs/pxe-baremetal-imaging.md.
 */
@Component({
  selector: 'app-disk-templates',
  standalone: true,
  imports: [FormsModule, MatIconModule, MatButtonModule, RouterLink, DecimalPipe],
  template: `
    <div class="dt-wrap">
      <!-- ── Templates ────────────────────────────────────────────── -->
      <section class="dt-col">
        <h2>Disk-Templates</h2>

        <!-- Import an existing disk image (vmdk/qcow2/raw) staged in the lab as a golden template. -->
        <div class="dt-import">
          @if (!importOpen()) {
            <button mat-button (click)="openImport()"><mat-icon>upload_file</mat-icon> Bestehendes Image importieren</button>
          } @else {
            <div class="dt-import-form">
              <b>Image importieren</b>
              <label class="dt-fld"><span>Quelldatei (in /srv/templates)</span>
                <select [(ngModel)]="imp.source_file">
                  <option value="" disabled>— wählen —</option>
                  @for (s of sources(); track s) { <option [value]="s">{{ s }}</option> }
                </select>
              </label>
              <label class="dt-fld"><span>Template-Name</span><input [(ngModel)]="imp.name" placeholder="z. B. debian13-base" /></label>
              <div class="dt-row">
                <button mat-flat-button color="primary" [disabled]="!imp.source_file || !imp.name.trim() || importing()" (click)="doImport()">Importieren</button>
                <button mat-button (click)="importOpen.set(false)">Abbrechen</button>
              </div>
              @if (sources().length === 0) { <p class="dt-muted">Keine Images in /srv/templates gefunden (.vmdk/.qcow2/.raw/.img).</p> }
              @if (importErr()) { <p class="dt-err">{{ importErr() }}</p> }
            </div>
          }
        </div>

        @if (images().length === 0) { <p class="dt-muted">Noch keine aufgenommenen Templates.</p> }
        @for (img of images(); track img.id) {
          <div class="dt-card" [class.dt-sel]="selected()?.id === img.id" (click)="select(img)">
            <div class="dt-row">
              <mat-icon>{{ img.is_active ? 'star' : 'save' }}</mat-icon>
              <b>{{ img.name }}</b>
              <span class="dt-badge" [class.ready]="img.status === 'ready'">{{ img.status }}</span>
            </div>
            <div class="dt-sub">{{ (img.disk_size / 1073741824) | number: '1.0-1' }} GiB · {{ img.volumes.length }} Volumes</div>
            @if (img.status === 'capturing') {
              <div class="dt-prog">
                <div class="dt-prog-bar"><span [style.width.%]="progressPct(img)"></span></div>
                <div class="dt-sub">{{ img.progress || 'Import läuft…' }}</div>
              </div>
            }
            @if (img.status === 'failed' && img.error) { <div class="dt-err">{{ img.error }}</div> }
            <button mat-button [disabled]="img.status !== 'ready'" (click)="toggleActive(img, $event)">
              {{ img.is_active ? 'Aktiv' : 'Als aktiv markieren' }}
            </button>
          </div>
        }
      </section>

      <!-- ── Disk / grow policy of the selected template ──────────── -->
      <section class="dt-col">
        <h2>Disk-Geometrie</h2>
        @if (!selected()) { <p class="dt-muted">Ein Template wählen.</p> }
        @if (selected(); as img) {
          <p class="dt-muted">Struktur kommt aus dem Image (partclone). Nur die Größen der wachsenden Volumes sind einstellbar.</p>
          @for (v of img.volumes; track v.role + (v.lv || '')) {
            <div class="dt-vol">
              <span class="dt-vol-name">
                <mat-icon>{{ v.vg ? 'view_stream' : 'storage' }}</mat-icon>
                {{ v.mountpoint || v.role }}
                @if (v.vg) { <span class="dt-lvm">LVM {{ v.vg }}/{{ v.lv }}</span> }
                <span class="dt-fs">{{ v.fs_type }}</span>
              </span>
              @if (isGrowable(v)) {
                <span class="dt-pct">
                  <input type="number" min="0" max="100" [(ngModel)]="pct[v.role]" (ngModelChange)="onPct()" /> %
                </span>
              } @else {
                <span class="dt-fixed">fix · {{ (v.size_bytes / 1073741824) | number: '1.0-1' }} GiB</span>
              }
            </div>
          }
          @if (growableRoles().length) {
            <div class="dt-sum" [class.bad]="sum() !== 100">Summe: {{ sum() }} % @if (sum() !== 100) { — muss 100 sein }</div>
            <button mat-button [disabled]="sum() !== 100" (click)="saveGrow()">Grow-Policy speichern</button>
          } @else {
            <p class="dt-muted">Keine wachsenden Volumes (root/var/home) — das letzte Volume füllt die Platte.</p>
          }
        }
      </section>

      <!-- ── Provision a target + jobs ────────────────────────────── -->
      <section class="dt-col">
        <h2>Bereitstellen</h2>
        <label class="dt-fld"><span>Hostname</span><input [(ngModel)]="host.hostname" placeholder="web042" /></label>
        <label class="dt-fld"><span>MAC</span><input [(ngModel)]="host.mac" placeholder="AA:BB:CC:DD:EE:FF" /></label>
        <label class="dt-fld"><span>Netzwerk</span>
          <select [(ngModel)]="net.mode">
            <option value="dhcp">DHCP</option>
            <option value="static">statisch</option>
          </select>
        </label>
        @if (net.mode === 'static') {
          <label class="dt-fld"><span>Adresse (CIDR)</span><input [(ngModel)]="net.address" placeholder="192.0.2.60/24" /></label>
          <label class="dt-fld"><span>Gateway</span><input [(ngModel)]="net.gateway" placeholder="192.0.2.1" /></label>
          <label class="dt-fld"><span>DNS (Komma)</span><input [(ngModel)]="dnsRaw" placeholder="192.0.2.1, 1.1.1.1" /></label>
        }
        <button mat-flat-button color="primary" [disabled]="!canProvision()" (click)="provision()">
          Host anlegen + für Installation armen
        </button>
        @if (err()) { <p class="dt-err">{{ err() }}</p> }
        <p class="dt-muted">Rollen weist du danach im <b>Management</b>-Tab des Hosts zu (konvergieren nach dem ersten Boot).</p>

        <h3>Restore-Jobs</h3>
        @for (j of jobs(); track j.id) {
          <div class="dt-job">
            <span class="dt-badge" [class.ready]="j.status === 'done'" [class.bad]="j.status === 'failed'">{{ j.status }}</span>
            <b>{{ j.target_hostname }}</b> <span class="dt-muted">{{ j.target_mac }}</span> · Schritt {{ j.step_index }}
            @if (j.agent_id) { <a mat-button [routerLink]="['/hosts', j.agent_id]">Management</a> }
          </div>
        }
      </section>
    </div>

    <!-- ── Nested-virt lab (QEMU im pxe-Container) ──────────────────────── -->
    <section class="dt-lab">
      <h2>Labor (nested-virt)</h2>
      <p class="dt-muted">Template von einer ISO bauen oder das aktive Template über ein plattenloses PXE-Ziel end-to-end testen — QEMU läuft im pxe-Container, Konsole per noVNC.</p>
      <div class="dt-lab-actions">
        <div class="dt-lab-form">
          <b>Template von ISO installieren</b>
          <input [(ngModel)]="inst.name" placeholder="VM-Name (z. B. tmpl-deb12)" />
          <input [(ngModel)]="inst.iso" placeholder="ISO-Datei (im ISO-Verzeichnis)" />
          <input [(ngModel)]="inst.disk" placeholder="Disk-Datei (z. B. tmpl-deb12.raw)" />
          <button mat-flat-button color="primary" [disabled]="!inst.name || !inst.iso || !inst.disk" (click)="startInstall()">Installieren + Konsole</button>
        </div>
        <div class="dt-lab-form">
          <b>PXE-Test des aktiven Templates</b>
          <p class="dt-muted">Erzeugt eine plattenlose VM auf dem ens19-Segment, die das aktive Template per PXE restauriert.</p>
          <button mat-flat-button [disabled]="!activeImage()" (click)="startPxeTest()">PXE-Test starten</button>
        </div>
      </div>
      @if (labErr()) { <p class="dt-err">{{ labErr() }}</p> }
      <h3>Laufende VMs</h3>
      @if (vms().length === 0) { <p class="dt-muted">Keine laufenden Lab-VMs.</p> }
      @for (v of vms(); track v.name) {
        <div class="dt-job">
          <span class="dt-badge ready">{{ v.kind }}</span>
          <b>{{ v.name }}</b> <span class="dt-muted">Display :{{ v.display }} · {{ v.disk }}</span>
          <button mat-button (click)="openConsole(v.name)">Konsole</button>
          <button mat-button (click)="stopVm(v.name)">Stop</button>
        </div>
      }
    </section>
  `,
  styles: [`
    .dt-wrap { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1rem; padding: 1rem; }
    .dt-lab { padding: 0 1rem 1.5rem; } .dt-lab h2 { font-size: 1rem; margin: .5rem 0; }
    .dt-lab-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin: .5rem 0; }
    .dt-lab-form { display: flex; flex-direction: column; gap: .35rem; border: 1px solid #3334; border-radius: 8px; padding: .7rem; }
    .dt-lab-form input { padding: .3rem; }
    .dt-import { margin-bottom: .6rem; }
    .dt-import-form { display: flex; flex-direction: column; gap: .35rem; border: 1px solid #4a90d9; border-radius: 8px; padding: .7rem; }
    .dt-import-form select, .dt-import-form input { padding: .3rem; }
    .dt-prog { margin: .3rem 0; }
    .dt-prog-bar { height: 6px; background: #8883; border-radius: 3px; overflow: hidden; }
    .dt-prog-bar span { display: block; height: 100%; background: #4a90d9; transition: width .4s ease; }
    .dt-col h2 { font-size: 1rem; margin: 0 0 .5rem; }
    .dt-muted { color: var(--mat-sys-on-surface-variant, #888); font-size: .85rem; }
    .dt-card { border: 1px solid #3334; border-radius: 8px; padding: .6rem; margin-bottom: .5rem; cursor: pointer; }
    .dt-sel { border-color: #4a90d9; }
    .dt-row { display: flex; align-items: center; gap: .4rem; }
    .dt-sub { font-size: .8rem; color: #888; margin: .2rem 0; }
    .dt-badge { font-size: .7rem; padding: .1rem .4rem; border-radius: 4px; background: #8883; }
    .dt-badge.ready { background: #2e7d3244; } .dt-badge.bad { background: #c6282844; }
    .dt-vol { display: flex; justify-content: space-between; align-items: center; padding: .3rem 0; border-bottom: 1px solid #3332; }
    .dt-vol-name { display: flex; align-items: center; gap: .35rem; }
    .dt-lvm { font-size: .7rem; color: #4a90d9; } .dt-fs { font-size: .7rem; color: #888; }
    .dt-pct input { width: 3.5rem; } .dt-fixed { font-size: .8rem; color: #888; }
    .dt-sum { margin: .5rem 0; } .dt-sum.bad { color: #d9534f; }
    .dt-fld { display: flex; flex-direction: column; margin-bottom: .4rem; font-size: .85rem; }
    .dt-fld input, .dt-fld select { padding: .3rem; }
    .dt-err { color: #d9534f; } .dt-job { padding: .3rem 0; border-bottom: 1px solid #3332; font-size: .85rem; }
    code { font-family: ui-monospace, monospace; }
  `],
})
export class DiskTemplatesComponent implements OnInit, OnDestroy {
  private svc = inject(ImagesService);

  images = signal<DiskImage[]>([]);
  jobs = signal<RestoreJob[]>([]);
  vms = signal<Vm[]>([]);
  selected = signal<DiskImage | null>(null);
  err = signal('');
  labErr = signal('');
  pct: Record<string, number> = {};

  inst = { name: '', iso: '', disk: '' };
  activeImage = computed(() => this.images().find((i) => i.is_active) ?? null);

  // Import an existing disk image staged in the lab.
  importOpen = signal(false);
  sources = signal<string[]>([]);
  imp = { name: '', source_file: '' };
  importing = signal(false);
  importErr = signal('');

  host = { hostname: '', mac: '' };
  net: ProvisionNetwork = { mode: 'dhcp' };
  dnsRaw = '';

  private timer?: ReturnType<typeof setInterval>;

  growableRoles = computed(() =>
    (this.selected()?.volumes ?? []).filter((v) => this.isGrowable(v)).map((v) => v.role));
  sum = computed(() => this.growableRoles().reduce((a, r) => a + (Number(this.pct[r]) || 0), 0));

  ngOnInit(): void {
    this.reload();
    this.pollVms();
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
      error: (e) => this.importErr.set(e?.error?.detail || 'Quellen konnten nicht geladen werden'),
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
      error: (e) => { this.importing.set(false); this.importErr.set(e?.error?.detail || 'Import fehlgeschlagen'); },
    });
  }
  ngOnDestroy(): void { if (this.timer) clearInterval(this.timer); }

  private pollVms(): void {
    // The lab is optional: a 503 (BOSSMAN_PXE_CONTAINER unset) just means no VMs to show.
    this.svc.listVms().subscribe({ next: (v) => this.vms.set(v), error: () => this.vms.set([]) });
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
      error: (e) => this.labErr.set(e?.error?.detail || 'Installation fehlgeschlagen'),
    });
  }

  startPxeTest(): void {
    this.labErr.set('');
    const name = `pxe-test-${this.slug()}`;
    this.svc.pxeTest({ name, mac: this.randMac(), disk: `${name}.raw` }).subscribe({
      next: () => { this.pollVms(); this.openConsole(name); },
      error: (e) => this.labErr.set(e?.error?.detail || 'PXE-Test fehlgeschlagen'),
    });
  }

  stopVm(name: string): void {
    this.svc.stopVm(name).subscribe({ next: () => this.pollVms(), error: (e) => this.labErr.set(e?.error?.detail || 'Stop fehlgeschlagen') });
  }

  private reload(): void {
    this.svc.list().subscribe((imgs) => {
      this.images.set(imgs);
      const active = imgs.find((i) => i.is_active) ?? imgs[0];
      if (active && !this.selected()) this.select(active);
    });
    this.svc.jobs().subscribe((j) => this.jobs.set(j));
  }

  isGrowable(v: ImageVolume): boolean { return GROWABLE.has(v.role); }

  /** Percent parsed from the trailing "· NN%" of the progress string (0 if none), for the bar width. */
  progressPct(img: DiskImage): number {
    const m = (img.progress || '').match(/(\d+)\s*%\s*$/);
    return m ? Math.max(0, Math.min(100, +m[1])) : 0;
  }

  select(img: DiskImage): void {
    this.selected.set(img);
    // seed the percentage inputs from the stored policy, else spread evenly.
    const roles = img.volumes.filter((v) => this.isGrowable(v)).map((v) => v.role);
    const stored = img.grow_policy || {};
    const even = roles.length ? Math.floor(100 / roles.length) : 0;
    this.pct = {};
    roles.forEach((r, i) => (this.pct[r] = stored[r] ?? (i === roles.length - 1 ? 100 - even * (roles.length - 1) : even)));
  }

  onPct(): void { /* sum() recomputes from pct via the template bindings */ }

  toggleActive(img: DiskImage, ev: Event): void {
    ev.stopPropagation();
    this.svc.patch(img.id, { is_active: !img.is_active }).subscribe({
      next: () => this.reload(),
      error: (e) => this.err.set(e?.error?.detail || 'Aktivieren fehlgeschlagen'),
    });
  }

  saveGrow(): void {
    const img = this.selected();
    if (!img || this.sum() !== 100) return;
    const policy: Record<string, number> = {};
    for (const r of this.growableRoles()) policy[r] = Number(this.pct[r]) || 0;
    this.svc.patch(img.id, { grow_policy: policy }).subscribe({
      next: (updated) => { this.selected.set(updated); this.reload(); },
      error: (e) => this.err.set(e?.error?.detail || 'Speichern fehlgeschlagen'),
    });
  }

  canProvision(): boolean {
    return !!this.host.hostname.trim() && !!this.host.mac.trim() && !!this.images().find((i) => i.is_active);
  }

  provision(): void {
    this.err.set('');
    const active = this.images().find((i) => i.is_active);
    if (!active) { this.err.set('Kein aktives Template'); return; }
    const network: ProvisionNetwork = { mode: this.net.mode };
    if (this.net.mode === 'static') {
      network.address = this.net.address;
      network.gateway = this.net.gateway;
      network.dns = this.dnsRaw.split(',').map((s) => s.trim()).filter(Boolean);
    }
    this.svc.createPlannedHost({ hostname: this.host.hostname.trim(), mac: this.host.mac.trim(), network }).subscribe({
      next: () => this.svc.arm({ image_id: active.id, target_mac: this.host.mac.trim(), target_hostname: this.host.hostname.trim() })
        .subscribe({
          next: () => { this.host = { hostname: '', mac: '' }; this.net = { mode: 'dhcp' }; this.dnsRaw = ''; this.reload(); },
          error: (e) => this.err.set(e?.error?.detail || 'Armen fehlgeschlagen'),
        }),
      error: (e) => this.err.set(e?.error?.detail || 'Host anlegen fehlgeschlagen'),
    });
  }
}
