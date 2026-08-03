/**
 * The Sequence tree model — a VIEW over the same Ansible-task document the text and Blockly views edit
 * (docs/ui-workspaces.md slice 3, docs/resource-protocol.md "one canvas, several views").
 *
 * A node is a Resource-ish step; an edge is order. Concretely:
 *   group → an Ansible task carrying `block:` (plus optional `rescue:` / `always:`)
 *   step  → an Ansible task whose module key is "the key that isn't a keyword" (Ansible's own rule)
 *
 * These are PURE functions on purpose: the round-trip is the thing that must not lose work, so it is
 * testable without a browser. Anything we do not model explicitly is preserved in `extra`, which is what
 * makes tree → text → tree lossless for documents authored elsewhere.
 */

/** Task-level keywords — everything else on a task is the module key. Mirrors the backend's
 *  services/ansible_playbook._TASK_KEYWORDS so the two parsers agree on what a module is. */
export const TASK_KEYWORDS = new Set([
  'name', 'when', 'loop', 'with_items', 'register', 'ignore_errors',
  'become', 'tags', 'notify', 'vars', 'args',
  'block', 'rescue', 'always',
  'changed_when', 'failed_when', 'delegate_to', 'delegate_facts', 'run_once',
  'no_log', 'check_mode', 'environment', 'retries', 'until', 'delay',
  'throttle', 'listen', 'become_user', 'become_method', 'any_errors_fatal',
]);

export type SeqKind = 'group' | 'step';

export interface SeqNode {
  /** Client-side identity, for drag & drop and selection only — never serialised. */
  id: string;
  kind: SeqKind;
  name: string;
  /** step: the module key (`yoloman.disk_partition`, `community.general.lvg`, `command`, …). */
  module?: string;
  /** step: the module's arguments (its `schema()` values). */
  args?: Record<string, unknown>;
  when?: string;
  loop?: unknown;
  register?: string;
  /** group: the `block:` children. */
  children?: SeqNode[];
  /** group: `rescue:` / `always:` children, kept so error handling survives the round-trip. */
  rescue?: SeqNode[];
  always?: SeqNode[];
  /** Any task key we do not model — preserved verbatim so a round-trip loses nothing. */
  extra?: Record<string, unknown>;
  /**
   * The key order this task had when it was parsed. Emitting keys in that order is what makes
   * text → tree → text byte-identical for a document authored elsewhere (YAML key order is visible in a
   * diff, so reordering it would look like an edit the operator never made). View state; never serialised.
   */
  keyOrder?: string[];
}

let seq = 0;
/** Fresh node id. Ids are view state; two loads of the same document may number differently. */
export function nextId(): string { return `n${++seq}`; }

type Task = Record<string, unknown>;

/** The module key of a task: the single key that is not a task keyword. */
export function moduleKeyOf(task: Task): string | null {
  const keys = Object.keys(task).filter((k) => !TASK_KEYWORDS.has(k));
  return keys.length === 1 ? keys[0] : keys[0] ?? null;
}

function commonFields(task: Task): Pick<SeqNode, 'name' | 'when' | 'loop' | 'register' | 'extra' | 'keyOrder'> {
  const extra: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(task)) {
    // Modelled explicitly below, or handled by the caller (block/rescue/always, the module key).
    if (['name', 'when', 'loop', 'register', 'block', 'rescue', 'always'].includes(k)) continue;
    if (!TASK_KEYWORDS.has(k)) continue;   // the module key — not "extra"
    extra[k] = v;
  }
  return {
    name: typeof task['name'] === 'string' ? (task['name'] as string) : '',
    when: typeof task['when'] === 'string' ? (task['when'] as string) : undefined,
    loop: task['loop'] ?? task['with_items'] ?? undefined,
    register: typeof task['register'] === 'string' ? (task['register'] as string) : undefined,
    extra: Object.keys(extra).length ? extra : undefined,
    keyOrder: Object.keys(task),
  };
}

/** Ansible task list → tree. */
export function tasksToTree(tasks: unknown): SeqNode[] {
  if (!Array.isArray(tasks)) return [];
  return tasks.filter((t) => t && typeof t === 'object').map((raw) => {
    const task = raw as Task;
    const common = commonFields(task);
    if (Array.isArray(task['block'])) {
      return {
        id: nextId(), kind: 'group' as const, ...common,
        children: tasksToTree(task['block']),
        rescue: Array.isArray(task['rescue']) ? tasksToTree(task['rescue']) : undefined,
        always: Array.isArray(task['always']) ? tasksToTree(task['always']) : undefined,
      };
    }
    const mod = moduleKeyOf(task);
    const rawArgs = mod ? task[mod] : undefined;
    return {
      id: nextId(), kind: 'step' as const, ...common,
      module: mod ?? '',
      // A free-form module may carry a bare string (`shell: echo hi`); keep it under `_raw` so the form can
      // show it and the serialiser can put it back exactly as it was.
      args: rawArgs && typeof rawArgs === 'object' && !Array.isArray(rawArgs)
        ? (rawArgs as Record<string, unknown>)
        : rawArgs === undefined ? {} : { _raw: rawArgs },
    };
  });
}

