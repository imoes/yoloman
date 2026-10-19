import { Component, ElementRef, OnDestroy, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { MatDialogModule, MatDialogRef } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MAT_DIALOG_DATA } from '@angular/material/dialog';
import { DeployCatalog, DeployRequest, DeployResult, DeploymentStatus, IpVerdict, PlacementNode, ResolvedInstall,
  VmDeployService } from '../../core/services/vm-deploy.service';
import { DeploymentTemplate, ImagesService } from '../../core/services/images.service';
import { BlockedReasonDirective } from '../../shared/blocked-reason/blocked-reason.directive';
import { GrowSizing, GrowSizingComponent } from '../../shared/grow-sizing/grow-sizing.component';

/** What the opener may preselect: Disk images → "New deployment" opens this wizard on its image. */
export interface DeployWizardData { image?: string; }

/** Install a host — the ONE deployment wizard (it replaced Disk images' provisioning wizard), the face of the MCP
 *  tool deploy_vm: same backend code (services/vm_provision.deploy), same checks.
 *  Target (VM on a hypervisor, or bare metal by MAC; optionally from a saved template) → Operating system
 *  (network install, or a golden image with THIS deployment's volume sizing) → Machine → Network (with the
 *  bootstrap→production VLAN handoff) → Roles & playbook → Review (dry run; save as template) → Progress.
 *  "Next" names what blocks it and stays focusable; "Deploy" unlocks only when every pre-flight check passed. */
