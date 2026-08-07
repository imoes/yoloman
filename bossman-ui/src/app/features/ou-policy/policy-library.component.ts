import { Component, OnInit, inject, signal } from '@angular/core';
import { MatDialog, MatDialogModule } from '@angular/material/dialog';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { OuService, PolicySet, PolicySetDetail } from '../../core/services/ou.service';
import { DialogService } from '../../shared/dialogs/dialog.service';
import { PolicyGpeditDialogComponent, PolicyGpeditDialogData } from './policy-gpedit-dialog.component';

/**
 * The named-policy LIBRARY as a Miller-column browser (the user's request):
 *   column 1  Policies (named, scope-independent)
 *   column 2  Entries of the selected policy (one per config file)
 *   column 3  ALL set values at a glance (every key=value across the entries),
 *             at the far right — so you see the whole policy's content on click.
 * A policy is authored here (create → add entries via the gpedit editor) and
 * linked to an OU/Site elsewhere (drag from the palette / the tree).
 */
@Component({
  selector: 'app-policy-library',
  standalone: true,
  imports: [MatDialogModule, MatButtonModule, MatIconModule],
  template: `
    <h2 mat-dialog-title>Policy library</h2>
    <mat-dialog-content>
      <div class="pl-miller">
        <!-- Column 1: policies -->
        <div class="pl-col pl-col-sets">
          <div class="pl-col-head">
            <span>Policies</span>
            <button mat-stroked-button class="pl-new" (click)="newPolicy()"><mat-icon>add</mat-icon> New</button>
          </div>
          @for (s of sets(); track s.id) {
            <div class="pl-item" [class.sel]="selected()?.id === s.id" (click)="pick(s)">
              <mat-icon class="pl-ic">dataset</mat-icon>
              <div class="pl-item-main">
                <div class="pl-item-name">{{ s.name }}</div>
                <div class="pl-item-sub">{{ s.entry_count }} entr{{ s.entry_count === 1 ? 'y' : 'ies' }} · {{ s.scope_label }}</div>
              </div>
            </div>
          } @empty { <p class="pl-dim">No policies yet — click New.</p> }
        </div>

        <!-- Column 2: entries of the selected policy -->
        <div class="pl-col pl-col-entries">
          @if (selected(); as d) {
            <div class="pl-col-head">
              <span>Entries</span>
              <button mat-stroked-button class="pl-new" (click)="addEntry(d)"><mat-icon>note_add</mat-icon> Add file</button>
            </div>
            @for (e of d.entries; track e.id) {
              <div class="pl-item" [class.sel]="selectedPath() === e.path" (click)="selectedPath.set(e.path)">
                <mat-icon class="pl-ic">description</mat-icon>
                <div class="pl-item-main">
                  <div class="pl-item-name">{{ e.path }}</div>
                  <div class="pl-item-sub">{{ e.type === 'template_render' ? 'template' : keyCount(e.values) + ' key' + (keyCount(e.values) === 1 ? '' : 's') }}</div>
                </div>
                <button mat-icon-button class="pl-del" (click)="deleteEntry(e, d); $event.stopPropagation()" title="Remove entry"><mat-icon>close</mat-icon></button>
              </div>
            } @empty { <p class="pl-dim">No entries — add a config file.</p> }
          } @else { <p class="pl-dim">Pick a policy.</p> }
        </div>

        <!-- Column 3 (far right): all values of the policy, at a glance -->
        <div class="pl-col pl-col-values">
          @if (selected(); as d) {
            <div class="pl-col-head"><span>Values</span></div>
            @if (d.values_flat.length) {
              @for (v of d.values_flat; track v.path + v.key) {
                <div class="pl-val" [class.dim]="selectedPath() && selectedPath() !== v.path">
                  <span class="pl-val-file">{{ shortPath(v.path) }}</span>
                  <span class="pl-val-key">{{ v.key }}</span>
                  <span class="pl-val-eq">=</span>
                  <span class="pl-val-v">{{ fmt(v.value) }}</span>
                </div>
              }
            } @else { <p class="pl-dim">This policy has no values yet.</p> }
          } @else { <p class="pl-dim">—</p> }
        </div>
      </div>
    </mat-dialog-content>
    <mat-dialog-actions align="end">
      @if (selected(); as d) {
        <button mat-button (click)="renamePolicy(d)">Rename…</button>
        <button mat-button class="pl-danger" (click)="deletePolicy(d)">Delete policy</button>
      }
      <span class="pl-spacer"></span>
      <button mat-flat-button color="primary" mat-dialog-close>Close</button>
    </mat-dialog-actions>
  `,
  styles: [
    `
      mat-dialog-content { min-width: min(920px, 90vw); }
      .pl-miller { display: flex; gap: 12px; height: 440px; }
      .pl-col { flex: 1 1 0; min-width: 0; border: 1px solid var(--mat-sys-outline-variant); border-radius: 8px; overflow-y: auto; }
      .pl-col-values { flex: 1.2 1 0; }
      .pl-col-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; position: sticky; top: 0;
        background: var(--mat-sys-surface); padding: 8px 10px; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; opacity: 0.85; border-bottom: 1px solid var(--bm-hairline); }
      .pl-new { transform: scale(0.82); transform-origin: right center; }
      .pl-item { display: flex; align-items: center; gap: 8px; padding: 6px 10px; cursor: pointer; border-left: 3px solid transparent; }
      .pl-item:hover { background: var(--bm-hover, color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent)); }
      .pl-item.sel { border-left-color: var(--mat-sys-primary); background: color-mix(in srgb, var(--mat-sys-primary) 10%, transparent); }
      .pl-ic { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
      .pl-item-main { min-width: 0; flex: 1; }
      .pl-item-name { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .pl-item-sub { font-size: 11px; opacity: 0.6; }
      .pl-del { transform: scale(0.7); opacity: 0.6; }
      .pl-del:hover { opacity: 1; color: var(--bm-red); }
      .pl-val { display: flex; align-items: baseline; gap: 6px; padding: 4px 10px; font-size: 12.5px; border-bottom: 1px solid var(--bm-hairline); }
      .pl-val.dim { opacity: 0.4; }
      .pl-val-file { font-size: 10.5px; opacity: 0.55; min-width: 88px; font-family: ui-monospace, monospace; }
      .pl-val-key { font-weight: 600; }
      .pl-val-eq { opacity: 0.5; }
      .pl-val-v { font-family: ui-monospace, monospace; opacity: 0.9; overflow: hidden; text-overflow: ellipsis; }
      .pl-dim { opacity: 0.6; font-size: 13px; padding: 10px; }
      .pl-spacer { flex: 1; }
      .pl-danger { color: var(--bm-red); }
    `,
  ],
})
export class PolicyLibraryComponent implements OnInit {
  private ouService = inject(OuService);
  private dialog = inject(MatDialog);
  private appDialog = inject(DialogService);

