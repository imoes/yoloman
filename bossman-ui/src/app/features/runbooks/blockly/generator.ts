import * as Blockly from 'blockly';

/** The canonical runbook step shape (matches the backend /runbooks/lint doc and
 * the editor's DocStep). The Blockly workspace is walked into a list of these,
 * then the editor serializes them to NestedText — the same "walk to an object
 * tree, don't string-concatenate" approach as the reference ansibleGenerator. */
export interface DocStep {
  name?: string;
  module: string;
  args?: Record<string, unknown>;
  when?: string;
  loop?: unknown;
  register?: string;
  ignore_errors?: boolean;
}

function safeJson(s: string): Record<string, unknown> {
  try {
    const v = JSON.parse(s);
    return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** Walk the workspace's top-to-bottom block chains into an ordered step list.
 * A runbook is linear, but a user may leave a detached stack on the canvas —
 * we include every enabled step block, each top stack in board order. */
export function workspaceToSteps(ws: Blockly.Workspace): DocStep[] {
  const steps: DocStep[] = [];
  for (const top of ws.getTopBlocks(true)) {
    let b: Blockly.Block | null = top;
    while (b) {
      if (b.type === 'runbook_module' && b.isEnabled()) steps.push(blockToStep(b));
      b = b.getNextBlock();
    }
  }
  return steps;
}

function blockToStep(b: Blockly.Block): DocStep {
  const step: DocStep = { module: (b.getFieldValue('MODULE') || '').trim() };
  const name = (b.getFieldValue('NAME') || '').trim();
  if (name) step.name = name;
  const args = safeJson(b.getFieldValue('ARGS') || '');
  if (Object.keys(args).length) step.args = args;
  const when = (b.getFieldValue('WHEN') || '').trim();
  if (when) step.when = when;
  const loop = (b.getFieldValue('LOOP') || '').trim();
  if (loop) step.loop = loop;
  const register = (b.getFieldValue('REGISTER') || '').trim();
  if (register) step.register = register;
  if (b.getFieldValue('IGNORE') === 'TRUE') step.ignore_errors = true;
  return step;
}
