import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, inject, input, signal } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { environment } from '../../../environments/environment';
import { Agent } from '../../core/models/agent.model';
import { AuthService } from '../../core/auth/auth.service';

type Status = 'connecting' | 'open' | 'closed';

/**
 * Proxmox-style web shell for a host. An xterm.js terminal over a WebSocket to
 * Bossman's console proxy (WS /api/v1/agents/{id}/console), which relays to the
 * agent's PTY running /bin/login — so the OS login prompt appears here and the
 * operator authenticates in the terminal. Keystrokes go as binary frames,
 * output arrives as binary, and terminal resizes are sent as a JSON control
 * frame. The bearer token rides in the query string (browsers can't set an
 * Authorization header on a WebSocket).
 */
@Component({
  selector: 'app-host-console',
  standalone: true,
  imports: [MatButtonModule, MatIconModule],
  template: `
    <div class="bm-console">
      <div class="bm-bar">
        <span class="bm-dot bm-{{ status() }}"></span>
        <span class="bm-status">{{ statusText() }}</span>
        <span class="bm-hint">Log in with your OS credentials.</span>
        <span class="bm-spacer"></span>
        <button mat-stroked-button (click)="reconnect()" [disabled]="status() === 'connecting'">
          <mat-icon>refresh</mat-icon> Reconnect
        </button>
      </div>
      <div #term class="bm-term"></div>
    </div>
  `,
  styles: [`
    .bm-console { display: flex; flex-direction: column; gap: 8px; }
    .bm-bar { display: flex; align-items: center; gap: 10px; }
    .bm-spacer { flex: 1; }
    .bm-hint { opacity: 0.6; font-size: 12.5px; }
    .bm-dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
    .bm-dot.bm-open { background: var(--bm-green, #2e7d32); }
    .bm-dot.bm-connecting { background: var(--bm-gold, #caa300); }
    .bm-dot.bm-closed { background: var(--bm-red, #d32f2f); }
    .bm-term { height: 70vh; min-height: 360px; background: #000; border-radius: 8px; padding: 6px; overflow: hidden; }
  `],
})
export class HostConsoleComponent implements AfterViewInit, OnDestroy {
  agent = input.required<Agent>();
  private auth = inject(AuthService);
  @ViewChild('term') termEl!: ElementRef<HTMLDivElement>;

  status = signal<Status>('connecting');

  private term?: Terminal;
  private fit?: FitAddon;
  private ws?: WebSocket;
  private onWinResize = () => this.fit?.fit();

  statusText(): string {
    return { connecting: 'Connecting…', open: 'Connected', closed: 'Disconnected' }[this.status()];
  }

  ngAfterViewInit(): void {
    this.open();
  }

  ngOnDestroy(): void {
    this.teardown();
  }

  reconnect(): void {
    this.teardown();
    this.open();
  }

  /** ws(s)://<bossman-host>/api/v1/agents/{id}/console?token=… derived from the
   * REST apiUrl, which may be absolute (dev) or root-relative (prod). */
  private wsUrl(): string {
    const api = environment.apiUrl;
    const base = api.startsWith('http') ? new URL(api) : new URL(api, window.location.origin);
    const proto = base.protocol === 'https:' ? 'wss:' : 'ws:';
    const token = this.auth.getToken() ?? '';
    return `${proto}//${base.host}${base.pathname}/agents/${this.agent().id}/console?token=${encodeURIComponent(token)}`;
  }

  private open(): void {
    this.status.set('connecting');
    const term = new Terminal({
      cursorBlink: true,
      fontFamily: 'ui-monospace, "Cascadia Code", Menlo, monospace',
      fontSize: 13,
      theme: { background: '#000000', foreground: '#e0e0e0' },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(this.termEl.nativeElement);
    fit.fit();
    this.term = term;
    this.fit = fit;

    const ws = new WebSocket(this.wsUrl());
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    const enc = new TextEncoder();

    ws.onopen = () => {
      this.status.set('open');
      this.sendResize();
      term.focus();
    };
    ws.onmessage = (ev: MessageEvent) => {
      if (typeof ev.data === 'string') term.write(ev.data);
      else term.write(new Uint8Array(ev.data as ArrayBuffer));
    };
    ws.onclose = () => {
      this.status.set('closed');
      term.write('\r\n\x1b[31m[disconnected]\x1b[0m\r\n');
    };
    ws.onerror = () => this.status.set('closed');

    term.onData((d) => {
      if (ws.readyState === WebSocket.OPEN) ws.send(enc.encode(d));
    });
    term.onResize(() => this.sendResizeFrame());
    window.addEventListener('resize', this.onWinResize);
  }

  private sendResize(): void {
    this.fit?.fit();
    this.sendResizeFrame();
  }

  private sendResizeFrame(): void {
    if (!this.term || !this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify({ type: 'resize', cols: this.term.cols, rows: this.term.rows }));
  }

  private teardown(): void {
    window.removeEventListener('resize', this.onWinResize);
    if (this.ws) {
      this.ws.onclose = null;
      this.ws.close();
      this.ws = undefined;
    }
    this.term?.dispose();
    this.term = undefined;
    this.fit = undefined;
  }
}
