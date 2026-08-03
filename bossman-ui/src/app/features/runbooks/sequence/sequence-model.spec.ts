import {
  tasksToTree, treeToTasks, moveNode, flatten, isDescendant, findNode,
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
});
