import { Directive, ElementRef, Input, OnChanges, OnDestroy, Renderer2, inject } from '@angular/core';
import { MatButton, MatFabButton, MatIconButton, MatMiniFabButton } from '@angular/material/button';

let nextId = 0;

/**
 * A Material action button that is blocked by a validation or precondition — and says WHY.
 *
 *   <button mat-flat-button (click)="save()" [disabled]="saving()" [bmBlocked]="saveBlocked()">Save</button>
 *
 * `bmBlocked` is the reason ('' / null = not blocked). While it is set the button stays focusable and
 * announced (Material's `aria-disabled` input, not native `disabled`: a natively disabled button is
 * skipped by the keyboard and never tells a screen reader why), a click is swallowed before the
 * component's own (click) handler runs, and the reason is rendered next to the button and linked to it
 * via aria-describedby (CLAUDE.md "Formale Logik" rule 4: every refusal names its reason). The pattern is
 * the one deploy-vm-wizard proved; this directive is that pattern in one place, so 150 buttons do not each
 * re-implement it. Native `[disabled]` stays for the in-flight case only (busy/saving/…); the lint
 * `npm run lint:disabled` enforces the split.
 *
 * `bmBlockedMode`: 'inline' (default) shows the reason as small text after the button; 'tip' — the default
 * for icon buttons and right for per-row actions, where a sentence per row would drown the table — keeps
 * it as the button's tooltip and for assistive tech, and shows it inline only once a blocked click asks.
 */
@Directive({
  selector: '[bmBlocked]',
  standalone: true,
})
export class BlockedReasonDirective implements OnChanges, OnDestroy {
  @Input() bmBlocked: string | null | undefined | false = '';
  @Input() bmBlockedMode: 'inline' | 'tip' | '' = '';

  private host = inject<ElementRef<HTMLElement>>(ElementRef);
  private r = inject(Renderer2);
  private button = inject(MatButton, { self: true, optional: true })
    ?? inject(MatIconButton, { self: true, optional: true })
    ?? inject(MatFabButton, { self: true, optional: true })
    ?? inject(MatMiniFabButton, { self: true, optional: true });
  private isIcon = !!inject(MatIconButton, { self: true, optional: true });
  private id = `bm-blocked-${++nextId}`;
  private why: HTMLElement | null = null;
  private unlisten: (() => void) | null = null;
  /** The button's own tooltip ("Reload", "Delete"), held while 'tip' mode shows the reason in its place. */
  private ownTitle: string | null = null;

  private get reason(): string { return (this.bmBlocked || '').trim(); }
  private get mode(): 'inline' | 'tip' { return this.bmBlockedMode || (this.isIcon ? 'tip' : 'inline'); }

  constructor() {
    // Capture phase on the button itself: runs before the template's (click) listener, so a blocked
    // click never reaches the handler (and a type="submit" never submits).
    const el = this.host.nativeElement;
    const onClick = (e: Event) => {
      if (!this.reason) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      this.why?.classList.add('bm-blocked-why--nudged');
    };
    el.addEventListener('click', onClick, true);
    this.unlisten = () => el.removeEventListener('click', onClick, true);
  }

  ngOnChanges(): void {
    const reason = this.reason;
    // Set before the button's host bindings run in this same change-detection pass.
    if (this.button) this.button.ariaDisabled = reason ? true : undefined;
    const el = this.host.nativeElement;
    el.classList.toggle('bm-blocked', !!reason);
    if (!reason) {
      this.removeWhy();
      el.removeAttribute('aria-describedby');
      this.restoreTitle();
      return;
    }
    if (!this.why) {
      this.why = this.r.createElement('span') as HTMLElement;
      this.why.id = this.id;
      this.why.setAttribute('aria-live', 'polite');
      const parent = this.r.parentNode(el);
      if (parent) this.r.insertBefore(parent, this.why, this.r.nextSibling(el));
    }
    this.why.className = this.mode === 'tip' ? 'bm-blocked-why bm-blocked-why--tip' : 'bm-blocked-why';
    this.why.textContent = reason;
    el.setAttribute('aria-describedby', this.id);
    if (this.mode === 'tip') {
      if (this.ownTitle === null) this.ownTitle = el.getAttribute('title') ?? '';
      el.setAttribute('title', reason);
    }
  }

  ngOnDestroy(): void {
    this.unlisten?.();
    this.removeWhy();
  }

  private restoreTitle(): void {
    if (this.ownTitle === null) return;
    const el = this.host.nativeElement;
    if (this.ownTitle) el.setAttribute('title', this.ownTitle);
    else el.removeAttribute('title');
    this.ownTitle = null;
  }

  private removeWhy(): void {
    this.why?.remove();
    this.why = null;
  }
}
