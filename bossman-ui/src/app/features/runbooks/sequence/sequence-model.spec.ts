import {
  SEARCH_SCOPES, STEP_TYPE_META, SeqNode, filterTree, findNode, flatten, isDescendant, moveNode,
  searchTree, stepTypeOf, tasksToTree, treeToTasks,
} from './sequence-model';

/**
 * The Sequence tree is a VIEW over the Ansible-task document, so the round-trip is what must never lose
 * work — that is what these tests pin down (docs/ui-workspaces.md slice 3). They are pure-function tests
 * on purpose: no browser, no fixtures, so a regression in tasksToTree/treeToTasks fails loudly and fast.
 */
describe('sequence-model (tree ⇄ Ansible tasks)', () => {
  const expectEq = (label: string, got: unknown, want: unknown) =>
    expect(JSON.stringify(got)).withContext(label).toEqual(JSON.stringify(want));
  const expectOk = (label: string, cond: boolean) => expect(cond).withContext(label).toBeTrue();

  it('round-trips a grouped sequence without losing anything', () => {

  
  // The operator's example sequence, as an Ansible task list.
  const tasks = [
    { name: 'Prepare', when: 'has_partitions', block: [
        { name: 'partition', 'yoloman.disk_partition': { disk: '/dev/sda', dump_file: '/tmp/target.sfdisk' } },
        { name: 'vg', 'community.general.lvg': { vg: 'rootvg', pvs: '/dev/sda1' }, loop: '{{ volume_groups }}' },
    ]},
    { name: 'Install', block: [
        { name: 'nginx', 'yoloman.role': { name: 'install-nginx' } },
    ], rescue: [ { name: 'cleanup', command: 'rm -rf /tmp/x' } ] },
    { name: 'Verify', block: [ { name: 'http', 'yoloman.check': { check: 'http_response' }, register: 'r' } ] },
  ];
  
  const tree = tasksToTree(tasks);
  expectEq('round-trip is lossless', treeToTasks(tree), tasks);
  expectEq('three top-level groups', tree.map(n => `${n.kind}:${n.name}`), ['group:Prepare', 'group:Install', 'group:Verify']);
  expectEq('group keeps its when', tree[0].when, 'has_partitions');
  expectEq('step keeps module + args', tree[0].children![0].module, 'yoloman.disk_partition');
  expectEq('step keeps loop', tree[0].children![1].loop, '{{ volume_groups }}');
  expectEq('rescue survives', tree[1].rescue!.map(n => n.name), ['cleanup']);
  expectEq('free-form scalar module survives', treeToTasks(tasksToTree([{ name: 'x', shell: 'echo hi' }])), [{ name: 'x', shell: 'echo hi' }]);
  const kw = [{ name: 'y', become: true, tags: ['a'], command: 'ls' }];
  expectEq('unmodelled keywords survive, in their original order', treeToTasks(tasksToTree(kw)), kw);
  
  // flatten: rendering order + depth
  expectEq('flatten depths', flatten(tree).map(r => `${r.depth}:${r.node.name}`),
     ['0:Prepare', '1:partition', '1:vg', '0:Install', '1:nginx', '0:Verify', '1:http']);
  
  // drag & drop moves
  const t2 = tasksToTree(tasks);
  const stepId = t2[0].children![0].id;                 // 'partition' in Prepare
  expectOk('move a step into another group', moveNode(t2, stepId, t2[1].id, 0));
  expectEq('step left its old group', t2[0].children!.map(n => n.name), ['vg']);
  expectEq('step arrived in the new group', t2[1].children!.map(n => n.name), ['partition', 'nginx']);
  
  const t3 = tasksToTree(tasks);
  expectOk('a group cannot be dropped into itself', !moveNode(t3, t3[0].id, t3[0].id, 0));
  const inner = t3[0].children![0].id;
  expectOk('a group cannot be dropped into its own subtree', !moveNode(t3, t3[0].id, inner, 0));
  expectOk('isDescendant sees a child', isDescendant(t3[0], inner));
  expectOk('reorder at root works', moveNode(t3, t3[2].id, null, 0));
  expectEq('root order after reorder', t3.map(n => n.name), ['Verify', 'Prepare', 'Install']);
  expectOk('findNode finds a nested step', !!findNode(t3, inner));
  
  
  });

  it('cannot represent a step without a module — which is why the editor must always set one', () => {
    // A task with no module key is invalid Ansible: Bossman's parser rejects the whole document. So a
    // module-less node serialises to a bare {name}, and the editor creates every new step WITH a module
    // (see runbook-editor.newStep) rather than letting the document go unparseable while the operator types.
    expectEq('module-less step loses its module key', treeToTasks([
      { id: 'x', kind: 'step', name: 'draft', module: '', args: {} },
    ]), [{ name: 'draft' }]);
    expectEq('a step WITH a module keeps it', treeToTasks([
      { id: 'y', kind: 'step', name: 'ok', module: 'ping', args: {} },
    ]), [{ name: 'ok', ping: {} }]);
  });
});


/**
 * Step typing, scoped search and Filter By — all pure projections of the document, which is the point:
 * switching a view or a filter must never be able to change what runs.
 *
 * Karma/ChromeHeadless cannot run in the dev sandbox, so these were additionally verified by bundling the
 * model with esbuild and asserting the same cases under node. Keep them framework-free so that stays
 * possible.
 */
