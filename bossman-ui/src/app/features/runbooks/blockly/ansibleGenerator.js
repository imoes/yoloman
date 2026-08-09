// awx-ng: walks a Blockly workspace and serializes it to Ansible playbook
// YAML. Deliberately NOT using Blockly's built-in string-concatenating code
// generator (fragile for context-sensitive YAML indentation) — instead we
// build a plain JS object tree (`plays[]`) and hand it to the same
// jsonToYaml() the rest of AWX-ng already uses for extra_vars.
import * as Blockly from 'blockly';
import yaml from 'js-yaml';
// yolo-man: the reference imported AWX's util/yaml helper here; we render with
// js-yaml directly (same "object tree -> YAML" behaviour) so the file is otherwise 1:1.
const jsonToYaml = (jsonStr) => yaml.dump(JSON.parse(jsonStr), { lineWidth: -1, noRefs: true });
import { RESERVED_FIELD_NAMES, ENVELOPE_BY_KEY } from './blocks';

function fieldValue(block, fieldName) {
  const field = block.getField(fieldName);
  if (!field) return undefined;
  const raw = field.getValue();
  if (field instanceof Blockly.FieldCheckbox) {
    return raw === 'TRUE';
  }
  return raw;
}

// Parses a YAML-text field but returns a value only when it's a plain
// mapping. Guards against e.g. a bare string ("cmk_hostname") whose
// yaml.load() is a string — spreading/assigning that produces character-
// indexed junk keys ({0:'c',1:'m',...}). Returns null for anything that
// isn't a plain object.
function parseYamlMapping(text) {
  if (!text) return null;
  let parsed;
  try {
    parsed = yaml.load(text);
  } catch {
    return null;
  }
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
    return parsed;
  }
  return null;
}