@Component({
  selector: 'app-deploy-vm-wizard',
  standalone: true,
  imports: [FormsModule, MatDialogModule, MatButtonModule, MatIconModule, MatProgressSpinnerModule, BlockedReasonDirective,
    GrowSizingComponent],
  template: `
    <div class="bm-wz">
      <div class="bm-wz-title">Install a host
        @if (cat()) { <span class="bm-wz-host">{{ cat()!.vm_hosts.length }} hypervisor(s)</span> }
      </div>
      <div class="bm-wz-body">
        <nav class="bm-wz-steps" aria-label="Steps">
          @for (s of steps; track $index) {
            <button type="button" class="bm-wz-step" [class.bm-wz-step--cur]="step() === $index" [class.bm-wz-step--done]="step() > $index"
                    [disabled]="$index > maxReachable() || deployed()" (click)="goto($index)">
              <span class="bm-wz-step-ic">@if (step() > $index) { <mat-icon>check</mat-icon> } @else { {{ $index + 1 }} }</span>
              {{ s }}
            </button>
          }
        </nav>

        <section class="bm-wz-main">
          @if (loadError()) { <div class="bm-wz-warn bm-wz-warn--block" role="alert">{{ loadError() }}</div> }
          @if (!cat() && !loadError()) { <div class="bm-wz-center"><mat-spinner diameter="28"></mat-spinner> Loading hypervisors…</div> }
          @if (cat()) {
          @switch (step()) {
            @case (0) {
              <h2>Target</h2>
              <div class="bm-dv-choice" role="radiogroup" aria-label="Kind of machine">
                <label><input type="radio" name="target" value="vm" [ngModel]="target()" (ngModelChange)="target.set($event)" data-field="target" /> Virtual machine</label>
                <label><input type="radio" name="target" value="bare_metal" [ngModel]="target()" (ngModelChange)="target.set($event)" /> Bare metal</label>
              </div>
              @if (templates().length) {
                <label class="bm-dv-wide">Start from a saved template <span class="bm-wz-dim">(fills image, sizing, network and roles)</span>
                  <select [ngModel]="templateId()" (ngModelChange)="applyTemplate($event)" name="template">
                    <option value="">— none —</option>
                    @for (t of templates(); track t.id) { <option [value]="t.id">{{ t.name }}</option> }
                  </select></label>
              }
              @if (target() === 'bare_metal') {
                <p class="bm-wz-lead">An existing machine, identified by the MAC of the NIC it PXE-boots from. A network install
                  needs it (its boot entry is per MAC); a golden image may leave it empty — then the next machine that PXE-boots
                  claims the job, and DHCP answers everyone for a short window.</p>
                <label class="bm-dv-wide">MAC address <input [ngModel]="mac()" (ngModelChange)="mac.set($event.trim())" name="mac" placeholder="aa:bb:cc:dd:ee:ff" /></label>
              } @else {
              <p class="bm-wz-lead">Where the VM is created. The VLAN tags its network card; the PXE DHCP of that segment
                will answer only this VM's MAC.</p>
              <div class="bm-dv-grid">
                <label>Hypervisor
                  <select [ngModel]="vmHost()" (ngModelChange)="vmHost.set($event); node.set(''); storage.set(''); bridge.set('')" name="vmhost">
                    <option value="" disabled>Choose…</option>
                    @for (h of cat()!.vm_hosts; track h.name) { <option [value]="h.name">{{ h.name }} ({{ h.kind }}, {{ h.host }})</option> }
                  </select></label>
                @if (hostError()) { <div class="bm-wz-warn bm-wz-warn--block">{{ hostError() }}</div> }
                <label>Node
                  <select [ngModel]="node()" (ngModelChange)="node.set($event); storage.set(''); bridge.set('')" name="node" [disabled]="!nodes().length">
                    <option value="" disabled>Choose…</option>
                    @for (n of nodes(); track n.node) { <option [value]="n.node">{{ n.node }} — {{ n.status }}</option> }
                  </select></label>
                <label>Storage
                  <select [ngModel]="storage()" (ngModelChange)="storage.set($event)" name="storage" [disabled]="!curNode()">
                    <option value="" disabled>Choose…</option>
                    @for (s of curNode()?.storages ?? []; track s.name) {
                      <option [value]="s.name">{{ s.name }}@if (s.avail_bytes) { — {{ gib(s.avail_bytes) }} GiB free }</option> }
                  </select></label>
                <label>Bridge
                  <select [ngModel]="bridge()" (ngModelChange)="bridge.set($event)" name="bridge" [disabled]="!curNode()">
                    <option value="" disabled>Choose…</option>
                    @for (b of curNode()?.bridges ?? []; track b.name) { <option [value]="b.name">{{ b.name }}@if (b.comment) { — {{ b.comment }} }</option> }
                  </select></label>
                <label>VLAN tag <span class="bm-wz-dim">(optional)</span>
                  <input type="number" min="1" max="4094" [ngModel]="vlan()" (ngModelChange)="vlan.set($event)" name="vlan" placeholder="e.g. 1028" /></label>
              </div>
              }
            }
            @case (1) {
              <h2>Operating system</h2>
              <p class="bm-wz-lead">A network install uses the distribution's own installer with its newest stable or LTS
                release. A golden image restores a captured disk (Debian family).</p>
              <div class="bm-dv-choice" role="radiogroup">
                <label><input type="radio" name="mode" value="install" [ngModel]="mode()" (ngModelChange)="mode.set($event)" /> Network install</label>
                <label><input type="radio" name="mode" value="image" [ngModel]="mode()" (ngModelChange)="mode.set($event)" [disabled]="!readyImages().length" />
                  Golden image @if (!readyImages().length) { <span class="bm-wz-dim">— none ready</span> }</label>
              </div>
              @if (mode() === 'install') {
                <div class="bm-dv-cards">
                  @for (i of cat()!.installs; track i.install) {
                    <button type="button" class="bm-dv-card" data-field="install" [class.bm-dv-card--sel]="install() === i.install" (click)="pickInstall(i.install)">
                      <span class="bm-dv-card-t">{{ i.title }}</span>
                      <span class="bm-wz-dim">{{ i.family === 'redhat' ? 'RPM' : 'DEB' }} · min. {{ i.min_memory_mb / 1024 }} GB RAM</span>
                    </button>
                  }
                </div>
                @if (resolving()) { <div class="bm-wz-center"><mat-spinner diameter="20"></mat-spinner> Asking the mirror for the newest release…</div> }
                @if (resolveError()) { <div class="bm-wz-warn bm-wz-warn--block">{{ resolveError() }}</div> }
                @if (resolved(); as r) {
                  <div class="bm-wz-prefill"><mat-icon>verified</mat-icon> {{ r.label }} — installer found on the mirror</div>
                  <label class="bm-dv-wide">Packages <span class="bm-wz-dim">(space-separated; checked against the repositories in the review)</span>
                    <input [ngModel]="packages()" (ngModelChange)="packages.set($event)" name="packages" /></label>
                  @if (r.missing_packages.length) {
                    <div class="bm-wz-warn">Not in the repositories: {{ r.missing_packages.join(', ') }}</div> }
                }
              } @else {
                <label>Image
                  <select [ngModel]="image()" (ngModelChange)="image.set($event); sizing.set(null)" name="image">
                    <option value="" disabled>Choose…</option>
                    @for (i of readyImages(); track i.name) { <option [value]="i.name">{{ i.name }}</option> }
                  </select></label>
                @if (imageRow(); as img) {
                  <h3 class="bm-dv-h3">Volume sizing <span class="bm-wz-dim">(this deployment only; the image's default stays)</span></h3>
                  <bm-grow-sizing [volumes]="img.volumes" [policy]="templateGrow()?.policy ?? img.grow_policy"
                                  [mode]="templateGrow()?.mode ?? (img.grow_mode === 'absolute' ? 'absolute' : 'percent')"
                                  (changed)="sizing.set($event)" />
                }
              }
            }
            @case (2) {
              <h2>Machine</h2>
              <div class="bm-dv-grid">
                <label>{{ target() === 'vm' ? 'VM name' : 'Name' }} <input [ngModel]="name()" (ngModelChange)="name.set($event)" name="name" placeholder="kt-web-01" /></label>
                <label>Hostname <span class="bm-wz-dim">(FQDN, defaults to the name)</span>
                  <input [ngModel]="hostname()" (ngModelChange)="hostname.set($event)" name="hostname" [placeholder]="name() || 'kt-web-01.example.org'" /></label>
                @if (target() === 'vm') {
                <label>CPU cores <input type="number" min="1" max="64" [ngModel]="cores()" (ngModelChange)="cores.set(+$event)" name="cores" /></label>
                <label>Memory (MB) <input type="number" min="512" step="512" [ngModel]="memory()" (ngModelChange)="memory.set(+$event)" name="memory" />
                  @if (minMemory() > memory()) { <span class="bm-dv-err">needs ≥ {{ minMemory() }} MB for this installer</span> }</label>
                <label>Disk (GiB) <input type="number" min="8" [ngModel]="disk()" (ngModelChange)="disk.set(+$event)" name="disk" /></label>
                }
              </div>
            }
            @case (3) {
              <h2>Network</h2>
              <p class="bm-wz-lead">A static address. "Suggest" and "Check" ask Bossman's records, NetBox and a live
                ping/ARP from an agent in the subnet — an address counts as free only when all three agree.</p>
              <div class="bm-dv-grid">
                <label>Address (CIDR) <input [ngModel]="address()" (ngModelChange)="address.set($event); ipVerdict.set(null)" name="address" placeholder="192.0.2.135/24" /></label>
                <div class="bm-dv-actions">
                  <button mat-stroked-button type="button" (click)="suggest()" [disabled]="ipBusy()"
                          [bmBlocked]="prefix() ? '' : 'Enter an address or a gateway first'" bmBlockedMode="tip">Suggest</button>
                  <button mat-stroked-button type="button" (click)="check()" [disabled]="ipBusy()"
                          [bmBlocked]="addrOnly() ? '' : 'Enter an address first'" bmBlockedMode="tip">Check</button>
                  @if (ipBusy()) { <mat-spinner diameter="18"></mat-spinner> }
                </div>
                @if (suggestions().length) {
                  <div class="bm-dv-wide bm-dv-sugg">@for (s of suggestions(); track s.address) {
                    <button type="button" class="bm-dv-chip" (click)="useSuggestion(s.address)">{{ s.address }}</button> }</div>
                }
                @if (ipVerdict(); as v) {
                  <div class="bm-dv-wide" [class.bm-wz-prefill]="v.verdict === 'free'" [class.bm-wz-warn]="v.verdict !== 'free'"
                       [class.bm-wz-warn--block]="v.verdict === 'in_use'" role="status">
                    <strong>{{ v.address }}: {{ v.verdict }}</strong> — {{ v.reason }}</div>
                }
                <label>Gateway <input [ngModel]="gateway()" (ngModelChange)="gateway.set($event)" name="gateway" placeholder="192.0.2.254" /></label>
                <label>DNS servers <span class="bm-wz-dim">(comma-separated)</span>
                  <input [ngModel]="dns()" (ngModelChange)="dns.set($event)" name="dns" placeholder="203.0.113.115" /></label>
                @if (target() === 'vm' && mode() === 'image') {
                  <label>Production VLAN <span class="bm-wz-dim">(optional — the NIC moves there after imaging)</span>
                    <input type="number" min="1" max="4094" [ngModel]="productionVlan()" (ngModelChange)="productionVlan.set($event || null)" name="prodvlan" /></label>
                }
              </div>
            }
            @case (4) {
              <h2>Roles &amp; playbook</h2>
              <p class="bm-wz-lead">Roles are desired state: bound to the new host now, they converge after its first report
                (waiting for approval unless YOLO mode is on). A playbook runs once at that moment — for example to install
                the application; check mode shows what it would change without changing it.</p>
              <label class="bm-dv-wide">Roles <span class="bm-wz-dim">(type to search {{ cat()!.roles.length }} roles, Enter adds)</span>
                <input list="bm-dv-roles" [ngModel]="roleDraft()" (ngModelChange)="roleDraft.set($event)" (keydown.enter)="addRole()"
                       (change)="addRole()" name="roles" autocomplete="off" placeholder="e.g. nginx" />
                <datalist id="bm-dv-roles">@for (r of cat()!.roles; track r.name) { <option [value]="r.name">{{ r.display_name }}</option> }</datalist></label>
              @if (roleDraft() && !roleKnown(roleDraft())) { <span class="bm-dv-err">No role is called "{{ roleDraft() }}".</span> }
              @if (roles().length) {
                <div class="bm-dv-sugg">@for (r of roles(); track r) {
                  <button type="button" class="bm-dv-chip" (click)="removeRole(r)" [attr.aria-label]="'Remove role ' + r">{{ r }} ✕</button> }</div>
              }
              <label class="bm-dv-wide">Playbook <span class="bm-wz-dim">(type to search {{ cat()!.runbooks.length }} stored runbooks; empty = none)</span>
                <input list="bm-dv-runbooks" [ngModel]="runbook()" (ngModelChange)="runbook.set($event.trim())" name="runbook"
                       placeholder="e.g. install-nginx" autocomplete="off" />
                <datalist id="bm-dv-runbooks">
                  @for (r of cat()!.runbooks; track r.name) { <option [value]="r.name">{{ r.folder }}</option> }
                </datalist></label>
              @if (runbook() && !runbookKnown()) { <span class="bm-dv-err">No stored runbook is called "{{ runbook() }}".</span> }
              @if (runbookKnown()?.description) { <div class="bm-wz-dim">{{ runbookKnown()!.description }}</div> }
              @if (runbookKnown()) {
                <div class="bm-dv-choice" role="radiogroup">
                  <label><input type="radio" name="apply" [value]="false" [ngModel]="apply()" (ngModelChange)="apply.set($event)" /> Check mode (preview)</label>
                  <label><input type="radio" name="apply" [value]="true" [ngModel]="apply()" (ngModelChange)="apply.set($event)" /> Apply</label>
                </div>
                <label class="bm-dv-wide">Variables <span class="bm-wz-dim">(JSON object, optional)</span>
                  <textarea rows="4" [ngModel]="vars()" (ngModelChange)="vars.set($event)" name="vars" placeholder='{"domain": "example.org"}'></textarea></label>
                @if (varsError()) { <span class="bm-dv-err">{{ varsError() }}</span> }
              }
            }
            @case (5) {
              <h2>Review</h2>
              <p class="bm-wz-lead">A dry run: every check Bossman makes before creating anything. Deploy unlocks when all pass.</p>
              <table class="bm-dv-sum"><tbody>
                <tr><th>Target</th><td>@if (target() === 'vm') { {{ vmHost() }} / {{ node() }} · {{ storage() }} · {{ bridge() }}@if (vlan()) { · VLAN {{ vlan() }} } }
                  @else { bare metal · {{ mac() || 'any machine that PXE-boots (wildcard)' }} }</td></tr>
                <tr><th>System</th><td>{{ mode() === 'install' ? (resolved()?.label ?? install()) : image() }}
                  @if (mode() === 'image' && sizing(); as g) { <span class="bm-wz-dim">· {{ g.mode }}: {{ sizingText() }}</span> }</td></tr>
                <tr><th>Machine</th><td>{{ effectiveHostname() }}@if (target() === 'vm') { · {{ cores() }} cores · {{ memory() }} MB · {{ disk() }} GiB }</td></tr>
                <tr><th>Network</th><td>{{ address() }} via {{ gateway() }} · DNS {{ dns() }}@if (productionVlan()) { · production VLAN {{ productionVlan() }} after imaging }</td></tr>
                <tr><th>Roles</th><td>{{ roles().length ? roles().join(', ') : '—' }}</td></tr>
                <tr><th>Playbook</th><td>@if (runbook()) { {{ runbook() }} ({{ apply() ? 'apply' : 'check mode' }}) } @else { — }</td></tr>
              </tbody></table>
              @if (mode() === 'image') {
                <div class="bm-dv-actions">
                  <input class="bm-dv-tname" [ngModel]="templateName()" (ngModelChange)="templateName.set($event)" name="tname" placeholder="template name, e.g. web-tier"
                         aria-label="Template name" />
                  <button mat-stroked-button type="button" (click)="saveTemplate()" [disabled]="savingTemplate()"
                          [bmBlocked]="templateName().trim() ? '' : 'Name the template'" bmBlockedMode="tip">Save as template</button>
                  @if (templateSaved()) { <span class="bm-wz-dim" role="status">{{ templateSaved() }}</span> }
                </div>
              }
              <div class="bm-dv-actions">
                <button mat-stroked-button type="button" (click)="dryRun()" [disabled]="busy()"><mat-icon>fact_check</mat-icon> Run checks</button>
                @if (busy()) { <mat-spinner diameter="18"></mat-spinner> }
              </div>
              @if (plan(); as p) {
                <ul class="bm-dv-checks">
                  @for (c of p.checks; track c.check) {
                    <li [class.bm-dv-ok]="c.ok" [class.bm-dv-no]="!c.ok"><mat-icon>{{ c.ok ? 'check_circle' : 'cancel' }}</mat-icon>
                      <span><strong>{{ c.check }}</strong> — {{ c.detail }}</span></li>
                  }
                </ul>
              }
              @if (deployError()) { <div class="bm-wz-warn bm-wz-warn--block" role="alert">{{ deployError() }}</div> }
            }
            @case (6) {
              <h2>Progress</h2>
              <p class="bm-wz-lead">{{ effectiveHostname() }} — @if (result()?.vmid) { VM {{ result()?.vmid }} · } MAC {{ result()?.mac || 'claimed at first PXE boot' }}. This page polls
                every 10 seconds; you can close it, the deployment continues and is listed on the page.</p>
              <ul class="bm-dv-checks">
                <li [class.bm-dv-ok]="phaseDone('vm')"><mat-icon>{{ phaseDone('vm') ? 'check_circle' : 'pending' }}</mat-icon>
                  <span>{{ target() === 'vm' ? 'VM created' : 'Host registered — power the machine on to PXE-boot it' }}</span></li>
                <li [class.bm-dv-ok]="phaseDone('boot')"><mat-icon>{{ phaseDone('boot') ? 'check_circle' : 'pending' }}</mat-icon>
                  <span>Installer mirrored, VM started @if (statusText()) { <span class="bm-wz-dim">— {{ statusText() }}</span> }</span></li>
                <li [class.bm-dv-ok]="phaseDone('agent')"><mat-icon>{{ phaseDone('agent') ? 'check_circle' : 'pending' }}</mat-icon>
                  <span>Agent reported @if (live()?.host?.last_seen_at) { <span class="bm-wz-dim">— {{ live()!.host!.last_seen_at }}</span> }</span></li>
                @for (r of roleResults(); track r.role) {
                  <li [class.bm-dv-ok]="r.ok" [class.bm-dv-no]="!r.ok"><mat-icon>{{ r.ok ? 'check_circle' : 'cancel' }}</mat-icon>
                    <span>Role {{ r.role }} — {{ r.status === 'active' ? 'bound, converges after the first report' : r.status === 'pending_approval' ? 'bound, waiting for approval' : (r.error || r.status) }}</span></li>
                }
                @if (runbook()) {
                  <li [class.bm-dv-ok]="live()?.finalize?.status === 'done'" [class.bm-dv-no]="live()?.finalize?.status === 'failed'">
                    <mat-icon>{{ live()?.finalize?.status === 'done' ? 'check_circle' : live()?.finalize?.status === 'failed' ? 'cancel' : 'pending' }}</mat-icon>
                    <span>Playbook {{ runbook() }} — {{ live()?.finalize?.status ?? 'waiting' }}
                      @if (live()?.finalize?.error) { <span class="bm-dv-err">{{ live()!.finalize!.error }}</span> }</span></li>
                }
              </ul>
              @if (failure()) { <div class="bm-wz-warn bm-wz-warn--block" role="alert">{{ failure() }}</div> }
            }
          }
          }
        </section>
      </div>
      <div class="bm-wz-foot">
        @if (blocker() && step() < 5) { <span id="bm-dv-why" class="bm-dv-why" [class.bm-dv-why--nudged]="nudged()" aria-live="polite">{{ blocker() }}</span> }
        <span class="bm-wz-spacer"></span>
        <button mat-button type="button" (click)="ref.close(deployed())">{{ deployed() ? 'Close' : 'Cancel' }}</button>
        @if (step() > 0 && !deployed()) { <button mat-stroked-button type="button" (click)="goto(step() - 1)">Back</button> }
        @if (step() < 5) { <button mat-flat-button type="button" (click)="next()" [aria-disabled]="!!blocker()"
                                   [class.bm-dv-blocked]="!!blocker()" [attr.aria-describedby]="blocker() ? 'bm-dv-why' : null">Next</button> }
        @if (step() === 5) {
          <button mat-flat-button type="button" (click)="deployNow()" [disabled]="busy()"
                  [bmBlocked]="plan()?.ok ? '' : plan() ? 'A pre-flight check failed — fix it and run the checks again' : 'Run the checks first'">
            <mat-icon>rocket_launch</mat-icon> Deploy</button>
        }
      </div>
    </div>
  `,
  styles: [`
    .bm-wz { display: flex; flex-direction: column; height: min(760px, 86vh); }
    .bm-wz-title { font-size: 18px; font-weight: 700; padding: 4px 4px 12px; display: flex; justify-content: space-between; align-items: baseline; }
    .bm-wz-host { font-size: 13px; opacity: 0.6; font-weight: 400; }
    .bm-wz-body { display: grid; grid-template-columns: 190px 1fr; gap: 18px; flex: 1; min-height: 0; }
    .bm-wz-steps { border-right: 1px solid var(--mat-sys-outline-variant); padding-right: 10px; overflow-y: auto; display: flex; flex-direction: column; }
    .bm-wz-step { display: flex; align-items: center; gap: 8px; padding: 8px 10px; font-size: 13px; border: 0; border-left: 3px solid transparent;
      background: none; color: inherit; text-align: left; opacity: 0.6; cursor: pointer; font: inherit; }
    .bm-wz-step:disabled { cursor: default; }
    .bm-wz-step--cur { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); opacity: 1; font-weight: 600; }
    .bm-wz-step--done { opacity: 0.9; }
    .bm-wz-step-ic { display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; border-radius: 50%;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 12%, transparent); font-size: 11px; }
    .bm-wz-step--done .bm-wz-step-ic { background: color-mix(in srgb, var(--bm-green, #2e7d32) 30%, transparent); }
    .bm-wz-step-ic mat-icon { font-size: 14px; width: 14px; height: 14px; }
    .bm-wz-main { overflow-y: auto; padding: 0 6px; min-width: 0; }
    .bm-wz-main h2 { margin: 4px 0 2px; }
    .bm-wz-lead { opacity: 0.72; margin: 0 0 16px; line-height: 1.5; max-width: 68ch; }
    .bm-wz-dim { opacity: 0.55; }
    .bm-wz-center { display: flex; align-items: center; gap: 10px; padding: 12px 0; }
    .bm-wz-prefill { display: flex; align-items: center; gap: 7px; font-size: 13px; margin: 8px 0 12px; padding: 7px 11px; border-radius: 6px;
      background: color-mix(in srgb, var(--bm-green, #2e7d32) 12%, transparent); }
    .bm-wz-prefill mat-icon { font-size: 18px; width: 18px; height: 18px; color: var(--bm-green, #2e7d32); }
    .bm-wz-warn { font-size: 13px; margin: 8px 0; padding: 7px 11px; border-radius: 6px; background: color-mix(in srgb, var(--bm-gold, #f9a825) 18%, transparent); }
    .bm-wz-warn--block { background: color-mix(in srgb, var(--bm-red, #d0021b) 14%, transparent);
      border: 1px solid color-mix(in srgb, var(--bm-red, #d0021b) 38%, transparent); }
    .bm-wz-foot { display: flex; align-items: center; gap: 8px; padding-top: 12px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-wz-spacer { flex: 1; }
    .bm-dv-why { font-size: 12px; opacity: 0.75; }
    .bm-dv-why--nudged { opacity: 1; font-weight: 600; color: var(--bm-red, #d0021b); }
    .bm-dv-blocked { opacity: 0.55; }
    .bm-dv-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px 16px; align-items: end; }
    .bm-dv-grid label, .bm-dv-wide { display: flex; flex-direction: column; gap: 4px; font-size: 12px; font-weight: 600; }
    .bm-dv-wide { grid-column: 1 / -1; margin: 6px 0; }
    .bm-dv-grid input, .bm-dv-grid select, .bm-dv-wide input, .bm-dv-wide select, .bm-dv-wide textarea, label > select {
      font: inherit; font-weight: 400; font-size: 13px; padding: 7px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; min-width: 0; }
    .bm-dv-choice { display: flex; gap: 18px; margin: 4px 0 14px; font-size: 13px; }
    .bm-dv-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; margin-bottom: 8px; }
    .bm-dv-card { display: flex; flex-direction: column; gap: 3px; align-items: flex-start; padding: 12px; border-radius: 10px; cursor: pointer;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: inherit; font: inherit; text-align: left; }
    .bm-dv-card:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-dv-card--sel { border-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
    .bm-dv-card-t { font-weight: 700; font-size: 14px; }
    .bm-dv-card .bm-wz-dim { font-size: 12px; }
    .bm-dv-actions { display: flex; align-items: center; gap: 8px; margin: 8px 0; }
    .bm-dv-sugg { flex-direction: row; flex-wrap: wrap; gap: 6px; }
    .bm-dv-chip { font: inherit; font-size: 12px; padding: 4px 10px; border-radius: 14px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; cursor: pointer; }
    .bm-dv-err { color: var(--bm-red, #d0021b); font-weight: 400; font-size: 12px; }
    .bm-dv-h3 { font-size: 14px; margin: 16px 0 6px; }
    .bm-dv-tname { font: inherit; font-size: 13px; padding: 6px 10px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant);
      background: var(--mat-sys-surface); color: inherit; min-width: 220px; }
    .bm-dv-sum { border-collapse: collapse; font-size: 13px; margin-bottom: 8px; }
    .bm-dv-sum th { text-align: left; padding: 4px 16px 4px 0; opacity: 0.6; font-weight: 600; vertical-align: top; }
    .bm-dv-sum td { padding: 4px 0; }
    .bm-dv-checks { list-style: none; padding: 0; margin: 8px 0; display: flex; flex-direction: column; gap: 6px; font-size: 13px; }
    .bm-dv-checks li { display: flex; gap: 8px; align-items: flex-start; }
    .bm-dv-checks mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.6; }
    .bm-dv-ok mat-icon { color: var(--bm-green, #2e7d32); opacity: 1; }
    .bm-dv-no mat-icon { color: var(--bm-red, #d0021b); opacity: 1; }
    @media (max-width: 720px) { .bm-wz-body { grid-template-columns: 1fr; } .bm-wz-steps { display: none; } }
  `],
})
export class DeployVmWizardComponent implements OnDestroy {
  readonly ref = inject(MatDialogRef<DeployVmWizardComponent>);
  private host = inject(ElementRef<HTMLElement>);
  private api = inject(VmDeployService);
  private images = inject(ImagesService);
  private data = inject<DeployWizardData | null>(MAT_DIALOG_DATA, { optional: true });

