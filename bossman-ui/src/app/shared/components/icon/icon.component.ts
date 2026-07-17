import { Component, Input } from '@angular/core';
import { DomSanitizer, SafeHtml } from '@angular/platform-browser';
import { inject } from '@angular/core';

/**
 * A bespoke line-icon set for Bossman (docs/design-philosophy.md): one
 * coherent 24-grid, 1.8px stroke, round-cap/round-join family drawn to the
 * macOS bar — crisp at any size, themeable via `currentColor`, no icon-font.
 * `<app-icon name="deploy" />`. Status/brand marks that carry the Rastafari
 * tricolour are the only multi-colour ones; everything else inherits colour.
 *
 * Only the icons the app actually needs live here; add a path to ICONS to
 * grow the set. Unknown names render nothing (never a broken glyph).
 */
type IconDef = string; // inner SVG markup for a 0 0 24 24 viewBox

const S = 'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"';

const ICONS: Record<string, IconDef> = {
  // ── navigation ──
  fleet: `<g ${S}><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></g>`,
  problems: `<g ${S}><path d="M12 3.5 22 20H2L12 3.5Z"/><path d="M12 10v4"/><circle cx="12" cy="17" r=".6" fill="currentColor" stroke="none"/></g>`,
  topology: `<g ${S}><circle cx="6" cy="6" r="2.5"/><circle cx="18" cy="6" r="2.5"/><circle cx="12" cy="18" r="2.5"/><path d="M7.7 7.8 10.6 16M16.3 7.8 13.4 16M8.2 6h7.6"/></g>`,
  security: `<g ${S}><path d="M12 3 5 6v5c0 4.4 3 7.7 7 9 4-1.3 7-4.6 7-9V6l-7-3Z"/><path d="m9 12 2 2 4-4.5"/></g>`,
  'host-placement': `<g ${S}><rect x="9" y="3" width="6" height="5" rx="1"/><rect x="3" y="16" width="6" height="5" rx="1"/><rect x="15" y="16" width="6" height="5" rx="1"/><path d="M12 8v3M6 16v-2h12v2M12 14v-3"/></g>`,
  roles: `<g ${S}><path d="M12 3 3 7.5 12 12l9-4.5L12 3Z"/><path d="M3 12.5 12 17l9-4.5M3 17 12 21.5 21 17"/></g>`,
  deploy: `<g ${S}><path d="M12 3c3.5 1.5 5.5 5 5.5 9L15 14.5H9L6.5 12C6.5 8 8.5 4.5 12 3Z"/><circle cx="12" cy="9.5" r="1.6"/><path d="M9 15l-2 3.5M15 15l2 3.5M12 15v4"/></g>`,
  runs: `<g ${S}><path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1"/><path d="M3 4v3.5h3.5"/><path d="M12 8v4l3 2"/></g>`,
  help: `<g ${S}><circle cx="12" cy="12" r="9"/><path d="M9.6 9.3a2.5 2.5 0 0 1 4.8.9c0 1.7-2.4 2.2-2.4 3.8"/><circle cx="12" cy="17" r=".6" fill="currentColor" stroke="none"/></g>`,
  setup: `<g ${S}><path d="M4 6h10M18 6h2M4 12h2M10 12h10M4 18h8M16 18h4"/><circle cx="16" cy="6" r="2"/><circle cx="8" cy="12" r="2"/><circle cx="14" cy="18" r="2"/></g>`,
  // ── setup section ──
  hosts: `<g ${S}><rect x="3" y="4" width="18" height="6" rx="1.5"/><rect x="3" y="14" width="18" height="6" rx="1.5"/><path d="M7 7h.01M7 17h.01"/></g>`,
  notifications: `<g ${S}><path d="M18 8a6 6 0 1 0-12 0c0 6-2.5 7.5-2.5 7.5h17S18 14 18 8Z"/><path d="M10.5 19a2 2 0 0 0 3 0"/></g>`,
  'ou-policy': `<g ${S}><rect x="4" y="3" width="16" height="18" rx="1.5"/><path d="M8 7h3M8 11h3M8 15h3M14 7h2M14 11h2M14 15h2"/></g>`,
  modules: `<g ${S}><path d="M10 4H6a2 2 0 0 0-2 2v4h2.5a1.8 1.8 0 1 1 0 3.6H4V18a2 2 0 0 0 2 2h4v-2.5a1.8 1.8 0 1 1 3.6 0V20h4a2 2 0 0 0 2-2v-4h-2.5a1.8 1.8 0 1 1 0-3.6H20V6a2 2 0 0 0-2-2h-4"/></g>`,
  checks: `<g ${S}><rect x="5" y="4" width="14" height="17" rx="1.5"/><path d="M9 3.5h6v2.5H9zM8.5 12l2 2 4-4.5"/></g>`,
  'config-templates': `<g ${S}><rect x="4" y="3" width="16" height="18" rx="1.5"/><path d="M9 9l-2 2 2 2M15 9l2 2-2 2"/></g>`,
  users: `<g ${S}><circle cx="9" cy="8" r="3"/><path d="M3.5 20a5.5 5.5 0 0 1 11 0"/><path d="M16 5.2a3 3 0 0 1 0 5.6M20.5 20a5.5 5.5 0 0 0-4-5.3"/></g>`,
  settings: `<g ${S}><circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M21.5 12h-3M5.5 12h-3M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1M18.7 18.7l-2.1-2.1M7.4 7.4 5.3 5.3"/></g>`,
  workflow: `<g ${S}><rect x="3" y="4" width="6" height="5" rx="1.2"/><rect x="15" y="4" width="6" height="5" rx="1.2"/><rect x="9" y="15" width="6" height="5" rx="1.2"/><path d="M6 9v2.5a1.5 1.5 0 0 0 1.5 1.5H12M18 9v2.5a1.5 1.5 0 0 1-1.5 1.5H12M12 13v2"/></g>`,
  // ── actions ──
  add: `<g ${S}><path d="M12 5v14M5 12h14"/></g>`,
  logout: `<g ${S}><path d="M14 4h4a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-4"/><path d="M10 8l-4 4 4 4M6 12h9"/></g>`,
  'chevron-down': `<g ${S}><path d="m7 10 5 5 5-5"/></g>`,
  // ── status dots (Rasta palette; multi-colour, fill-based) ──
  'dot-ok': `<circle cx="12" cy="12" r="6" fill="var(--bm-green)"/>`,
  'dot-warn': `<circle cx="12" cy="12" r="6" fill="var(--bm-gold)"/>`,
  'dot-crit': `<circle cx="12" cy="12" r="6" fill="var(--bm-red)"/>`,
  'dot-unknown': `<circle cx="12" cy="12" r="6" fill="var(--bm-unknown)"/>`,
};

