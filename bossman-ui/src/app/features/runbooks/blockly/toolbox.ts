import * as Blockly from 'blockly';

/** The Blockly toolbox for the runbook designer. A "Common" category of the
 * everyday modules as click-to-place blocks (MODULE preset via the block's
 * `fields`), plus a blank "Step" for anything else — the module name is a plain
 * field, so the long tail is typed rather than listed. Horizontal layout (set in
 * the workspace component) renders these as a top navbar.
 *
 * NOTE: we deliberately do NOT feed the whole ~2000-module catalog into a
 * @blockly/toolbox-search category — its indexer instantiates every entry, which
 * (with MODULE preset) would fire one argspec fetch per module. The Common set
 * covers the 90% case; the field types the rest. */
const COMMON_MODULES: { ref: string; label: string }[] = [
  { ref: 'shell', label: 'shell' },
  { ref: 'command', label: 'command' },
  { ref: 'apt', label: 'apt' },
  { ref: 'dnf', label: 'dnf' },
  { ref: 'package', label: 'package' },
  { ref: 'service', label: 'service' },
  { ref: 'systemd', label: 'systemd' },
  { ref: 'file', label: 'file' },
  { ref: 'copy', label: 'copy' },
  { ref: 'template', label: 'template' },
  { ref: 'lineinfile', label: 'lineinfile' },
  { ref: 'user', label: 'user' },
  { ref: 'group', label: 'group' },
  { ref: 'git', label: 'git' },
  { ref: 'pip', label: 'pip' },
  { ref: 'debug', label: 'debug' },
  { ref: 'set_fact', label: 'set_fact' },
];

export function buildRunbookToolbox(): Blockly.utils.toolbox.ToolboxDefinition {
  const moduleBlock = (ref: string) => ({ kind: 'block', type: 'runbook_module', fields: { MODULE: ref } });
  return {
    kind: 'categoryToolbox',
    contents: [
      {
        kind: 'category',
        name: 'Common',
        colour: '210',
        contents: COMMON_MODULES.map((m) => moduleBlock(m.ref)),
      },
      {
        kind: 'category',
        name: 'Step',
        colour: '210',
        contents: [{ kind: 'block', type: 'runbook_module' }],
      },
      {
        // Blocks for a step's `when:` — drag into a step's WHEN socket, or into
        // each other (compare/and/or/not/test compose a Jinja boolean).
        kind: 'category',
        name: 'Conditions',
        colour: '210',
        contents: [
          { kind: 'block', type: 'cond_compare' },
          { kind: 'block', type: 'cond_var' },
          { kind: 'block', type: 'cond_literal' },
          { kind: 'block', type: 'cond_test' },
          { kind: 'block', type: 'cond_not' },
          { kind: 'block', type: 'cond_logic' },
        ],
      },
    ],
  };
}
