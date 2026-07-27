import * as Blockly from 'blockly';
import { FieldMultilineInput } from '@blockly/field-multilineinput';

/**
 * Runbook block definitions (ported from ansible-manager's playbookBuilder/
 * blocks.js, adapted to Bossman runbooks). Blocks are defined the imperative way
 * — `Blockly.Blocks[type] = { init }` — same as the reference.
 *
 * A runbook is a LINEAR list of steps (no play/role wrapper), so every step
 * block chains top-to-bottom via `previous/nextStatement(STEP_CHECK)`.
 *
 * Block A ships ONE generic step block that fully represents a DocStep
 * (name, module, args-as-JSON, when/loop/register/ignore_errors) so the visual
 * mode round-trips every runbook. Block B replaces the module+args fields with
 * one catalog-driven `module_<name>` block per module (per-arg fields), keeping
 * the same chain contract so the generator/importer don't change.
 */
export const STEP_CHECK = 'Step';
const HUE_STEP = 210;   // blue

let registered = false;

export function registerRunbookBlocks(): void {
  if (registered) return;   // Blockly.Blocks is a global registry — define once
  registered = true;

  Blockly.Blocks['runbook_module'] = {
    init(this: Blockly.Block) {
      this.appendDummyInput().appendField('step');
      this.appendDummyInput()
        .appendField('name')
        .appendField(new Blockly.FieldTextInput(''), 'NAME');
      this.appendDummyInput()
        .appendField('module')
        .appendField(new Blockly.FieldTextInput(''), 'MODULE');
      this.appendDummyInput()
        .appendField('args (JSON)')
        .appendField(new FieldMultilineInput('{}'), 'ARGS');
      this.appendDummyInput()
        .appendField('when')
        .appendField(new Blockly.FieldTextInput(''), 'WHEN');
      this.appendDummyInput()
        .appendField('loop')
        .appendField(new Blockly.FieldTextInput(''), 'LOOP');
      this.appendDummyInput()
        .appendField('register')
        .appendField(new Blockly.FieldTextInput(''), 'REGISTER');
      this.appendDummyInput()
        .appendField('ignore errors')
        .appendField(new Blockly.FieldCheckbox('FALSE'), 'IGNORE');
      this.setPreviousStatement(true, STEP_CHECK);
      this.setNextStatement(true, STEP_CHECK);
      this.setColour(HUE_STEP);
      this.setTooltip('One runbook step: a module invocation with its args and flow controls.');
    },
  };
}
