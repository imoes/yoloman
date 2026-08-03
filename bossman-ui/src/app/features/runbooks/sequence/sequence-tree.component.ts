import { Component, input, output } from '@angular/core';
import { CdkDrag, CdkDropList, CdkDropListGroup, CdkDragDrop, moveItemInArray, transferArrayItem } from '@angular/cdk/drag-drop';
import { MatIconModule } from '@angular/material/icon';
import { SeqNode, isDescendant } from './sequence-model';

/**
 * The Sequence tree — groups and steps, reorderable by drag & drop (docs/ui-workspaces.md slice 3).
 *
 * Recursive by design: a group renders another instance of this component for its children, and every
 * children-array is a CDK drop list. All of them sit inside one `cdkDropListGroup` in the parent editor,
 * which is what lets a step be dragged from one group into another without wiring list ids by hand.
 *
 * It edits the SeqNode arrays in place (they are the view model) and emits `changed` so the editor can
 * serialise back to the Ansible-task document — the tree never talks YAML itself.
 */
// Fold state for groups, shared across the recursive instances (see isCollapsed).
const COLLAPSED = new Set<string>();

@Component({
  selector: 'app-sequence-tree',
  standalone: true,
  imports: [CdkDrag, CdkDropList, MatIconModule],
  template: `
    <div class="bm-seq-list" cdkDropList [cdkDropListData]="nodes()" (cdkDropListDropped)="onDrop($event)">
      @for (n of nodes(); track n.id) {
        @if (shown(n)) {
        <div class="bm-seq-item" cdkDrag [cdkDragData]="n">
          <div class="bm-seq-row" [class.on]="selectedId() === n.id" [class.hit]="matchIds().has(n.id)"
               (click)="select.emit(n.id)">
            <span class="bm-seq-grip" cdkDragHandle title="Drag to reorder or move into a group">
              <mat-icon>drag_indicator</mat-icon>
            </span>
            @if (n.kind === 'group') {
              <button type="button" class="bm-seq-caret" (click)="toggle(n.id); $event.stopPropagation()"
                      [title]="isCollapsed(n.id) ? 'Expand group' : 'Collapse group'">
                <mat-icon>{{ isCollapsed(n.id) ? 'chevron_right' : 'expand_more' }}</mat-icon>
              </button>
            }
            <span class="bm-seq-glyph">{{ n.kind === 'group' ? '📁' : glyph(n.module) }}</span>
            <span class="bm-seq-name">{{ n.name || (n.kind === 'group' ? '(group)' : n.module || '(step)') }}</span>
            @if (n.kind === 'step' && n.module) { <code class="bm-seq-mod">{{ n.module }}</code> }
            @if (n.kind === 'group' && isCollapsed(n.id)) {
              <span class="bm-seq-when">{{ countOf(n) }} step(s) hidden</span>
            }
            @if (n.when) { <span class="bm-seq-when">when: {{ n.when }}</span> }
            @if (n.loop !== undefined) { <span class="bm-seq-when">loop</span> }
            <button type="button" class="bm-seq-del" (click)="remove.emit(n.id); $event.stopPropagation()"
                    title="Remove">×</button>
          </div>
          @if (n.kind === 'group' && !isCollapsed(n.id)) {
            <div class="bm-seq-children">
              <app-sequence-tree [nodes]="childrenOf(n)" [selectedId]="selectedId()"
                                 [matchIds]="matchIds()" [visibleIds]="visibleIds()"
                                 (select)="select.emit($event)" (remove)="remove.emit($event)"
                                 (changed)="changed.emit()" />
              @if (!childrenOf(n).length) {
                <p class="bm-seq-empty">empty group — drag a step in here</p>
              }
              <!-- The error-handling branches. Each is its own drop list inside the shared
                   cdkDropListGroup, so a step can be dragged straight into rescue or always. -->
              @if (n.rescue?.length) {
                <div class="bm-seq-branch">
                  <span class="bm-seq-btag bm-seq-rescue">⟲ rescue</span>
                  <span class="bm-seq-bhint">runs only if the group failed</span>
                </div>
                <app-sequence-tree [nodes]="rescueOf(n)" [selectedId]="selectedId()"
                                   [matchIds]="matchIds()" [visibleIds]="visibleIds()"
                                   (select)="select.emit($event)" (remove)="remove.emit($event)"
                                   (changed)="changed.emit()" />
              }
              @if (n.always?.length) {
                <div class="bm-seq-branch">
                  <span class="bm-seq-btag bm-seq-always">⤓ always</span>
                  <span class="bm-seq-bhint">runs either way</span>
                </div>
                <app-sequence-tree [nodes]="alwaysOf(n)" [selectedId]="selectedId()"
                                   [matchIds]="matchIds()" [visibleIds]="visibleIds()"
                                   (select)="select.emit($event)" (remove)="remove.emit($event)"
                                   (changed)="changed.emit()" />
              }
            </div>
          }
        </div>
        }
      }
    </div>
  `,
  styles: [`
    .bm-seq-list { min-height: 12px; }
    .bm-seq-item { }
    .bm-seq-row { display: flex; align-items: center; gap: 7px; padding: 4px 6px; border-radius: 6px;
      cursor: pointer; border: 1px solid transparent; }
    .bm-seq-row:hover { background: color-mix(in srgb, var(--mat-sys-on-surface) 5%, transparent); }
    .bm-seq-row.on { background: color-mix(in srgb, var(--mat-sys-primary) 12%, transparent);
      border-color: color-mix(in srgb, var(--mat-sys-primary) 30%, transparent); }
    /* A search hit. SCCM paints the row yellow; the design philosophy reserves colour fills for status, so
       this is a gold left accent + a faint tint instead of a block of colour behind the text. */
    .bm-seq-row.hit { box-shadow: inset 3px 0 0 var(--bm-gold, #b8860b);
      background: color-mix(in srgb, var(--bm-gold, #b8860b) 10%, transparent); }
    .bm-seq-grip { display: inline-flex; opacity: .35; cursor: grab; }
    .bm-seq-grip mat-icon { font-size: 17px; width: 17px; height: 17px; }
    .bm-seq-glyph { font-size: 13px; }
    .bm-seq-name { font-size: 13px; }
    .bm-seq-mod { font-size: 11px; opacity: .6; font-family: ui-monospace, monospace; }
    .bm-seq-when { font-size: 10.5px; opacity: .6; padding: 0 6px; border-radius: 999px;
      background: color-mix(in srgb, var(--mat-sys-on-surface) 10%, transparent); }
    .bm-seq-del { margin-left: auto; background: none; border: 0; color: inherit; opacity: .4;
      cursor: pointer; font-size: 15px; line-height: 1; padding: 0 4px; }
    .bm-seq-del:hover { opacity: 1; color: var(--mat-sys-error, #c62828); }
    .bm-seq-children { margin-left: 22px; border-left: 1px dashed var(--mat-sys-outline-variant);
      padding-left: 8px; }
    .bm-seq-empty { font-size: 11.5px; opacity: .45; margin: 2px 0 2px 4px; }
    .bm-seq-caret { background: none; border: 0; color: inherit; opacity: .5; cursor: pointer;
      display: inline-flex; padding: 0; margin-right: -3px; }
    .bm-seq-caret:hover { opacity: 1; }
    .bm-seq-caret mat-icon { font-size: 18px; width: 18px; height: 18px; }
    .bm-seq-branch { display: flex; align-items: center; gap: 7px; margin: 5px 0 1px; }
    .bm-seq-btag { font-size: 10.5px; font-family: ui-monospace, monospace; padding: 1px 7px;
      border-radius: 999px; }
    .bm-seq-rescue { background: color-mix(in srgb, var(--bm-gold, #b8860b) 22%, transparent); }
    .bm-seq-always { background: color-mix(in srgb, var(--mat-sys-on-surface) 11%, transparent); }
    .bm-seq-bhint { font-size: 10.5px; opacity: .45; }
    .cdk-drag-preview .bm-seq-row { background: var(--mat-sys-surface); box-shadow: 0 3px 10px rgba(0,0,0,.25); }
    .cdk-drop-list-dragging .bm-seq-row { transition: transform .16s ease; }
  `],
})
export class SequenceTreeComponent {
  nodes = input.required<SeqNode[]>();
  selectedId = input<string | null>(null);
  /** Search hits, highlighted in place (SCCM highlights rather than hides, which keeps the order readable). */
  matchIds = input<Set<string>>(new Set<string>());
  /** Ids to show when a "Filter By" is active; null means no filtering. */
  visibleIds = input<Set<string> | null>(null);

