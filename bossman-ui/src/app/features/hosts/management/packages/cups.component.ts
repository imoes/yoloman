import { Component, inject, input, signal } from '@angular/core';
import { MatIconModule } from '@angular/material/icon';
import { MatButtonModule } from '@angular/material/button';
import { AgentService } from '../../../../core/services/agent.service';

interface Printer { name: string; uri: string; state: string; isDefault: boolean; }

/**
 * CUPS snapin — printer management via lpadmin/lpstat/lpinfo (the essential
 * CUPS task). List printers with their device URI/state/default, add a printer
 * (device URI + driver; "everywhere" = driverless IPP), set the default, and
 * delete. "Detect devices" runs `lpinfo -v` to populate discovered URIs.
 * Replaces the old key/value editor, which mangled cupsd.conf's Apache-style
 * <Location>/<Limit>/<Policy> blocks into broken rows.
 */
@Component({
  selector: 'app-cups',
  standalone: true,
  imports: [MatIconModule, MatButtonModule],
  template: `
    <div class="bm-cups">
      @if (loading()) { <p class="bm-dim">Loading printers…</p> }
      @else {
        <div class="bm-head">
          <span class="bm-dim">CUPS printers</span>
          <button mat-stroked-button (click)="reload()"><mat-icon>refresh</mat-icon> Reload</button>
          <span class="bm-spacer"></span>
          @if (msg()) { <span class="bm-ok">{{ msg() }}</span> }
          @if (err()) { <span class="bm-err">{{ err() }}</span> }
        </div>

        <section class="bm-card">
          <header><h3>Printers</h3></header>
          <table class="bm-t">
            <thead><tr><th>Name</th><th>Device URI</th><th>State</th><th>Default</th><th></th></tr></thead>
            <tbody>
              @for (p of printers(); track p.name) {
                <tr>
                  <td class="bm-mono">{{ p.name }}</td>
                  <td class="bm-mono">{{ p.uri }}</td>
                  <td>{{ p.state }}</td>
                  <td>@if (p.isDefault) { <mat-icon class="bm-star">star</mat-icon> } @else { <button class="bm-link" (click)="setDefault(p)" [disabled]="busy()">set default</button> }</td>
                  <td><button class="bm-x" (click)="del(p)" [disabled]="busy()" title="Delete printer">🗑</button></td>
                </tr>
              }
              @if (!printers().length) { <tr><td colspan="5" class="bm-dim">No printers configured.</td></tr> }
            </tbody>
          </table>
        </section>

        <section class="bm-card">
          <header class="bm-cardhead"><h3>Add printer</h3>
            <span>
              <button mat-button (click)="detect()" [disabled]="busy()"><mat-icon>search</mat-icon> Detect devices</button>
              <button mat-button (click)="loadModels()" [disabled]="busy()"><mat-icon>dns</mat-icon> Load driver DB</button>
            </span>
          </header>
          <div class="bm-form">
            <label class="bm-fld">Name<input [value]="nName()" (input)="nName.set($any($event.target).value)" placeholder="office-laser" /></label>
            <label class="bm-fld bm-uri">Device URI
              <input [value]="nUri()" (input)="nUri.set($any($event.target).value)" placeholder="ipp://printer.local/ipp/print" list="cups-devs" />
              <datalist id="cups-devs">@for (d of devices(); track d) { <option [value]="d"></option> }</datalist>
            </label>
            <label class="bm-fld bm-model">Driver / model
              <input [value]="nModel()" (input)="nModel.set($any($event.target).value)" placeholder="everywhere" list="cups-models" />
              <datalist id="cups-models">
                <option value="everywhere">Driverless IPP Everywhere</option>
                <option value="raw">Raw / passthrough queue</option>
                @for (m of models(); track m.name) { <option [value]="m.name">{{ m.desc }}</option> }
              </datalist>
            </label>
            <label class="bm-fld">Location<input [value]="nLoc()" (input)="nLoc.set($any($event.target).value)" placeholder="optional" /></label>
            <button mat-raised-button color="primary" (click)="add()" [disabled]="busy() || !nName().trim() || !nUri().trim()">Add printer</button>
          </div>
          <p class="bm-hint">Driver: <code>everywhere</code> = driverless IPP (modern network printers); or a PPD/model name from the driver DB (click “Load driver DB” for the dropdown), or <code>raw</code> for a passthrough queue. @if (devMsg()) { <span class="bm-dim">— {{ devMsg() }}</span> } @if (modelMsg()) { <span class="bm-dim">— {{ modelMsg() }}</span> }</p>
        </section>
      }
    </div>
  `,
  styles: [`
    .bm-cups { display: flex; flex-direction: column; gap: 14px; }
    .bm-head { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    .bm-spacer { flex: 1; }
    .bm-card { border: 1px solid var(--mat-sys-outline-variant); border-radius: 10px; overflow: hidden; }
    .bm-card > header, .bm-cardhead { padding: 9px 14px; border-bottom: 1px solid var(--mat-sys-outline-variant); display: flex; align-items: center; justify-content: space-between; }
    .bm-card h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .bm-t { width: 100%; border-collapse: collapse; }
    .bm-t th { text-align: left; font-size: 12px; opacity: 0.7; padding: 5px 8px; }
    .bm-t td { padding: 5px 8px; border-top: 1px solid var(--mat-sys-outline-variant); font-size: 13px; vertical-align: middle; }
    .bm-mono { font-family: ui-monospace, monospace; font-size: 12px; word-break: break-all; }
    .bm-star { color: #f5a623; font-size: 18px; width: 18px; height: 18px; }
    .bm-link { border: 0; background: none; color: var(--mat-sys-primary); cursor: pointer; font-size: 12px; padding: 0; }
    .bm-form { padding: 12px 14px; display: flex; gap: 12px; flex-wrap: wrap; align-items: flex-end; }
    .bm-fld { display: flex; flex-direction: column; gap: 4px; font-size: 12px; }
    .bm-fld.bm-uri { flex: 1; min-width: 260px; }
    .bm-fld input { padding: 6px 9px; border-radius: 6px; border: 1px solid var(--mat-sys-outline-variant); background: var(--mat-sys-surface); color: var(--mat-sys-on-surface); font-size: 13px; }
    .bm-hint { font-size: 12px; opacity: 0.7; padding: 0 14px 12px; }
    .bm-hint code { font-family: ui-monospace, monospace; background: color-mix(in srgb, var(--mat-sys-on-surface) 8%, transparent); padding: 1px 5px; border-radius: 4px; }
    .bm-x { border: 0; background: transparent; cursor: pointer; opacity: 0.6; }
    .bm-dim { opacity: 0.6; font-size: 13px; } .bm-ok { color: var(--bm-green,#2e7d32); font-size: 13px; } .bm-err { color: var(--mat-sys-error,#c62828); font-size: 13px; }
  `],
})
export class CupsComponent {
  private agentService = inject(AgentService);
  agentId = input.required<string>();

