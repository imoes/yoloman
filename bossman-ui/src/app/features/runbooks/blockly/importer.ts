import * as Blockly from 'blockly';
import { DocStep } from './generator';
import { parseConditionToBlock } from './condition-parser';

interface ImportableBlock extends Blockly.BlockSvg {
  importArgs_(module: string, args: Record<string, unknown>): void;
}

/** Build the Blockly workspace from a runbook's steps (the inverse of
 * workspaceToSteps) — the text→visual direction. One `runbook_module` block per
 * step, chained via previous/next; the module's typed arg fields are built by
 * the block's own importArgs_ (which also subscribes for a late-arriving
 * argspec so fields upgrade to dropdowns/checkboxes once it loads). */
export function stepsToWorkspace(ws: Blockly.WorkspaceSvg, steps: DocStep[]): void {
  ws.clear();
  let prev: Blockly.BlockSvg | null = null;
  for (const st of steps) {
    const b = ws.newBlock('runbook_module') as ImportableBlock;
    b.initSvg();
    b.setFieldValue(st.name ?? '', 'NAME');
    b.importArgs_(st.module ?? '', (st.args as Record<string, unknown>) ?? {});
    if (st.when) {
      const cond = parseConditionToBlock(ws, String(st.when)) as Blockly.BlockSvg;
      b.getInput('WHEN')!.connection!.connect(cond.outputConnection!);
    }
    b.setFieldValue(loopToStr(st.loop), 'LOOP');
    b.setFieldValue(st.register ?? '', 'REGISTER');
    b.setFieldValue(st.ignore_errors ? 'TRUE' : 'FALSE', 'IGNORE');
    if (prev) {
      prev.nextConnection!.connect(b.previousConnection!);
    } else {
      b.moveBy(24, 24);
    }
    prev = b;
  }
  ws.render();
}

function loopToStr(loop: unknown): string {
  if (loop === undefined || loop === null || loop === '') return '';
  return typeof loop === 'string' ? loop : JSON.stringify(loop);
}
