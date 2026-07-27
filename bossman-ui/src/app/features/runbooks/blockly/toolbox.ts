import * as Blockly from 'blockly';

/** The Blockly toolbox for the runbook designer. Block A: one "Steps" category
 * with the generic step block. Block B adds a search category (@blockly/
 * toolbox-search) and one entry per catalog module. Horizontal layout (set in
 * the workspace component) renders these categories as a top navbar. */
export function buildRunbookToolbox(): Blockly.utils.toolbox.ToolboxDefinition {
  return {
    kind: 'categoryToolbox',
    contents: [
      {
        kind: 'category',
        name: 'Steps',
        colour: '210',
        contents: [
          { kind: 'block', type: 'runbook_module' },
        ],
      },
    ],
  };
}
