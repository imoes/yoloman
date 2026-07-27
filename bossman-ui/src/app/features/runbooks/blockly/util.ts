import * as Blockly from 'blockly';

/** Create a block and render it if the workspace is a rendered (browser) one.
 * Ported from the reference designer's blocklyUtil.newBlock — guarded so the
 * same code works against a headless Blockly.Workspace() in unit tests. */
export function newBlock(workspace: Blockly.Workspace, type: string): Blockly.Block {
  const block = workspace.newBlock(type);
  const svg = block as Blockly.BlockSvg;
  if (typeof svg.initSvg === 'function') {
    svg.initSvg();
    svg.render();
  }
  return block;
}