/**
 * Tree → Ansible task list (the inverse of tasksToTree).
 *
 * Keys are emitted in the node's original `keyOrder` where one is known, so a document parsed and written
 * back is byte-identical; keys the operator added land after, in a conventional order.
 */
export function treeToTasks(nodes: SeqNode[]): Task[] {
  return nodes.map((n) => {
    const fields: Record<string, unknown> = {};
    if (n.name) fields['name'] = n.name;
    if (n.kind === 'group') {
      fields['block'] = treeToTasks(n.children ?? []);
      if (n.rescue?.length) fields['rescue'] = treeToTasks(n.rescue);
      if (n.always?.length) fields['always'] = treeToTasks(n.always);
    } else if (n.module) {
      const args = n.args ?? {};
      // Restore a free-form scalar exactly as it came in.
      fields[n.module] = '_raw' in args && Object.keys(args).length === 1 ? args['_raw'] : args;
    }
    if (n.when) fields['when'] = n.when;
    if (n.loop !== undefined) fields['loop'] = n.loop;
    if (n.register) fields['register'] = n.register;
    for (const [k, v] of Object.entries(n.extra ?? {})) fields[k] = v;

    // Original order first (only keys that still exist), then anything new.
    const task: Task = {};
    for (const k of n.keyOrder ?? []) {
      if (k in fields) task[k] = fields[k];
    }
    for (const [k, v] of Object.entries(fields)) {
      if (!(k in task)) task[k] = v;
    }
    return task;
  });
}

// ---- tree editing (pure; the component just calls these) ---------------------------------------

/** Depth-first walk, parent list included, so an edit can splice in place. */
function locate(nodes: SeqNode[], id: string): { list: SeqNode[]; index: number } | null {
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].id === id) return { list: nodes, index: i };
    for (const branch of [nodes[i].children, nodes[i].rescue, nodes[i].always]) {
      if (branch) {
        const hit = locate(branch, id);
        if (hit) return hit;
      }
    }
  }
  return null;
}

export function findNode(nodes: SeqNode[], id: string): SeqNode | null {
  const at = locate(nodes, id);
  return at ? at.list[at.index] : null;
}

/** Remove a node (and its subtree) and return it. */
export function removeNode(nodes: SeqNode[], id: string): SeqNode | null {
  const at = locate(nodes, id);
  if (!at) return null;
  return at.list.splice(at.index, 1)[0];
}

/** True when `id` is inside `node`'s subtree — the guard that stops a group being dropped into itself. */
export function isDescendant(node: SeqNode, id: string): boolean {
  for (const branch of [node.children, node.rescue, node.always]) {
    for (const c of branch ?? []) {
      if (c.id === id || isDescendant(c, id)) return true;
    }
  }
  return false;
}

/**
 * Move `id` into `targetGroupId`'s children (or the root when null) at `index`.
 * Refuses to move a group into itself or its own subtree, which would detach the tree.
 */
export function moveNode(root: SeqNode[], id: string, targetGroupId: string | null, index: number): boolean {
  const moving = findNode(root, id);
  if (!moving) return false;
  if (targetGroupId) {
    const target = findNode(root, targetGroupId);
    if (!target || target.kind !== 'group') return false;
    if (target.id === id || isDescendant(moving, targetGroupId)) return false;
  }
  removeNode(root, id);
  const list = targetGroupId ? (findNode(root, targetGroupId)!.children ??= []) : root;
  list.splice(Math.max(0, Math.min(index, list.length)), 0, moving);
  return true;
}

/** Flatten for rendering: every node with its depth and parent, in document order. */
export interface FlatRow { node: SeqNode; depth: number; parentId: string | null }
export function flatten(nodes: SeqNode[], depth = 0, parentId: string | null = null): FlatRow[] {
  const out: FlatRow[] = [];
  for (const n of nodes) {
    out.push({ node: n, depth, parentId });
    if (n.kind === 'group') out.push(...flatten(n.children ?? [], depth + 1, n.id));
  }
  return out;
}

// ---- Search + filter (SCCM's "Search Within" / "Filter By") -------------------------------------------
//
// SCCM's task-sequence editor scopes a search to Step Name, Step Type, Group Name, Variable Name,
// Conditions, Other Contents — and filters by "Continue On Error" / "Has Conditions". That vocabulary is a
// good fit because it is the same document: a step's type IS its module, a condition IS `when:`, a variable
// IS a `register:` name or a `{{ ... }}` reference, and Continue On Error IS `ignore_errors`.
//
// SCCM also offers Step Description and Group Description. We do NOT: a step in our model has no description
// field, so offering the scope would be offering something that can never match.
//
// Both are pure projections of the tree — no document is touched, so switching them can never change what
// runs.