describe('sequence-model (step types)', () => {
  const step = (module?: string): SeqNode => ({ id: 'x', kind: 'step', name: '', module });

  it('types a step from the document, not from substrings of the module name', () => {
    expect(stepTypeOf({ id: 'g', kind: 'group', name: 'x' })).toBe('group');
    expect(stepTypeOf(step('apt'))).toBe('task');
    expect(stepTypeOf(step('community.general.lvg'))).toBe('task');
    expect(stepTypeOf(step('checkmk.mysql'))).toBe('check');
    expect(stepTypeOf(step('config'))).toBe('config');
    expect(stepTypeOf(step('import_tasks'))).toBe('role');
    expect(stepTypeOf(step('include_role'))).toBe('role');
    expect(stepTypeOf(step('runbook'))).toBe('role');       // the canonical doc's spelling
  });

  it('does not repeat the substring guessing it replaced', () => {
    // The old glyph() used module.includes('check') / includes('role'), which mis-typed all three of these.
    expect(stepTypeOf(step('check_plugin'))).toBe('task');
    expect(stepTypeOf(step('checkmk_local'))).toBe('task');   // no dot → not the checkmk collection
    expect(stepTypeOf(step('rolebinding'))).toBe('task');
  });

  it('survives a step with no module', () => {
    expect(stepTypeOf(step(''))).toBe('task');
    expect(stepTypeOf(step(undefined))).toBe('task');
  });

  it('types every step of a real task list, through the tree parser', () => {
    const tree = tasksToTree([
      { name: 'a task', apt: { name: 'nginx' } },
      { name: 'a role call', import_tasks: 'install-nginx' },
      { name: 'a check', 'checkmk.mysql': {} },
      { name: 'a config', config: { path: '/etc/x' } },
      { name: 'not a check', check_plugin: {} },
      { name: 'a group', block: [{ name: 'inner', ping: null }] },
    ]);
    expect(tree.map(stepTypeOf)).toEqual(['task', 'role', 'check', 'config', 'task', 'group']);
  });

  it('has an icon and a label for every type', () => {
    for (const t of ['group', 'role', 'check', 'config', 'task'] as const) {
      expect(STEP_TYPE_META[t].glyph).toBeTruthy();
      expect(STEP_TYPE_META[t].label).toBeTruthy();
    }
  });
});

describe('sequence-model (search + filter)', () => {
  const TREE: SeqNode[] = [
    {
      id: 'g1', kind: 'group', name: 'Prepare', when: 'has_partitions',
      children: [
        { id: 's1', kind: 'step', name: 'Partition', module: 'yoloman.disk_partition',
          args: { device: '{{ target_disk }}' }, register: 'part_result' },
        { id: 's2', kind: 'step', name: 'Create VG', module: 'community.general.lvg',
          args: { vg: 'data' }, extra: { ignore_errors: true } },
      ],
      rescue: [{ id: 'r1', kind: 'step', name: 'Recover', module: 'shell',
                 args: { cmd: 'echo {{ part_result.rc }}' }, when: 'part_result.failed' }],
      always: [{ id: 'a1', kind: 'step', name: 'Cleanup', module: 'file',
                 args: { path: '/tmp/x' }, extra: { ignore_errors: true } }],
    },
    { id: 's3', kind: 'step', name: 'Install nginx', module: 'apt', args: { name: 'nginx' } },
  ];

  it('scopes to step name, group name and step type separately', () => {
    expect([...searchTree(TREE, 'nginx', ['stepName'])]).toEqual(['s3']);
    expect(searchTree(TREE, 'Install', ['groupName']).size).toBe(0);
    expect([...searchTree(TREE, 'prepare', ['groupName'])]).toEqual(['g1']);
    expect([...searchTree(TREE, 'lvg', ['stepType'])]).toEqual(['s2']);
  });

  it('finds a variable where it is DEFINED and where it is USED', () => {
    const hits = searchTree(TREE, 'part_result', ['variableName']);
    expect(hits.has('s1')).toBe(true);      // register: part_result
    expect(hits.has('r1')).toBe(true);      // {{ part_result.rc }} inside args
    expect(searchTree(TREE, 'target_disk', ['variableName']).has('s1')).toBe(true);
  });

  it('searches conditions and arg values', () => {
    expect([...searchTree(TREE, 'has_partitions', ['conditions'])]).toEqual(['g1']);
    expect(searchTree(TREE, 'data', ['contents']).has('s2')).toBe(true);
  });

  it('matches nothing for an empty query or no scope', () => {
    // Highlighting the whole tree when the box is empty would tell the operator nothing.
    expect(searchTree(TREE, '   ', ['stepName']).size).toBe(0);
    expect(searchTree(TREE, 'nginx', []).size).toBe(0);
  });

  it('is case-insensitive, and every offered scope is implemented', () => {
    expect(searchTree(TREE, 'NGINX', ['stepName']).has('s3')).toBe(true);
    for (const s of SEARCH_SCOPES) expect(searchTree(TREE, 'x', [s.key]) instanceof Set).toBe(true);
  });

  it('does not filter at all when no filter is set', () => {
    expect(filterTree(TREE, {})).toBeNull();
  });

  it('keeps a matching step AND its ancestor group', () => {
    const v = filterTree(TREE, { continueOnError: true })!;
    expect(v.has('s2')).toBe(true);
    expect(v.has('g1')).toBe(true);        // dropping it would misrepresent the order s2 runs in
    expect(v.has('s1')).toBe(false);
    expect(v.has('s3')).toBe(false);
  });

  it('collects matches in rescue/always even when children also matched', () => {
    // Regression: the walk used `walk(children) || walk(rescue) || walk(always)`, which short-circuits, so
    // `a1` was never added once `s2` had matched.
    expect(filterTree(TREE, { continueOnError: true })!.has('a1')).toBe(true);
  });

  it('filters by having a condition', () => {
    const v = filterTree(TREE, { hasConditions: true })!;
    expect(v.has('g1')).toBe(true);
    expect(v.has('r1')).toBe(true);
    expect(v.has('s3')).toBe(false);
  });
});
