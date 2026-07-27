import * as Blockly from 'blockly';
import { DocStep } from './generator';

/** Build the Blockly workspace from a runbook's steps (the inverse of
 * workspaceToSteps) — the text→visual direction. Creates one `runbook_module`
 * block per step and chains them via previous/next connections, mirroring the
 * reference importer's `newBlock` + connect approach. */
export function stepsToWorkspace(ws: Blockly.WorkspaceSvg, steps: DocStep[]): void {
  ws.clear();
  let prev: Blockly.BlockSvg | null = null;
  for (const st of steps) {
    const b = ws.newBlock('runbook_module') as Blockly.BlockSvg;
    b.initSvg();
    b.setFieldValue(st.name ?? '', 'NAME');
    b.setFieldValue(st.module ?? '', 'MODULE');
    const args = st.args && Object.keys(st.args).length ? JSON.stringify(st.args) : '{}';
    b.setFieldValue(args, 'ARGS');
    b.setFieldValue(st.when ?? '', 'WHEN');
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