  readonly steps = ['Target', 'Operating system', 'Machine', 'Network', 'Roles & playbook', 'Review', 'Progress'];
  step = signal(0);
  maxReachable = signal(0);

  cat = signal<DeployCatalog | null>(null);
  loadError = signal('');
  vmHost = signal(''); node = signal(''); storage = signal(''); bridge = signal(''); vlan = signal<number | null>(null);
  mode = signal<'install' | 'image'>('install'); install = signal(''); image = signal('');
  resolved = signal<ResolvedInstall | null>(null); resolving = signal(false); resolveError = signal('');
  packages = signal('');
  name = signal(''); hostname = signal(''); cores = signal(2); memory = signal(4096); disk = signal(32);
  address = signal(''); gateway = signal(''); dns = signal('');
  suggestions = signal<IpVerdict[]>([]); ipVerdict = signal<IpVerdict | null>(null); ipBusy = signal(false);
  runbook = signal(''); apply = signal(false); vars = signal('');
  plan = signal<DeployResult | null>(null); busy = signal(false); deployError = signal('');
  result = signal<DeployResult | null>(null); deployed = signal(false); live = signal<DeploymentStatus | null>(null);
  target = signal<'vm' | 'bare_metal'>('vm'); mac = signal('');
  sizing = signal<GrowSizing | null>(null); productionVlan = signal<number | null>(null);
  roles = signal<string[]>([]); roleDraft = signal('');
  templates = signal<DeploymentTemplate[]>([]); templateId = signal(''); templateGrow = signal<{ mode: 'percent' | 'absolute'; policy: Record<string, number> } | null>(null);
  templateName = signal(''); savingTemplate = signal(false); templateSaved = signal('');
  private timer: ReturnType<typeof setInterval> | null = null;