  /** A filtered-out node is not rendered; without an active filter everything shows. */
  shown(n: SeqNode): boolean {
    const v = this.visibleIds();
    return !v || v.has(n.id);
  }

  select = output<string>();
  remove = output<string>();
  /** Emitted whenever the tree structure changed, so the editor re-serialises. */
  changed = output<void>();

  /**
   * Which groups are folded. A module-level set shared by every instance of this recursive component, keyed
   * by node id: the tree renders itself recursively, so per-instance state would forget a nested group's
   * fold the moment its parent re-rendered. Ids are view state, so nothing here reaches the document.
   */
  isCollapsed(id: string): boolean {
    return COLLAPSED.has(id);
  }
  toggle(id: string): void {
    if (COLLAPSED.has(id)) COLLAPSED.delete(id); else COLLAPSED.add(id);
  }
  /** How much a folded group hides, so the row still tells you the size. */
  countOf(n: SeqNode): number {
    const walk = (list?: SeqNode[]): number =>
      (list ?? []).reduce((sum, c) => sum + 1 + walk(c.children) + walk(c.rescue) + walk(c.always), 0);
    return walk(n.children) + walk(n.rescue) + walk(n.always);
  }

  childrenOf(n: SeqNode): SeqNode[] {
    return (n.children ??= []);
  }
  rescueOf(n: SeqNode): SeqNode[] {
    return (n.rescue ??= []);
  }
  alwaysOf(n: SeqNode): SeqNode[] {
    return (n.always ??= []);
  }