  sets = signal<PolicySet[]>([]);
  selected = signal<PolicySetDetail | null>(null);
  selectedPath = signal<string | null>(null);

  ngOnInit(): void { this.reload(); }

  private reload(keepId?: string): void {
    this.ouService.listPolicySets().subscribe((s) => {
      this.sets.set(s);
      const id = keepId ?? this.selected()?.id;
      if (id && s.some((x) => x.id === id)) this.load(id);
      else if (!s.length) this.selected.set(null);
    });
  }

  private load(id: string): void {
    this.ouService.getPolicySet(id).subscribe((d) => this.selected.set(d));
  }

  pick(s: PolicySet): void { this.selectedPath.set(null); this.load(s.id); }

  keyCount(v: Record<string, unknown>): number { return Object.keys(v || {}).length; }
  shortPath(p: string): string { return p.split('/').pop() || p; }
  fmt(v: unknown): string { return v === null ? '(removed)' : typeof v === 'object' ? JSON.stringify(v) : String(v); }

  async newPolicy(): Promise<void> {
    const name = await this.appDialog.prompt({ title: 'New policy', message: 'A named policy groups several config files.', input: { label: 'Name', value: '' } });
    if (name == null || !name.trim()) return;
    this.ouService.createPolicySet({ name: name.trim() }).subscribe({
      next: (d) => this.reload(d.id),
      error: (e: { error?: { detail?: string } }) => this.appDialog.notify(e?.error?.detail ?? 'create failed', 'error'),
    });
  }

  async renamePolicy(d: PolicySetDetail): Promise<void> {
    const name = await this.appDialog.prompt({ title: 'Rename policy', input: { label: 'Name', value: d.name } });
    if (name == null || !name.trim()) return;
    this.ouService.patchPolicySet(d.id, { name: name.trim() }).subscribe({ next: () => this.reload(d.id), error: (e: { error?: { detail?: string } }) => this.appDialog.notify(e?.error?.detail ?? 'rename failed', 'error') });
  }

  async deletePolicy(d: PolicySetDetail): Promise<void> {
    const ok = await this.appDialog.confirm({ title: 'Delete policy', message: `Delete "${d.name}" and its ${d.entry_count} entr${d.entry_count === 1 ? 'y' : 'ies'}?`, confirmText: 'Delete', danger: true });
    if (!ok) return;
    this.ouService.deletePolicySet(d.id).subscribe(() => { this.selected.set(null); this.reload(); });
  }

  /** Add a config-file entry via the gpedit editor, scoped to this set. */
  addEntry(d: PolicySetDetail): void {
    const scope: PolicyGpeditDialogData['scope'] = { kind: 'set', id: d.id, label: d.name };
    this.dialog.open<PolicyGpeditDialogComponent, PolicyGpeditDialogData>(
      PolicyGpeditDialogComponent, { data: { scope }, width: 'min(1100px, 94vw)', maxWidth: '94vw' },
    ).afterClosed().subscribe(() => this.reload(d.id));
  }

  deleteEntry(e: PolicySetDetail['entries'][number], d: PolicySetDetail): void {
    this.ouService.deleteConfigPolicy(e.id).subscribe(() => this.reload(d.id));
  }
}
