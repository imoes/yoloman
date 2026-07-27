// awx-ng: tiny shared helper used by both playbookImporter.js and
// conditionParser.js — extracted to avoid a circular import between them.
export function newBlock(workspace, type) {
  const block = workspace.newBlock(type);
  // initSvg/render only exist on rendered (browser) workspaces — guard so
  // this also works against a headless Blockly.Workspace() in jest tests.
  if (typeof block.initSvg === 'function') {
    block.initSvg();
    block.render();
  }
  return block;
}