  hostRow = computed(() => this.cat()?.vm_hosts.find((h) => h.name === this.vmHost()) ?? null);
  hostError = computed(() => this.hostRow()?.placement_error ?? '');
  nodes = computed<PlacementNode[]>(() => this.hostRow()?.placement?.nodes ?? []);
  curNode = computed(() => this.nodes().find((n) => n.node === this.node()) ?? null);
  readyImages = computed(() => (this.cat()?.images ?? []).filter((i) => i.status === 'ready'));
  minMemory = computed(() => this.mode() === 'install' ? (this.resolved()?.min_memory_mb ?? 0) : 0);
  effectiveHostname = computed(() => (this.hostname() || this.name()).trim());
  addrOnly = computed(() => this.address().split('/')[0].trim());
  prefix = computed(() => {
    const m = /^(\d+)\.(\d+)\.(\d+)\.\d+\/(\d+)$/.exec(this.address().trim());
    if (m) { return `${m[1]}.${m[2]}.${m[3]}.0/${m[4]}`; }
    const g = /^(\d+)\.(\d+)\.(\d+)\.\d+$/.exec(this.gateway().trim());
    return g ? `${g[1]}.${g[2]}.${g[3]}.0/24` : '';
  });
  runbookKnown = computed(() => this.cat()?.runbooks.find((r) => r.name === this.runbook()) ?? null);
  imageRow = computed(() => this.readyImages().find((i) => i.name === this.image()) ?? null);
  sizingText = computed(() => Object.entries(this.sizing()?.policy ?? {}).map(([k, v]) => `${k} ${v}`).join(', '));
  roleResults = computed(() => ((this.result()?.roles ?? []) as any[]).filter((r) => typeof r === 'object'));
  private macOk = computed(() => /^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(this.mac()));
  varsError = computed(() => {
    if (!this.vars().trim()) { return ''; }
    try { const v = JSON.parse(this.vars()); return v && typeof v === 'object' && !Array.isArray(v) ? '' : 'must be a JSON object'; }
    catch { return 'not valid JSON'; }
  });