/** Which parts of a node a search looks at. */
export type SearchScope = 'stepName' | 'stepType' | 'groupName' | 'variableName' | 'conditions' | 'contents';

export const SEARCH_SCOPES: { key: SearchScope; label: string }[] = [
  { key: 'stepName', label: 'Step name' },
  { key: 'stepType', label: 'Step type' },
  { key: 'groupName', label: 'Group name' },
  { key: 'variableName', label: 'Variable name' },
  { key: 'conditions', label: 'Conditions' },
  { key: 'contents', label: 'Other contents' },
];

/** Every `{{ name }}` / `{{ name.attr }}` reference in a value, however deeply nested. */
function varRefs(value: unknown, out: string[] = []): string[] {
  if (typeof value === 'string') {
    for (const m of value.matchAll(/\{\{\s*([A-Za-z_][\w.\[\]'"]*)/g)) out.push(m[1]);
  } else if (Array.isArray(value)) {
    for (const v of value) varRefs(v, out);
  } else if (value && typeof value === 'object') {
    for (const v of Object.values(value)) varRefs(v, out);
  }
  return out;
}

/** The searchable text of one node, per scope. */
function haystack(n: SeqNode, scope: SearchScope): string {
  switch (scope) {
    case 'stepName':
      return n.kind === 'step' ? n.name ?? '' : '';
    case 'groupName':
      return n.kind === 'group' ? n.name ?? '' : '';
    case 'stepType':
      return n.module ?? '';
    case 'variableName':
      // A register defines a variable; a `{{ ... }}` in args/when/loop uses one. Both are what an operator
      // means by "where is this variable used".
      return [n.register ?? '', ...varRefs(n.args), ...varRefs(n.when), ...varRefs(n.loop)].join(' ');
    case 'conditions':
      return [n.when ?? '', String(n.extra?.['failed_when'] ?? ''), String(n.extra?.['changed_when'] ?? '')]
        .join(' ');
    case 'contents':
      return JSON.stringify(n.args ?? {});
  }
}

/** Ids of every node matching `query` in any of `scopes`. An empty query matches nothing (not everything) —
 *  a search box that highlights the whole tree when empty tells the operator nothing. */
export function searchTree(nodes: SeqNode[], query: string, scopes: SearchScope[]): Set<string> {
  const hits = new Set<string>();
  const q = query.trim().toLowerCase();
  if (!q || !scopes.length) return hits;
  const walk = (list: SeqNode[]): void => {
    for (const n of list) {
      if (scopes.some((s) => haystack(n, s).toLowerCase().includes(q))) hits.add(n.id);
      walk(n.children ?? []);
      walk(n.rescue ?? []);
      walk(n.always ?? []);
    }
  };
  walk(nodes);
  return hits;
}

/** SCCM's "Filter By" checkboxes. */
export interface TreeFilters {
  /** Continue On Error — a step that records a failure and carries on (`ignore_errors`). */
  continueOnError?: boolean;
  /** Has Conditions — a `when:` (or failed_when/changed_when). */
  hasConditions?: boolean;
}

function passes(n: SeqNode, f: TreeFilters): boolean {
  if (f.continueOnError && !n.extra?.['ignore_errors']) return false;
  if (f.hasConditions && !(n.when || n.extra?.['failed_when'] || n.extra?.['changed_when'])) return false;
  return true;
}

/**
 * Ids of the nodes to SHOW under `filters`. A group is kept when it passes itself or when anything beneath it
 * does — dropping an ancestor would detach its matching children and misrepresent the order they run in,
 * which is the one thing a sequence view must not do. No active filter means everything is visible.
 */
export function filterTree(nodes: SeqNode[], filters: TreeFilters): Set<string> | null {
  if (!filters.continueOnError && !filters.hasConditions) return null;   // null = no filtering at all
  const visible = new Set<string>();
  const walk = (list: SeqNode[]): boolean => {
    let anyHere = false;
    for (const n of list) {
      // Each branch must be walked, so `||` would be wrong: it short-circuits, and a matching node in
      // `rescue`/`always` would then never be added to `visible` at all.
      const inChildren = walk(n.children ?? []);
      const inRescue = walk(n.rescue ?? []);
      const inAlways = walk(n.always ?? []);
      const below = inChildren || inRescue || inAlways;
      const self = passes(n, filters);
      if (self || below) {
        visible.add(n.id);
        anyHere = true;
      }
    }
    return anyHere;
  };
  walk(nodes);
  return visible;
}