  /** A rough glyph per module family, purely to make the tree scannable. */
  glyph(module?: string): string {
    if (!module) return '⚙';
    if (module.includes('check')) return '✅';
    if (module.includes('role')) return '🎭';
    return '⚙';
  }

  /**
   * CDK drop. Within one list it is a reorder; across lists it is a move. The one illegal case is dragging
   * a group into its own subtree — CDK cannot know that, and allowing it would detach the tree from the
   * document, so refuse it here.
   */
  onDrop(ev: CdkDropList extends never ? never : CdkDragDrop<SeqNode[]>): void {
    const from = ev.previousContainer.data as SeqNode[];
    const to = ev.container.data as SeqNode[];
    const moving = from[ev.previousIndex];
    if (!moving) return;
    if (ev.previousContainer === ev.container) {
      moveItemInArray(to, ev.previousIndex, ev.currentIndex);
    } else {
      // Would the target list live inside the node being moved?
      if (moving.kind === 'group' && to.some((n) => n.id === moving.id) === false && containsList(moving, to)) return;
      transferArrayItem(from, to, ev.previousIndex, ev.currentIndex);
    }
    this.changed.emit();
  }
}

/** True when `list` is one of the arrays inside `node`'s subtree (identity, not value). */
function containsList(node: SeqNode, list: SeqNode[]): boolean {
  for (const branch of [node.children, node.rescue, node.always]) {
    if (!branch) continue;
    if (branch === list) return true;
    for (const c of branch) {
      if (containsList(c, list)) return true;
    }
  }
  return false;
}

export { isDescendant };