  /** Why "Next" cannot go on from this step, and the field to fix — shown next to Next, which stays focusable
   *  (aria-disabled, not disabled): a click on it moves the focus to that field instead of doing nothing. */
  gate = computed<{ text: string; field: string } | null>(() => {
    const g = (text: string, field: string) => ({ text, field });
    switch (this.step()) {
      case 0: return this.target() === 'bare_metal'
        ? (this.mac() && !this.macOk() ? g('MAC address: six pairs of hex digits, e.g. aa:bb:cc:dd:ee:ff', 'mac') : null)
        : !this.vmHost() ? g('Choose a hypervisor', 'vmhost') : !this.node() ? g('Choose a node', 'node')
        : !this.storage() ? g('Choose a storage', 'storage') : !this.bridge() ? g('Choose a bridge', 'bridge') : null;
      case 1: return this.mode() === 'install'
        ? (!this.install() ? g('Choose a distribution', 'install') : this.resolving() ? g('Resolving the release…', 'install')
          : !this.resolved() ? g('The release could not be resolved', 'install')
          : this.target() === 'bare_metal' && !this.mac() ? g('A network install needs the machine\'s MAC (Target step)', 'install') : null)
        : (!this.image() ? g('Choose an image', 'image') : this.sizing()?.error ? g(`Sizing: ${this.sizing()!.error}`, 'image') : null);
      case 2: return !/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/.test(this.name()) ? g('Name: lowercase letters, digits and dashes', 'name')
        : this.target() === 'vm' && this.minMemory() > this.memory() ? g(`Memory must be at least ${this.minMemory()} MB`, 'memory') : null;
      case 3: return !/^\d+\.\d+\.\d+\.\d+\/\d+$/.test(this.address().trim()) ? g('Address must be CIDR, e.g. 192.0.2.135/24', 'address')
        : !/^\d+\.\d+\.\d+\.\d+$/.test(this.gateway().trim()) ? g('Enter the gateway', 'gateway')
        : this.ipVerdict()?.verdict === 'in_use' ? g('This address is in use', 'address') : null;
      case 4: return this.roleDraft() && !this.roleKnown(this.roleDraft()) ? g('Pick a role from the list or clear the field', 'roles')
        : this.runbook() && !this.runbookKnown() ? g('Choose a stored runbook or leave the field empty', 'runbook')
        : this.varsError() ? g(`Variables: ${this.varsError()}`, 'vars') : null;
      default: return null;
    }
  });
  blocker = computed(() => this.gate()?.text ?? '');
  nudged = signal(false);

