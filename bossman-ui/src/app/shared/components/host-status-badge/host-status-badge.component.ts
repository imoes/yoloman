import { Component, input } from '@angular/core';
import { BadgeStatus } from '../../status.util';

/** The single source of truth for the status pill/dot look, used
 * everywhere a host, plan run, or edge health needs to show at a glance
 * (see docs/plan.md's Bossman plan, section C.3's shared component list). */
@Component({
  selector: 'app-status-badge',
  standalone: true,
  template: ` <span class="bm-badge" [class]="'bm-badge--' + status()">{{ label() }}</span> `,
  styles: [
    `
      .bm-badge {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 2px 10px;
        border-radius: 999px;
        font-size: 12px;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.02em;
        white-space: nowrap;
      }
      .bm-badge::before {
        content: '';
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: currentColor;
        flex: none;
      }
      .bm-badge--ok {
        color: var(--bm-green);
        background: color-mix(in srgb, var(--bm-green) 18%, transparent);
      }
      .bm-badge--warn {
        color: var(--bm-gold);
        background: color-mix(in srgb, var(--bm-gold) 18%, transparent);
      }
      .bm-badge--crit {
        color: var(--bm-red);
        background: color-mix(in srgb, var(--bm-red) 18%, transparent);
      }
      .bm-badge--unknown {
        color: var(--bm-unknown);
        background: color-mix(in srgb, var(--bm-unknown) 18%, transparent);
      }
    `,
  ],
})
export class HostStatusBadgeComponent {
  status = input.required<BadgeStatus>();
  label = input<string>('');
}