// Converts a field's raw text into the shape its ansible-doc param type
// expects. Every module param field is a flat text/dropdown/checkbox
// control (see blocks.js), so list/dict-typed params (e.g. apt/yum/dnf's
// `name: [nginx, curl]`, a common multi-package install) need their text
// parsed into a real array/object rather than being emitted as one literal
// string — that mismatch used to force those tasks into the raw_task
// fallback entirely (see playbookImporter.js).
function coerceModuleArgValue(rawValue, paramType) {
  if (paramType === 'int' || paramType === 'float') {
    const n = Number(rawValue);
    return Number.isNaN(n) ? rawValue : n;
  }
  if (paramType === 'list') {
    // Accept either full YAML list syntax (multi-line "- item" or "[a, b]")
    // or a quick comma-separated shorthand, same convention as tags/notify.
    try {
      const parsed = yaml.load(rawValue);
      if (Array.isArray(parsed)) return parsed;
    } catch { /* fall through to comma-split */ }
    return String(rawValue).split(',').map((s) => s.trim()).filter(Boolean);
  }
  if (paramType === 'dict') {
    return parseYamlMapping(rawValue) || rawValue;
  }
  if (paramType === 'raw') {
    // 'raw' means "accepts anything" — use the parsed structure only when it
    // actually is one; otherwise keep the original string untouched (a bare
    // string parses back to itself anyway via yaml.load, so this is safe).
    try {
      const parsed = yaml.load(rawValue);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch { /* keep as string */ }
    return rawValue;
  }
  return rawValue; // str / path / bool(already coerced by fieldValue)
}

// Converts a literal string typed into a cond_literal block into its Jinja
// source form. An explicitly-quoted value ("6", 'Debian') always stays a
// string, even if its contents look numeric — this matters because several
// common ansible_facts (e.g. distribution_major_version) are STRINGS, so a
// faithfully-imported `== "6"` must not silently become the number 6.
// Otherwise: plain numbers/true/false are unquoted, anything else is
// auto-quoted as a string (the convenient default for typing e.g. Debian).
function literalToExpr(raw) {
  if (raw === '') return null;
  const quoted = /^(['"])([\s\S]*)\1$/.exec(raw);
  if (quoted) return `'${quoted[2].replace(/'/g, "\\'")}'`;
  if (/^-?\d+(\.\d+)?$/.test(raw) || raw === 'true' || raw === 'false') return raw;
  return `'${String(raw).replace(/'/g, "\\'")}'`;
}

// Walks a condition-block tree (cond_var/cond_literal/cond_compare/cond_test/
// cond_not/cond_logic/cond_raw — see blocks.js) into the Jinja expression
// string Ansible expects for `when:`. Returns null for an empty/disconnected
// slot (no when: is emitted) or when a required child is missing.
export function conditionBlockToExpr(block) {
  if (!block) return null;
  switch (block.type) {
    case 'cond_var': {
      const name = (block.getFieldValue('NAME') || '').trim();
      return name || null;
    }
    case 'cond_literal':
      return literalToExpr(block.getFieldValue('VALUE'));
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
      // "not" binds tighter than and/or in Jinja/Python — only parenthesize
      // when the child is itself an and/or combination (precedence would
      // otherwise flip); a plain "not foo.bar" needs no parens (matches the
      // common hand-written style, e.g. `not _containerd_dir.stat.exists`).
      return innerBlock.type === 'cond_logic' ? `not (${inner})` : `not ${inner}`;
    }
    case 'cond_logic': {
      const a = conditionBlockToExpr(block.getInputTargetBlock('A'));
      const b = conditionBlockToExpr(block.getInputTargetBlock('B'));
      if (!a || !b) return null;
      // Always parenthesized — safe/unambiguous regardless of how these
      // blocks are nested, at the minor cost of a few redundant parens.
      return `(${a} ${block.getFieldValue('OP')} ${b})`;
    }
    case 'cond_raw':
      return block.getFieldValue('EXPR') || null;
    default:
      return null;
  }
}

function blockToModuleArgs(moduleBlock) {
  const args = {};
  const paramTypes = moduleBlock.paramTypes_ || {};
  // dict-typed params can carry a connected `dict` block (input BLOCK_<name>)
  // — it wins over the param's text field (see blocks.js appendParamRow).
  moduleBlock.inputList.forEach((input) => {
    if (input.name && input.name.startsWith('BLOCK_') && input.connection) {
      const vb = input.connection.targetBlock();
      if (vb) args[input.name.slice('BLOCK_'.length)] = valueBlockToValue(vb);
    }
  });
  moduleBlock.inputList.forEach((input) => {
    input.fieldRow.forEach((field) => {
      // Skip the module header/add-dropdown and every task-envelope field
      // (name/when/tags/…) — only the module's OWN arguments belong here.
      if (!field.name || RESERVED_FIELD_NAMES.has(field.name)) return;
      // A connected dict block already provided this param's value.
      if (Object.prototype.hasOwnProperty.call(args, field.name)) return;
      const value = fieldValue(moduleBlock, field.name);
      // Blank text fields and unchecked checkboxes mean "the user didn't
      // set this" — there's no separate UI affordance (yet) to distinguish
      // "explicitly false" from "left at the field's blank default", so we
      // omit both to avoid bloating every generated task with untouched
      // params (see blocks.js: fields intentionally start blank/unchecked).
      if (value === '' || value === null || value === undefined || value === false) return;
      args[field.name] = coerceModuleArgValue(value, paramTypes[field.name]);
    });
  });
  return args;
}

// A module block IS a task (see blocks.js) — this walks its own name/module-
// args/envelope fields into one ordered task object. raw_task holds an
// entire unrecognized task verbatim.
// Walks the SETTINGS statement input's chain of task-setting blocks (when/tags/
// register/…) into `ordered` — shared by module blocks and block_task.
function applyTaskSettings(taskBlock, ordered) {
  let settingBlock = taskBlock.getInputTargetBlock('SETTINGS');
  while (settingBlock) {
    const envelope = ENVELOPE_BY_KEY[settingBlock.settingKey_];
    if (envelope) {
      if (envelope.kind === 'value') {
        const expr = conditionBlockToExpr(settingBlock.getInputTargetBlock('VALUE'));
        if (expr) ordered[envelope.yamlKey] = expr;
      } else {
        const value = fieldValue(settingBlock, 'VALUE');
        if (value !== '' && value !== null && value !== undefined && value !== false) {
          if (envelope.fieldKind === 'checkbox') {
            ordered[envelope.yamlKey] = true;
          } else if (envelope.key === 'TAGS' || envelope.key === 'NOTIFY') {
            ordered[envelope.yamlKey] = String(value).split(',').map((t) => t.trim()).filter(Boolean);
          } else if (envelope.key === 'LOOP') {
            // loop is assigned directly (not spread), so a bare scalar is
            // safe — no repeat of the EXTRA/VARS char-spread bug.
            ordered[envelope.yamlKey] = yaml.load(value);
          } else {
            ordered[envelope.yamlKey] = value;
          }
        }
      }
    }
    settingBlock = settingBlock.getNextBlock();
  }
}

function blockToTaskObject(taskBlock) {
  if (taskBlock.type === 'raw_task') {
    const raw = fieldValue(taskBlock, 'RAW_YAML') || '';
    return yaml.load(raw) || {};
  }

  // block / rescue / always — grouped error handling. Each section is a chain
  // of task blocks; rescue/always are omitted when empty.
  if (taskBlock.type === 'block_task') {
    const ordered = {};
    const name = fieldValue(taskBlock, 'NAME');
    if (name) ordered.name = name;
    ordered.block = taskChainToObjects(taskBlock.getInputTargetBlock('BLOCK'));
    const rescue = taskChainToObjects(taskBlock.getInputTargetBlock('RESCUE'));
    if (rescue.length) ordered.rescue = rescue;
    const always = taskChainToObjects(taskBlock.getInputTargetBlock('ALWAYS'));
    if (always.length) ordered.always = always;
    applyTaskSettings(taskBlock, ordered);
    return ordered;
  }

  const shortName = taskBlock.moduleShortName_
    || (taskBlock.ansibleModuleFqcn ? taskBlock.ansibleModuleFqcn.split('.').pop() : taskBlock.type.replace(/^module_/, ''));
  const name = fieldValue(taskBlock, 'NAME');

  const ordered = {};
  if (name) ordered.name = name;
  ordered[shortName] = blockToModuleArgs(taskBlock);
  applyTaskSettings(taskBlock, ordered);

  return ordered;
}

// Walks a chain of module_*/raw_task blocks (starting at `firstBlock`, e.g.
// from a statement input's getInputTargetBlock()) into an ordered array of
// task objects. Shared by tasks:/handlers: (same block shape) and by
// workspaceToTasks() (role tasks/main.yml — a bare top-level chain).
function taskChainToObjects(firstBlock) {
  const tasks = [];
  let block = firstBlock;
  while (block) {
    if (block.isEnabled()) tasks.push(blockToTaskObject(block));
    block = block.getNextBlock();
  }
  return tasks;
}

function blockToRoleObject(roleBlock) {
  const name = fieldValue(roleBlock, 'ROLE_NAME');
  const roleVars = parseYamlMapping(fieldValue(roleBlock, 'VARS'));
  if (!roleVars) return name;
  return { role: name, ...roleVars };
}

// A define_var block's VALUE field accepts plain text OR YAML (numbers,
// comma/dash lists, mappings) — same permissive convention as EXTRA/role
// VARS. A bare word like "nginx" round-trips as the string "nginx" via
// yaml.load, so this is safe for the common case of a plain string value.
// Coerces a scalar text field into its JS value: numbers/booleans/inline
// lists/mappings parse via YAML; a Jinja `{{ … }}`/`{% … %}` template always
// stays a verbatim string (YAML would choke on the braces); everything else
// stays a string. Empty → ''. Used for variable values and dict-entry values.
function coerceScalarValue(raw) {
  const text = raw == null ? '' : String(raw);
  if (text === '') return '';
  if (text.includes('{{') || text.includes('{%')) return text;
  try {
    const parsed = yaml.load(text);
    return parsed === undefined ? text : parsed;
  } catch {
    return text;
  }
}

// A `dict` block → a plain JS mapping object. Each dict_entry's value is its
// connected value block (variable/nested dict) if present, else its scalar
// text field (see coerceScalarValue).
function dictBlockToObject(dictBlock) {
  const obj = {};
  let entry = dictBlock.getInputTargetBlock('ENTRIES');
  while (entry) {
    if (entry.type === 'dict_entry' && entry.isEnabled()) {
      const key = (entry.getFieldValue('KEY') || '').trim();
      if (key) {
        const vb = entry.getInputTargetBlock('VALUE_BLOCK');
        obj[key] = vb ? valueBlockToValue(vb) : coerceScalarValue(entry.getFieldValue('VALUE'));
      }
    }
    entry = entry.getNextBlock();
  }
  return obj;
}

// A `list` block → a plain JS array, same "block wins over field" pattern as
// dictBlockToObject.
function listBlockToArray(listBlock) {
  const arr = [];
  let item = listBlock.getInputTargetBlock('ITEMS');
  while (item) {
    if (item.type === 'list_item' && item.isEnabled()) {
      const vb = item.getInputTargetBlock('VALUE_BLOCK');
      arr.push(vb ? valueBlockToValue(vb) : coerceScalarValue(item.getFieldValue('VALUE')));
    }
    item = item.getNextBlock();
  }
  return arr;
}

// A "value block" (variable reference / literal / dict / list) → its JS
// value, in a VALUE context (a variable's value or a dict-/list-typed param)
// — NOT a when: condition. Key difference from conditionBlockToExpr: a
// cond_var here becomes a templated `{{ name }}` reference (in vars/params a
// bare name would be a literal string), whereas in a when: expression it
// stays bare.
export function valueBlockToValue(block) {
  if (!block) return null;
  switch (block.type) {
    case 'cond_var': {
      const name = (block.getFieldValue('NAME') || '').trim();
      return name ? `{{ ${name} }}` : '';
    }
    case 'cond_literal':
      return coerceScalarValue(block.getFieldValue('VALUE'));
    case 'dict':
      return dictBlockToObject(block);
    case 'list':
      return listBlockToArray(block);
    default:
      return null;
  }
}

// The value of a define_var block: a connected value block (dict/variable)
// wins over the scalar text field.
function varBlockValue(varBlock) {
  const vb = varBlock.getInputTargetBlock('VALUE_BLOCK');
  return vb ? valueBlockToValue(vb) : coerceScalarValue(fieldValue(varBlock, 'VALUE'));
}

function blockToPlayObject(playBlock) {
  const name = fieldValue(playBlock, 'NAME');
  const hosts = fieldValue(playBlock, 'HOSTS');
  const become = fieldValue(playBlock, 'BECOME');
  const extra = fieldValue(playBlock, 'EXTRA');

  const vars = {};
  let varBlock = playBlock.getInputTargetBlock('VARS');
  while (varBlock) {
    if (varBlock.isEnabled()) {
      const varName = fieldValue(varBlock, 'NAME');
      if (varName) vars[varName] = varBlockValue(varBlock);
    }
    varBlock = varBlock.getNextBlock();
  }

  const roles = [];
  let roleBlock = playBlock.getInputTargetBlock('ROLES');
  while (roleBlock) {
    if (roleBlock.isEnabled()) {
      roles.push(blockToRoleObject(roleBlock));
    }
    roleBlock = roleBlock.getNextBlock();
  }

  const tasks = taskChainToObjects(playBlock.getInputTargetBlock('TASKS'));
  const handlers = taskChainToObjects(playBlock.getInputTargetBlock('HANDLERS'));

  const play = { name, hosts };
  if (become) play.become = true;
  if (Object.keys(vars).length) play.vars = vars;
  // Play-level keys without a dedicated block yet (environment:, ...)
  // round-trip verbatim through this field — see blocks.js. `roles:` has its
  // own typed role_use blocks (below) and `vars:` its own define_var chain
  // (above), neither is part of EXTRA.
  const extraObj = parseYamlMapping(extra);
  if (extraObj) Object.assign(play, extraObj);
  if (roles.length) play.roles = roles;
  play.tasks = tasks;
  // Handlers are the same block shape as tasks (module_*/raw_task), just
  // addressed by name via another task's notify: — see blocks.js.
  if (handlers.length) play.handlers = handlers;
  return play;
}

export function workspaceToPlays(workspace) {
  return workspace
    .getTopBlocks(true)
    .filter((block) => block.type === 'play' && block.isEnabled())
    .map(blockToPlayObject);
}

// Role-tasks document mode: a role's tasks/main.yml is a bare list of tasks
// (no play wrapper). Collect every top-level module/raw_task stack in order.
export function workspaceToTasks(workspace) {
  const tasks = [];
  workspace.getTopBlocks(true).forEach((top) => {
    const isTaskLike = top.type === 'raw_task' || top.type === 'block_task' || top.type.startsWith('module_');
    if (isTaskLike) tasks.push(...taskChainToObjects(top));
  });
  return tasks;
}

// Role defaults/main.yml and vars/main.yml are both a bare vars: mapping
// (no play/task wrapper) — a top-level chain of define_var blocks, the
// inverse of importVarsYaml() in playbookImporter.js.
export function workspaceToVarsMapping(workspace) {
  const vars = {};
  workspace.getTopBlocks(true).forEach((top) => {
    if (top.type !== 'define_var') return;
    let block = top;
    while (block) {
      if (block.isEnabled()) {
        const name = fieldValue(block, 'NAME');
        if (name) vars[name] = varBlockValue(block);
      }
      block = block.getNextBlock();
    }
  });
  return vars;
}

export function workspaceToPlaybook(workspace) {
  const plays = workspaceToPlays(workspace);
  return jsonToYaml(JSON.stringify(plays));
}

// Serializes the workspace for the active document mode:
//   'playbook' → list of plays; 'role'/'tasks' → bare list of tasks
//   (tasks/main.yml and handlers/main.yml are the same shape); 'vars' →
//   bare vars: mapping (defaults/main.yml and vars/main.yml are the same
//   shape) — see the role section tabs in PlaybookBuilder.js.
export function serializeWorkspace(workspace, mode = 'playbook') {
  // A role section (vars/tasks/handlers/defaults) whose file failed to parse
  // on import becomes a single raw_section block holding the original text
  // verbatim (see playbookImporter's importVarsYaml/importTasksYaml) — if
  // present, that text IS this section's output, unchanged. Without this
  // check, saving would silently regenerate an empty mapping/list from the
  // (correctly) empty set of define_var/module blocks and overwrite the
  // real file. Not relevant to 'playbook' mode — importPlaybookYaml throws
  // visibly instead of ever creating this block.
  if (mode === 'vars' || mode === 'role' || mode === 'tasks') {
    const rawSection = workspace.getTopBlocks(true).find((b) => b.type === 'raw_section' && b.isEnabled());
    if (rawSection) return fieldValue(rawSection, 'RAW_YAML');
  }
  if (mode === 'vars') return jsonToYaml(JSON.stringify(workspaceToVarsMapping(workspace)));
  const doc = (mode === 'role' || mode === 'tasks') ? workspaceToTasks(workspace) : workspaceToPlays(workspace);
  return jsonToYaml(JSON.stringify(doc));
}