  next(): void {
    const g = this.gate();
    if (!g) { this.nudged.set(false); this.goto(this.step() + 1); return; }
    this.nudged.set(true);
    const el = this.host.nativeElement.querySelector(`[name="${g.field}"], [data-field="${g.field}"]`) as HTMLElement | null;
    el?.focus();
  }

  constructor() {
    this.api.catalog().subscribe({
      next: (c) => {
        this.cat.set(c);
        if (c.vm_hosts.length === 1) { this.vmHost.set(c.vm_hosts[0].name); }
        // Opened from Disk images on one image: golden-image mode with that image chosen.
        if (this.data?.image && c.images.some((i) => i.name === this.data!.image && i.status === 'ready')) {
          this.mode.set('image'); this.image.set(this.data.image);
        }
      },
      error: (e) => this.loadError.set(this.err(e, 'Loading the hypervisors failed')),
    });
    this.images.listTemplates().subscribe({ next: (t) => this.templates.set(t), error: () => this.templates.set([]) });
  }

  roleKnown(name: string): boolean { return !!this.cat()?.roles.some((r) => r.name === name.trim()); }

  addRole(): void {
    const n = this.roleDraft().trim();
    if (n && this.roleKnown(n) && !this.roles().includes(n)) { this.roles.set([...this.roles(), n]); }
    if (!n || this.roleKnown(n)) { this.roleDraft.set(''); }
  }