  loading = signal(false);
  loaded = signal(false);
  busy = signal(false);
  msg = signal(''); err = signal(''); devMsg = signal(''); modelMsg = signal('');
  printers = signal<Printer[]>([]);
  devices = signal<string[]>([]);
  models = signal<{ name: string; desc: string }[]>([]);
  nName = signal(''); nUri = signal(''); nModel = signal('everywhere'); nLoc = signal('');

  loadOnce(): void { if (!this.loaded() && !this.loading()) this.reload(); }

  reload(): void {
    this.loading.set(true); this.msg.set(''); this.err.set('');
    // -v: "device for NAME: URI"; -p: state lines; -d: default destination.
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', 'echo "===V==="; lpstat -v 2>/dev/null; echo "===P==="; lpstat -p 2>/dev/null; echo "===D==="; lpstat -d 2>/dev/null; true'] }).subscribe({
      next: (resp) => {
        this.loading.set(false); this.loaded.set(true);
        this.printers.set(this.parse((resp.result as { data?: { stdout?: string } })?.data?.stdout || ''));
      },
      error: () => { this.loading.set(false); this.loaded.set(true); this.printers.set([]); },
    });
  }

  private parse(out: string): Printer[] {
    const [v = '', rest = ''] = out.split('===P===');
    const [p = '', d = ''] = rest.split('===D===');
    const map = new Map<string, Printer>();
    for (const line of v.replace('===V===', '').split('\n')) {
      const m = /^device for (.+?):\s*(.+)$/.exec(line.trim());
      if (m) map.set(m[1], { name: m[1], uri: m[2].trim(), state: '', isDefault: false });
    }
    for (const line of p.split('\n')) {
      const m = /^printer (.+?) is (\w+)/.exec(line.trim());
      if (m) { const pr = map.get(m[1]) ?? { name: m[1], uri: '', state: '', isDefault: false }; pr.state = m[2]; map.set(m[1], pr); }
    }
    const dm = /system default destination:\s*(.+)$/.exec(d.trim());
    const def = dm ? dm[1].trim() : '';
    if (def && map.has(def)) map.get(def)!.isDefault = true;
    return [...map.values()];
  }

  detect(): void {
    this.busy.set(true); this.devMsg.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', 'lpinfo -v 2>/dev/null || true'] }).subscribe({
      next: (resp) => {
        this.busy.set(false);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        // lines: "<class> <uri>"; keep real device URIs (skip bare backends).
        const devs = out.split('\n').map((l) => l.trim().split(/\s+/)[1]).filter((u): u is string => !!u && u.includes(':') && u.includes('/'));
        this.devices.set([...new Set(devs)]);
        this.devMsg.set(`${this.devices().length} device(s) discovered`);
      },
      error: () => { this.busy.set(false); this.devMsg.set('device detection failed'); },
    });
  }

  loadModels(): void {
    this.busy.set(true); this.modelMsg.set('');
    // lpinfo -m: "<ppd-name> <lang> <make-and-model description>" per line.
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', 'lpinfo -m 2>/dev/null || true'] }).subscribe({
      next: (resp) => {
        this.busy.set(false);
        const out = (resp.result as { data?: { stdout?: string } })?.data?.stdout || '';
        const ms: { name: string; desc: string }[] = [];
        for (const line of out.split('\n')) {
          const t = line.trim();
          if (!t) continue;
          const sp = t.indexOf(' ');
          if (sp < 0) continue;
          const name = t.slice(0, sp);
          const desc = t.slice(sp + 1).trim();
          if (name && name !== 'everywhere' && name !== 'raw') ms.push({ name, desc });
        }
        // Cap the datalist so a driver DB with thousands of PPDs stays snappy;
        // the field stays free-text so any model name still works.
        this.models.set(ms.slice(0, 2000));
        this.modelMsg.set(`${ms.length} driver(s) in the DB${ms.length > 2000 ? ' (showing 2000 — type to match others)' : ''}`);
      },
      error: () => { this.busy.set(false); this.modelMsg.set('driver DB unavailable'); },
    });
  }

  add(): void {
    const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
    const name = this.nName().trim(), uri = this.nUri().trim(), model = this.nModel().trim() || 'everywhere', loc = this.nLoc().trim();
    let cmd = `lpadmin -p ${q(name)} -E -v ${q(uri)} -m ${q(model)}`;
    if (loc) cmd += ` -L ${q(loc)}`;
    cmd += `; cupsenable ${q(name)} 2>/dev/null; cupsaccept ${q(name)} 2>/dev/null; true`;
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['sh', '-c', cmd] }).subscribe({
      next: (resp) => {
        this.busy.set(false);
        const d = (resp.result as { data?: { rc?: number; stderr?: string } })?.data;
        if ((d?.rc ?? 0) !== 0 && d?.stderr) { this.err.set(d.stderr); return; }
        this.msg.set(`Added ${name}.`); this.nName.set(''); this.nUri.set(''); this.nModel.set('everywhere'); this.nLoc.set(''); this.reload();
      },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'add failed'); },
    });
  }

  setDefault(p: Printer): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['lpadmin', '-d', p.name] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`${p.name} is now default.`); this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'failed'); },
    });
  }

  del(p: Printer): void {
    this.busy.set(true); this.msg.set(''); this.err.set('');
    this.agentService.callTool(this.agentId(), 'command', { argv: ['lpadmin', '-x', p.name] }).subscribe({
      next: () => { this.busy.set(false); this.msg.set(`Deleted ${p.name}.`); this.reload(); },
      error: (e) => { this.busy.set(false); this.err.set(e?.error?.detail || 'delete failed'); },
    });
  }
}