/** The Rastafari brand mark: a shield split into the green/gold/red tricolour
 * with a "B" cut out — a crisp vector replacement for the raster logo. */
export const BRAND_MARK = `
<svg viewBox="0 0 40 40" width="40" height="40" role="img" aria-label="Bossman">
  <defs><clipPath id="bm-sh"><path d="M20 2 4 8v12c0 9 7 15 16 18 9-3 16-9 16-18V8L20 2Z"/></clipPath></defs>
  <g clip-path="url(#bm-sh)">
    <rect x="0" y="0" width="40" height="13.3" fill="#1e9600"/>
    <rect x="0" y="13.3" width="40" height="13.3" fill="#ffc800"/>
    <rect x="0" y="26.6" width="40" height="13.4" fill="#d0021b"/>
  </g>
  <path d="M20 2 4 8v12c0 9 7 15 16 18 9-3 16-9 16-18V8L20 2Z" fill="none" stroke="#0d0d0d" stroke-width="1.5"/>
  <text x="20" y="26" text-anchor="middle" font-family="system-ui,Arial" font-weight="800" font-size="18" fill="#0d0d0d">B</text>
</svg>`;

@Component({
  selector: 'app-icon',
  standalone: true,
  template: `<span class="bm-icon" [innerHTML]="svg" [style.width.px]="size" [style.height.px]="size"></span>`,
  styles: [`
    .bm-icon { display: inline-flex; align-items: center; justify-content: center; line-height: 0; }
    .bm-icon ::ng-deep svg { width: 100%; height: 100%; display: block; }
  `],
})
export class IconComponent {
  private sanitizer = inject(DomSanitizer);
  @Input() size = 20;
  private _name = '';
  svg: SafeHtml = '';

  @Input() set name(n: string) {
    this._name = n;
    const inner = ICONS[n] ?? '';
    this.svg = this.sanitizer.bypassSecurityTrustHtml(
      inner ? `<svg viewBox="0 0 24 24" role="img" aria-label="${n}">${inner}</svg>` : '',
    );
  }
  get name(): string { return this._name; }
}
