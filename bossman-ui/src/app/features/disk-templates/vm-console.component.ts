import { AfterViewInit, Component, ElementRef, OnDestroy, ViewChild, inject, signal } from '@angular/core';
import { ActivatedRoute } from '@angular/router';
import RFB from '@novnc/novnc/lib/rfb.js';
import { environment } from '../../../environments/environment';
import { AuthService } from '../../core/auth/auth.service';

/**
 * Chrome-less noVNC console for a lab VM (route /vm-console/:name), opened in its own window from the
 * disk-templates lab panel. Mirrors console-page.component.ts, but embeds noVNC's RFB against the
 * Bossman VNC relay (/api/v1/vm/{name}/vnc) instead of an xterm PTY. The relay proxies to the VM's
 * websockify bridge in the pxe container; the bearer token rides the query string (a browser can't set
 * an Authorization header on a WebSocket). See docs/pxe-baremetal-imaging.md.
 */
@Component({
  selector: 'app-vm-console',
  standalone: true,
  template: `
    <div class="vc-page">
      <div class="vc-bar">
        <span class="vc-title">{{ name() }}</span>
        <span class="vc-dim">{{ status() }}</span>
      </div>
      <div #screen class="vc-screen"></div>
      @if (error()) { <p class="vc-err">{{ error() }}</p> }
    </div>
  `,
  styles: [`
    :host { display: block; height: 100vh; }
    .vc-page { display: flex; flex-direction: column; height: 100vh; background: #000; }
    .vc-bar { display: flex; align-items: baseline; gap: 10px; padding: 8px 14px; background: #111; color: #ddd; border-bottom: 1px solid #333; }
    .vc-title { font-family: monospace; font-weight: 600; }
    .vc-dim { opacity: 0.55; font-size: 12.5px; }
    .vc-screen { flex: 1; min-height: 0; }
    .vc-err { color: #f48771; padding: 16px; }
  `],
})
export class VmConsoleComponent implements AfterViewInit, OnDestroy {
  @ViewChild('screen', { static: true }) screen!: ElementRef<HTMLDivElement>;
  private route = inject(ActivatedRoute);
  private auth = inject(AuthService);

  name = signal<string>('');
  status = signal<'connecting' | 'connected' | 'disconnected'>('connecting');
  error = signal<string>('');
  private rfb?: RFB;

  ngAfterViewInit(): void {
    const name = this.route.snapshot.paramMap.get('name') ?? '';
    this.name.set(name);
    document.title = `${name} — console`;
    if (!name) { this.error.set('no VM name'); return; }
    try {
      const rfb = new RFB(this.screen.nativeElement, this.vncUrl(name));
      rfb.scaleViewport = true;
      rfb.addEventListener('connect', () => this.status.set('connected'));
      rfb.addEventListener('disconnect', (e: Event) => {
        this.status.set('disconnected');
        const clean = (e as CustomEvent<{ clean?: boolean }>).detail?.clean;
        if (!clean) this.error.set('connection closed');
      });
      this.rfb = rfb;
    } catch (e) {
      this.error.set(`could not connect: ${e}`);
    }
  }

  ngOnDestroy(): void { this.rfb?.disconnect(); }

  /** ws(s)://<bossman-host>/api/v1/vm/{name}/vnc?token=… — derived from the REST apiUrl. */
  private vncUrl(name: string): string {
    const api = environment.apiUrl;
    const base = api.startsWith('http') ? new URL(api) : new URL(api, window.location.origin);
    const proto = base.protocol === 'https:' ? 'wss:' : 'ws:';
    const token = this.auth.getToken() ?? '';
    return `${proto}//${base.host}${base.pathname}/vm/${encodeURIComponent(name)}/vnc?token=${encodeURIComponent(token)}`;
  }
}