  removeRole(name: string): void { this.roles.set(this.roles().filter((r) => r !== name)); }

  /** A saved template fills image, sizing, network and roles — the same template the old wizard saved. */
  applyTemplate(id: string): void {
    this.templateId.set(id);
    const t = this.templates().find((x) => x.id === id);
    if (!t) { this.templateGrow.set(null); return; }
    const img = this.cat()?.images.find((i) => i.id === t.image_id);
    if (img) { this.mode.set('image'); this.image.set(img.name); }
    this.templateGrow.set(Object.keys(t.grow_policy || {}).length ? { mode: t.grow_mode, policy: t.grow_policy } : null);
    const net = t.network as { address?: string; gateway?: string; dns?: string[] };
    if (net?.address) { this.address.set(net.address); }
    if (net?.gateway) { this.gateway.set(net.gateway); }
    if (net?.dns?.length) { this.dns.set(net.dns.join(', ')); }
    this.roles.set([...(t.roles || [])]);
    this.templateName.set(t.name);
  }

  saveTemplate(): void {
    const img = this.imageRow();
    if (!this.templateName().trim()) { return; }
    this.savingTemplate.set(true);
    this.images.saveTemplate({
      name: this.templateName().trim(), image_id: img?.id ?? null,
      grow_mode: this.sizing()?.mode ?? 'percent', grow_policy: this.sizing()?.policy ?? {},
      network: { mode: 'static', address: this.address().trim(), gateway: this.gateway().trim(),
                 dns: this.dns().split(',').map((d) => d.trim()).filter(Boolean) } as any,
      roles: this.roles(),
    }).subscribe({
      next: (t) => { this.savingTemplate.set(false); this.templateSaved.set(`Saved as "${t.name}"`);
                     this.images.listTemplates().subscribe((all) => this.templates.set(all)); },
      error: (e) => { this.savingTemplate.set(false); this.templateSaved.set(this.err(e, 'Saving the template failed')); },
    });
  }

  ngOnDestroy(): void { if (this.timer) { clearInterval(this.timer); } }

