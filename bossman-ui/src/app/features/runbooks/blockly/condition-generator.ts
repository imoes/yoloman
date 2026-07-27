import * as Blockly from 'blockly';

/** A literal field value → its Jinja form. An explicitly-quoted value ("6",
 * 'Debian') stays a string even if numeric-looking (several ansible_facts like
 * distribution_major_version are strings); otherwise plain numbers/true/false
 * are unquoted and anything else is auto-quoted. Ported from the reference. */
function literalToExpr(raw: string): string | null {
  if (raw === '') return null;
  const quoted = /^(['"])([\s\S]*)\1$/.exec(raw);
  if (quoted) return `'${quoted[2].replace(/'/g, "\\'")}'`;
  if (/^-?\d+(\.\d+)?$/.test(raw) || raw === 'true' || raw === 'false') return raw;
  return `'${String(raw).replace(/'/g, "\\'")}'`;
}

/** Walk a condition-block tree into the Jinja expression Ansible expects for
 * `when:`. null for an empty/disconnected slot or a missing required child.
 * Ported from ansibleGenerator.conditionBlockToExpr. */
export function conditionBlockToExpr(block: Blockly.Block | null): string | null {
  if (!block) return null;
  switch (block.type) {
    case 'cond_var': {
      const name = (block.getFieldValue('NAME') || '').trim();
      return name || null;
    }
    case 'cond_literal':
      return literalToExpr(block.getFieldValue('VALUE') || '');
    case 'cond_compare': {
      const left = conditionBlockToExpr(block.getInputTargetBlock('LEFT'));
      const right = conditionBlockToExpr(block.getInputTargetBlock('RIGHT'));
      if (!left || !right) return null;
      return `${left} ${block.getFieldValue('OP')} ${right}`;
    }
    case 'cond_test': {
      const subject = conditionBlockToExpr(block.getInputTargetBlock('SUBJECT'));
      if (!subject) return null;
      const negate = block.getFieldValue('NEGATE') === 'TRUE';
      return `${subject} is ${negate ? 'not ' : ''}${block.getFieldValue('TEST')}`;
    }
    case 'cond_not': {
      const innerBlock = block.getInputTargetBlock('A');
      const inner = conditionBlockToExpr(innerBlock);
      if (!inner) return null;
      // "not" binds tighter than and/or — only parenthesize an and/or child.
      return innerBlock && innerBlock.type === 'cond_logic' ? `not (${inner})` : `not ${inner}`;
    }
    case 'cond_logic': {
      const a = conditionBlockToExpr(block.getInputTargetBlock('A'));
      const b = conditionBlockToExpr(block.getInputTargetBlock('B'));
      if (!a || !b) return null;
      return `(${a} ${block.getFieldValue('OP')} ${b})`;
    }
    case 'cond_raw':
      return block.getFieldValue('EXPR') || null;
    default:
      return null;
  }
}
