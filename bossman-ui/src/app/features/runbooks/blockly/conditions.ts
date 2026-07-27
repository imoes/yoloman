import * as Blockly from 'blockly';
import { FieldMultilineInput } from '@blockly/field-multilineinput';

/**
 * Condition ("when:") blocks — value-returning blocks that compose into a Jinja
 * boolean expression, so a step's `when:` is built visually (comparisons,
 * and/or/not, "is" tests) instead of hand-typed Jinja. Ported verbatim in shape
 * from the ansible-manager playbook designer (blocks.js defineConditionBlocks).
 *
 * cond_var / cond_literal have NO output check (null) so they plug directly into
 * a WHEN slot too — Ansible allows a bare truthy variable as `when: some_flag`.
 * The others output COND_CHECK. cond_raw is the lossless escape hatch for a
 * when: expression the parser couldn't decompose.
 */
export const COND_CHECK = 'Condition';

export const COND_TEST_NAMES: [string, string][] = [
  ['defined', 'defined'], ['undefined', 'undefined'], ['none', 'none'],
  ['true', 'true'], ['false', 'false'], ['changed', 'changed'],
  ['failed', 'failed'], ['success', 'success'], ['skipped', 'skipped'],
];

const HUE_VALUE = 65;    // var/literal (khaki)
const HUE_COMPARE = 210; // compare/test (blue)
const HUE_LOGIC = 230;   // not/and/or
const HUE_RAW = 0;       // raw (red)

let registered = false;

export function registerConditionBlocks(): void {
  if (registered) return;
  registered = true;

  Blockly.Blocks['cond_var'] = {
    init(this: Blockly.Block) {
      this.appendDummyInput().appendField('var').appendField(new Blockly.FieldTextInput('foo'), 'NAME');
      this.setOutput(true, null);   // null → plugs into a WHEN slot or a value input
      this.setColour(HUE_VALUE);
      this.setTooltip("A variable/fact reference, e.g. foo, result.changed, ansible_facts['distribution']. Emitted verbatim (no {{ }}).");
    },
  };

  Blockly.Blocks['cond_literal'] = {
    init(this: Blockly.Block) {
      this.appendDummyInput().appendField('value').appendField(new Blockly.FieldTextInput(''), 'VALUE');
      this.setOutput(true, null);
      this.setColour(HUE_VALUE);
      this.setTooltip("A literal — plain numbers/true/false are emitted unquoted, anything else is quoted (Debian → 'Debian').");
    },
  };

  Blockly.Blocks['cond_compare'] = {
    init(this: Blockly.Block) {
      this.appendValueInput('LEFT').appendField('compare');
      this.appendDummyInput().appendField(new Blockly.FieldDropdown([
        ['==', '=='], ['!=', '!='], ['>', '>'], ['<', '<'], ['>=', '>='], ['<=', '<='],
        ['in', 'in'], ['not in', 'not in'],
      ]), 'OP');
      this.appendValueInput('RIGHT');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(HUE_COMPARE);
      this.setTooltip("Compares two values, e.g. ansible_facts['distribution'] == 'Debian'.");
    },
  };

  Blockly.Blocks['cond_test'] = {
    init(this: Blockly.Block) {
      this.appendValueInput('SUBJECT').appendField('check');
      this.appendDummyInput()
        .appendField('is')
        .appendField(new Blockly.FieldCheckbox('FALSE'), 'NEGATE')
        .appendField('not')
        .appendField(new Blockly.FieldDropdown(COND_TEST_NAMES), 'TEST');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(HUE_COMPARE);
      this.setTooltip('A Jinja "is" test, e.g. foo is defined, result is failed (tick the box for "is not …").');
    },
  };

  Blockly.Blocks['cond_not'] = {
    init(this: Blockly.Block) {
      this.appendValueInput('A').setCheck(COND_CHECK).appendField('not');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(HUE_LOGIC);
      this.setTooltip('Negates a condition.');
    },
  };

  Blockly.Blocks['cond_logic'] = {
    init(this: Blockly.Block) {
      this.appendValueInput('A').setCheck(COND_CHECK);
      this.appendDummyInput().appendField(new Blockly.FieldDropdown([['and', 'and'], ['or', 'or']]), 'OP');
      this.appendValueInput('B').setCheck(COND_CHECK);
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(HUE_LOGIC);
      this.setTooltip('Combines two conditions with and/or — chain more blocks for more than two.');
    },
  };

  Blockly.Blocks['cond_raw'] = {
    init(this: Blockly.Block) {
      this.appendDummyInput().appendField('raw condition');
      this.appendDummyInput().appendField(new FieldMultilineInput(''), 'EXPR');
      this.setOutput(true, COND_CHECK);
      this.setColour(HUE_RAW);
      this.setTooltip('Fallback: a when: expression kept verbatim because it could not be decomposed into blocks.');
    },
  };
}
