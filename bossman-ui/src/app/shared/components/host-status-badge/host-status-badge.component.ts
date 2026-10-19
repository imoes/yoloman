import { Component, input } from '@angular/core';
import { BadgeStatus } from '../../status.util';
import { StatusPillComponent } from '../../status-pill/status-pill.component';

/** A computed BadgeStatus (ok/warn/crit/unknown) shown with a label that is NOT itself a status word — a host
 * name on a dashboard tile, an enrollment state whose health comes from last_seen_at. It draws through
 * bm-status-pill, so it has the same icon + text + tone look as every other status; where the label IS the
 * status word, use `<bm-status-pill [status]="word" />` directly. */
@Component({
  selector: 'app-status-badge',
  standalone: true,
  imports: [StatusPillComponent],
  template: `<bm-status-pill [status]="status()" [label]="label() || status()" />`,
})
export class HostStatusBadgeComponent {
  status = input.required<BadgeStatus>();
  label = input<string>('');
}
