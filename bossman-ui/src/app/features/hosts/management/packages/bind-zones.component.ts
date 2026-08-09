import { Component, computed, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';
import { ConfigResource } from '../../../../core/models/agent.model';

interface Zone { name: string; file: string; }
interface Rec { name: string; ttl: string; class: string; type: string; data: string; }

const NAMED_CONF_LOCAL = '/etc/bind/named.conf.local';
const RR_TYPES = ['A', 'AAAA', 'CNAME', 'MX', 'NS', 'PTR', 'SRV', 'TXT', 'SOA', 'CAA', 'NAPTR', 'SSHFP'];

/**
 * bind DNS zone-lifecycle snapin. Lists the master zones declared in
 * named.conf.local, creates a new one (writes the `zone "x" { … };` include
 * directive via blockinfile + a starter zone file through the zonefile codec +
 * `rndc reload`), and edits a zone's resource records in a typed table
 * (round-tripped through the zonefile codec). This is the codec-less part bind
 * needs beyond the zonefile codec — the include directive in named.conf.local.
 */
@Component({
  selector: 'app-bind-zones',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-bz">
      @if (loading()) { <p class="bm-dim">Loading zones…</p> }
      @else {
        <div class="bm-bz-cols">
          <!-- Zone list + create -->
          <aside class="bm-bz-zones">
            <div class="bm-bz-h">Zones ({{ zones().length }})</div>
            @for (z of zones(); track z.name) {
              <button class="bm-bz-zone" [class.sel]="selected()?.name === z.name" (click)="selectZone(z)">
                <mat-icon>dns</mat-icon><span>{{ z.name }}</span>
              </button>
            }
            @if (!zones().length) { <p class="bm-dim bm-bz-none">No master zones declared yet.</p> }
            <div class="bm-bz-create">
              <input class="bm-in" #zn placeholder="new zone e.g. example.com" [disabled]="busy()" />
              <button mat-stroked-button (click)="createZone(zn.value); zn.value=''" [disabled]="busy()"><mat-icon>add</mat-icon> Create zone</button>
            </div>
            @if (msg()) { <p class="bm-ok">{{ msg() }}</p> }
            @if (err()) { <p class="bm-err">{{ err() }}</p> }
          </aside>

          <!-- Records of the selected zone -->
          <section class="bm-bz-recs">
            @if (!selected()) { <p class="bm-dim">Select a zone to edit its records, or create one.</p> }
            @else {
              <div class="bm-bz-h2">
                <strong>{{ selected()!.name }}</strong> <span class="bm-dim">· {{ selected()!.file }}</span>
                <span class="bm-spacer"></span>
                <label class="bm-dry"><input type="checkbox" [checked]="dryRun()" (change)="dryRun.set($any($event.target).checked)" /> dry-run</label>
                <button mat-raised-button color="primary" (click)="saveRecords()" [disabled]="busy()">{{ dryRun() ? 'Preview' : 'Save + reload' }}</button>
              </div>
              <table class="bm-kv">
                <thead><tr><th>Name</th><th>TTL</th><th>Class</th><th>Type</th><th>Data</th><th></th></tr></thead>
                <tbody>
                  @for (r of records(); track $index) {
                    <tr>
                      <td><input class="bm-in bm-sm" [value]="r.name" (input)="setRec($index,'name',$any($event.target).value)" /></td>
                      <td><input class="bm-in bm-xs" [value]="r.ttl" (input)="setRec($index,'ttl',$any($event.target).value)" /></td>
                      <td><input class="bm-in bm-xs" [value]="r.class || 'IN'" (input)="setRec($index,'class',$any($event.target).value)" /></td>
                      <td>
                        <select class="bm-in bm-sm" [value]="r.type" (change)="setRec($index,'type',$any($event.target).value)">
                          @for (t of rrTypes; track t) { <option [value]="t" [selected]="t===r.type">{{ t }}</option> }
                        </select>
                      </td>
                      <td><input class="bm-in" [value]="r.data" (input)="setRec($index,'data',$any($event.target).value)" /></td>
                      <td><button class="bm-x" (click)="removeRec($index)" title="Remove record">✕</button></td>
                    </tr>
                  }
                </tbody>
              </table>
              <button mat-button (click)="addRec()"><mat-icon>add</mat-icon> Add record</button>
            }
          </section>
        </div>
      }
    </div>
  `,
  styles: [`
    .bm-bz-cols { display: grid; grid-template-columns: 260px 1fr; gap: 16px; align-items: start; }
    .bm-bz-h, .bm-bz-h2 { font-weight: 600; margin-bottom: 10px; }
    .bm-bz-h2 { display: flex; align-items: center; gap: 8px; }
    .bm-spacer { flex: 1; }
    .bm-bz-zone { display: flex; align-items: center; gap: 8px; width: 100%; text-align: left; border: 0; background: transparent;
      cursor: pointer; padding: 6px 8px; border-radius: 6px; color: inherit; font-size: 13.5px; }
    .bm-bz-zone:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 6%, transparent); }
    .bm-bz-zone.sel { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent); font-weight: 600; }
    .bm-bz-zone mat-icon { font-size: 18px; width: 18px; height: 18px; opacity: 0.8; }
    .bm-bz-create { margin-top: 12px; display: flex; flex-direction: column; gap: 6px; }
    .bm-bz-none { padding: 4px 8px; }
    .bm-dry { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; }
    .bm-kv { width: 100%; border-collapse: collapse; }
    .bm-kv th { text-align: left; font-size: 12px; opacity: 0.7; padding: 4px 6px; }
    .bm-kv td { padding: 3px 6px; border-top: 1px solid var(--mat-sys-outline-variant); }
    .bm-in { width: 100%; box-sizing: border-box; padding: 4px 8px; border-radius: 6px;
      border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); }
    .bm-sm { min-width: 120px; } .bm-xs { width: 70px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.55; }
    .bm-dim { opacity: 0.6; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class BindZonesComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  readonly rrTypes = RR_TYPES;
  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal('');
  err = signal('');
  dryRun = signal(false);
  zones = signal<Zone[]>([]);
  selected = signal<Zone | null>(null);
  records = signal<Rec[]>([]);

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    // named.conf.local has no codec — read it raw and regex the zone blocks.
    this.agentService.callTool(this.agentId(), 'command', { argv: ['cat', NAMED_CONF_LOCAL] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        const text = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        this.zones.set(this.parseZones(text));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.zones.set([]); },
    });
  }

  private parseZones(text: string): Zone[] {
    const out: Zone[] = [];
    const re = /zone\s+"([^"]+)"\s*(?:in\s+)?\{([^}]*)\}/gi;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) {
      const body = m[2];
      const fm = /file\s+"([^"]+)"/i.exec(body);
      if (fm) out.push({ name: m[1], file: fm[1] });
    }
    return out;
  }

  createZone(name: string): void {
    name = (name || '').trim().replace(/\.$/, '');
    if (!name) return;
    if (this.zones().some((z) => z.name === name)) { this.err.set(`Zone ${name} already exists.`); return; }
    const file = `/etc/bind/db.${name}`;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const block = `zone "${name}" {\n    type master;\n    file "${file}";\n};`;
    // 1) declare the zone in named.conf.local (the include directive) via a
    //    per-zone marked block (idempotent + individually removable).
    this.agentService.callTool(this.agentId(), 'blockinfile', {
      path: NAMED_CONF_LOCAL, block, marker: `// {mark} bossman zone ${name}`, create: true,
    }).subscribe({
      next: () => {
        // 2) write a starter zone file (SOA + NS) through the zonefile codec.
        const soa = `ns1.${name}. admin.${name}. 1 3600 1800 604800 86400`;
        const res: ConfigResource = {
          type: 'config', path: file, format: 'zonefile',
          values: {
            '$TTL': '3600', '$ORIGIN': `${name}.`,
            records: [
              { name: '@', class: 'IN', type: 'SOA', data: soa },
              { name: '@', class: 'IN', type: 'NS', data: `ns1.${name}.` },
              { name: 'ns1', class: 'IN', type: 'A', data: '127.0.0.1' },
            ],
          },
        };
        this.agentService.stateApply(this.agentId(), [res], false).subscribe({
          next: () => this.reloadBind(() => {
            this.busy.set(false); this.msg.set(`Zone ${name} created.`); this.reload();
          }),
          error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Zone file write failed.'); },
        });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'named.conf.local update failed.'); },
    });
  }

  selectZone(z: Zone): void {
    this.selected.set(z); this.records.set([]); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'config', { path: z.file, format: 'zonefile' }).subscribe({
      next: (resp) => {
        const data = (resp.result as { data?: { config?: { records?: unknown } } })?.data?.config;
        const recs = (data?.records as Rec[]) || [];
        this.records.set(recs.map((r) => ({ name: r.name || '', ttl: r.ttl || '', class: r.class || 'IN', type: r.type || 'A', data: r.data || '' })));
        this._origin = (data as { ['$ORIGIN']?: string })?.['$ORIGIN'] || `${z.name}.`;
        this._ttl = (data as { ['$TTL']?: string })?.['$TTL'] || '3600';
      },
      error: () => this.records.set([]),
    });
  }
  private _origin = ''; private _ttl = '3600';

  setRec(i: number, k: keyof Rec, v: string): void {
    this.records.update((rs) => { const c = [...rs]; c[i] = { ...c[i], [k]: v }; return c; });
  }
  addRec(): void { this.records.update((rs) => [...rs, { name: '', ttl: '', class: 'IN', type: 'A', data: '' }]); }
  removeRec(i: number): void { this.records.update((rs) => rs.filter((_, j) => j !== i)); }

  saveRecords(): void {
    const z = this.selected(); if (!z) return;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    const res: ConfigResource = {
      type: 'config', path: z.file, format: 'zonefile',
      values: { '$TTL': this._ttl, '$ORIGIN': this._origin, records: this.records() },
    };
    this.agentService.stateApply(this.agentId(), [res], this.dryRun()).subscribe({
      next: (resp) => {
        const n = resp.plan?.changed_count ?? 0;
        if (this.dryRun()) { this.busy.set(false); this.msg.set(`Preview: ${n} change(s) — nothing written.`); return; }
        this.reloadBind(() => { this.busy.set(false); this.msg.set(`Saved ${n} change(s) + reloaded bind.`); });
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'Save failed.'); },
    });
  }

  /** rndc reload — best-effort; bind picks up the new/edited zone. */
  private reloadBind(done: () => void): void {
    this.agentService.callTool(this.agentId(), 'command', { argv: ['rndc', 'reload'] }).subscribe({ next: () => done(), error: () => done() });
  }
}
