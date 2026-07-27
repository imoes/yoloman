import {
  AfterViewInit, Component, ElementRef, EventEmitter, Input, OnDestroy, Output, ViewChild,
} from '@angular/core';
import * as Blockly from 'blockly';

/**
 * Angular wrapper around Blockly.inject — the ansible-manager playbook designer
 * uses the same "don't pull in ngx-blockly, just wrap inject()" approach (its
 * peer deps fight our framework version). This component owns the workspace
 * lifecycle: inject on view-init, dispose on destroy, re-measure on resize, and
 * relay non-UI change events out so the parent can regenerate the runbook.
 *
 * It is deliberately dumb: block definitions, toolbox, generator and importer
 * all live outside it (blocks.ts / generator.ts / importer.ts) so this file
 * never needs to change as the runbook block vocabulary grows.
 */
@Component({
  selector: 'app-blockly-workspace',
  standalone: true,
  template: `<div #host class="bm-blockly-host"></div>`,
  styles: [`
    :host { display: block; width: 100%; height: 100%; }
    .bm-blockly-host { width: 100%; height: 100%; }
    /* Blockly injects an absolutely-positioned widget/dropdown div into <body>;
       keep it above our Material overlays. */
    ::ng-deep .blocklyWidgetDiv, ::ng-deep .blocklyDropDownDiv, ::ng-deep .blocklyTooltipDiv { z-index: 2100; }
    /* The reference toolbox uses Blockly's light Classic theme (grey #ddd bg,
       near-white labels) — unreadable in our dark UI. Recolour the toolbox +
       flyout for dark, keeping the category-colour accent bars. */
    ::ng-deep .blocklyToolboxDiv { background: var(--mat-sys-surface-container, #26282b) !important; color: var(--mat-sys-on-surface, #e6e6e6); }
    ::ng-deep .blocklyTreeLabel { color: var(--mat-sys-on-surface, #e6e6e6) !important; }
    ::ng-deep .blocklyTreeRow { color: var(--mat-sys-on-surface, #e6e6e6); }
    ::ng-deep .blocklyToolboxCategory { color: var(--mat-sys-on-surface, #e6e6e6); }
    ::ng-deep .blocklyFlyoutBackground { fill: var(--mat-sys-surface, #1a1c1e) !important; fill-opacity: 0.96; }
    /* toolbox-search input */
    ::ng-deep .blocklyToolboxDiv input, ::ng-deep .blocklyToolboxCategory input {
      background: var(--mat-sys-surface, #1a1c1e); color: var(--mat-sys-on-surface, #e6e6e6);
      border: 1px solid var(--mat-sys-outline-variant, #444); border-radius: 4px;
    }
  `],
})
export class BlocklyWorkspaceComponent implements AfterViewInit, OnDestroy {
  @ViewChild('host', { static: true }) hostRef!: ElementRef<HTMLDivElement>;

  /** Toolbox definition (JSON toolbox). Applied at inject and on change. */
  @Input() toolbox: Blockly.utils.toolbox.ToolboxDefinition | null = null;
  /** Initial workspace state (Blockly JSON serialization). */
  @Input() initialState: object | null = null;

  /** Fires on every non-UI workspace change (block add/move/field edit/delete),
   * carrying the live workspace so the parent can serialize it. */
  @Output() workspaceChange = new EventEmitter<Blockly.WorkspaceSvg>();
  /** Fires once the workspace exists, for imperative wiring (import, etc.). */
  @Output() ready = new EventEmitter<Blockly.WorkspaceSvg>();

  private ws?: Blockly.WorkspaceSvg;
  private resizeObs?: ResizeObserver;
  private changeListener = (e: Blockly.Events.Abstract) => {
    if (e.isUiEvent) return;              // ignore pan/zoom/select — only content changes
    if (this.ws) this.workspaceChange.emit(this.ws);
  };

  ngAfterViewInit(): void {
    this.ws = Blockly.inject(this.hostRef.nativeElement, {
      toolbox: this.toolbox ?? undefined,
      // Vendored locally (public/assets/blockly) — Blockly's default media URL
      // points at appspot.com, which the app's CSP blocks.
      media: 'assets/blockly/',
      renderer: 'geras',
      theme: Blockly.Themes.Classic,
      trashcan: true,
      zoom: { controls: true, wheel: false, startScale: 1 },
      grid: { spacing: 24, length: 3, colour: '#e6e6e6', snap: true },
      horizontalLayout: true,
      toolboxPosition: 'start',
    });

    if (this.initialState) {
      Blockly.serialization.workspaces.load(this.initialState, this.ws);
    }
    this.ws.addChangeListener(this.changeListener);

    // Gentler, trackpad-proportional wheel zoom (built-in wheel zoom jumps
    // scaleSpeed² per notch) — same tweak as the reference designer.
    this.hostRef.nativeElement.addEventListener('wheel', this.onWheel, { passive: false });

    // Keep the SVG sized to the container as the layout/window changes.
    this.resizeObs = new ResizeObserver(() => { if (this.ws) Blockly.svgResize(this.ws); });
    this.resizeObs.observe(this.hostRef.nativeElement);

    // E2E hook (same as the reference designer's window.__pbWorkspace) so tests
    // can drive the workspace; harmless in production.
    (window as unknown as { __rbWorkspace?: Blockly.WorkspaceSvg }).__rbWorkspace = this.ws;

    this.ready.emit(this.ws);
  }

  private onWheel = (e: WheelEvent): void => {
    if (!this.ws) return;
    e.preventDefault();
    const amount = -e.deltaY / 200;
    const metrics = this.ws.getMetrics();
    this.ws.zoom((metrics.viewWidth / 2), (metrics.viewHeight / 2), amount);
  };

  /** The live workspace, for imperative use (serialize/import) by the parent. */
  get workspace(): Blockly.WorkspaceSvg | undefined {
    return this.ws;
  }

  ngOnDestroy(): void {
    this.hostRef?.nativeElement?.removeEventListener('wheel', this.onWheel);
    this.resizeObs?.disconnect();
    if (this.ws) {
      this.ws.removeChangeListener(this.changeListener);
      this.ws.dispose();
      this.ws = undefined;
    }
  }
}