  gib(bytes: number): string { return (bytes / 1024 ** 3).toFixed(0); }

  goto(i: number): void {
    if (i > this.step() && this.blocker()) { return; }
    this.step.set(i);
    this.nudged.set(false);
    this.maxReachable.set(Math.max(this.maxReachable(), i));
    if (i === 5) { this.dryRun(); }
  }

  pickInstall(install: string): void {
    this.install.set(install);
    this.resolved.set(null);
    this.resolveError.set('');
    this.resolving.set(true);
    this.api.resolveInstall(install).subscribe({
      next: (r) => {
        this.resolved.set(r);
        this.packages.set(r.default_packages.join(' '));
        if (this.memory() < r.min_memory_mb) { this.memory.set(r.min_memory_mb); }
        this.resolving.set(false);
      },
      error: (e) => { this.resolveError.set(this.err(e, 'Resolving the release failed')); this.resolving.set(false); },
    });
  }

  suggest(): void {
    this.ipBusy.set(true);
    this.api.suggestIps(this.prefix(), 5).subscribe({
      next: (r) => { this.suggestions.set(r.free); this.ipBusy.set(false); },
      error: (e) => { this.ipVerdict.set({ address: this.prefix(), verdict: 'unknown', reason: this.err(e, 'suggest failed'), sources: {} }); this.ipBusy.set(false); },
    });
  }

  useSuggestion(addr: string): void {
    const len = this.prefix().split('/')[1] || '24';
    this.address.set(`${addr}/${len}`);
    this.check();
  }

  check(): void {
    this.ipBusy.set(true);
    const len = Number(this.address().split('/')[1] || 24);
    this.api.checkIp([this.addrOnly()], len).subscribe({
      next: (r) => { this.ipVerdict.set(r[0] ?? null); this.ipBusy.set(false); },
      error: (e) => { this.ipVerdict.set({ address: this.addrOnly(), verdict: 'unknown', reason: this.err(e, 'check failed'), sources: {} }); this.ipBusy.set(false); },
    });
  }

  private request(dryRun: boolean): DeployRequest {
    const pk = this.packages().trim().split(/\s+/).filter(Boolean);
    const vm = this.target() === 'vm';
    return {
      target: this.target(), mac: vm ? '' : this.mac(),
      vm_host: vm ? this.vmHost() : '', node: vm ? this.node() : '', name: this.name(), storage: vm ? this.storage() : '',
      bridge: vm ? this.bridge() : '', vlan: vm ? (this.vlan() || null) : null,
      address: this.address().trim(), gateway: this.gateway().trim(),
      dns: this.dns().split(',').map((d) => d.trim()).filter(Boolean),
      image: this.mode() === 'image' ? this.image() : null,
      install: this.mode() === 'install' ? `${this.install()}${this.resolved() ? '-' + this.resolved()!.release : ''}` : null,
      hostname: this.hostname().trim() || null, cores: this.cores(), memory_mb: this.memory(), disk_gib: this.disk(),
      packages: this.mode() === 'install' ? pk : null,
      finalize_runbook: this.runbook() || null,
      finalize_variables: this.vars().trim() ? JSON.parse(this.vars()) : {},
      finalize_apply: this.apply(), dry_run: dryRun,
      roles: this.roles(),
      grow_policy: this.mode() === 'image' ? (this.sizing()?.policy ?? null) : null,
      grow_mode: this.sizing()?.mode ?? 'percent',
      production_vlan: vm && this.mode() === 'image' ? this.productionVlan() : null,
    };
  }

  dryRun(): void {
    this.busy.set(true);
    this.deployError.set('');
    this.api.deploy(this.request(true)).subscribe({
      next: (r) => { this.plan.set(r); this.busy.set(false); },
      error: (e) => { this.deployError.set(this.err(e, 'The checks could not run')); this.busy.set(false); },
    });
  }

  deployNow(): void {
    this.busy.set(true);
    this.deployError.set('');
    this.api.deploy(this.request(false)).subscribe({
      next: (r) => {
        this.result.set(r); this.deployed.set(true); this.busy.set(false);
        this.step.set(6); this.maxReachable.set(6);
        this.poll();
        this.timer = setInterval(() => this.poll(), 10000);
      },
      error: (e) => {
        const d = e?.error?.detail;
        if (d?.checks) { this.plan.set({ ...(this.plan() as DeployResult), ok: false, checks: d.checks }); }
        this.deployError.set(this.err(e, 'Deploy refused'));
        this.busy.set(false);
      },
    });
  }

  private poll(): void {
    this.api.status(this.effectiveHostname()).subscribe({ next: (s) => this.live.set(s), error: () => undefined });
  }

  statusText = computed(() => {
    const s = this.live();
    return s?.install ? s.install.status : s?.restore ? `${s.restore.status} (step ${s.restore.step})` : '';
  });

  phaseDone(phase: 'vm' | 'boot' | 'agent'): boolean {
    const s = this.live();
    if (phase === 'vm') { return this.target() === 'vm' ? !!this.result()?.vmid : !!this.result(); }
    if (phase === 'boot') { return !!s && (s.install ? s.install.status !== 'pending' : !!s.restore && s.restore.status !== 'pending'); }
    return !!s?.host?.last_seen_at;
  }

  failure = computed(() => {
    const s = this.live();
    return s?.install?.status === 'failed' ? (s.install.error || 'The install failed') :
      s?.restore?.status === 'failed' ? (s.restore.error || 'The restore failed') : '';
  });

  private err(e: any, fallback: string): string {
    const d = e?.error?.detail;
    return typeof d === 'string' ? d : d?.message ?? e?.message ?? fallback;
  }
}
