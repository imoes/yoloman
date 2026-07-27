// awx-ng: inverse of ansibleGenerator.js — parses existing playbook YAML
// (hand-written or from before this feature existed) and reconstructs it as
// Blockly blocks, so users can open and visually edit files they didn't
// create with the builder. Anything not covered by a typed block (a module
// outside ansible.builtin, an unrecognized task shape like block/rescue, or
// play-level keys without a dedicated block yet) is preserved verbatim via
// the raw_task/EXTRA escape hatches — no data loss on import.
import * as Blockly from 'blockly';
import yaml from 'js-yaml';
import { moduleBlockType, MODULE_NAMES, ENVELOPE_FIELDS } from './blocks';
import { newBlock } from './blocklyUtil';
import { parseConditionToBlock } from './conditionParser';

const KNOWN_PLAY_KEYS = new Set(['name', 'hosts', 'become', 'tasks', 'roles', 'handlers']);
// A task's module key is whatever remains after removing "name" and every
// task-level modifier keyword (when/tags/notify/register/become/…) — NOT
// simply "the first unrecognized key", which used to misfire whenever a
// task had more than one modifier (e.g. loop + register together would
// make the importer mistake "loop" for the module and raw_task the rest).
// `with_items` is the legacy predecessor of `loop:` (still common in older
// playbooks) — treated as an alias so those tasks don't need the modern
// keyword to be recognized.
const KNOWN_TASK_ENVELOPE_KEYS = new Set([
  'name', 'with_items', ...ENVELOPE_FIELDS.map((e) => e.yamlKey),
]);
const MODULE_NAME_SET = new Set(MODULE_NAMES);

function setField(block, fieldName, value) {
  const field = block.getField(fieldName);
  if (!field) return;
  if (field instanceof Blockly.FieldCheckbox) {
    field.setValue(value ? 'TRUE' : 'FALSE');
  } else if (value !== null && typeof value === 'object') {
    // List/dict-typed param values (e.g. apt's `name: [nginx, curl]`) — dump
    // to YAML text rather than JS's `String([...])`/`"[object Object]"`, so
    // the field holds a value the generator's coerceModuleArgValue() (and a
    // human) can actually parse back.
    field.setValue(yaml.dump(value).trim());
  } else {
    field.setValue(String(value));
  }
}

// Parses Ansible's inline "key=value" shorthand (e.g.
// `file: path=/tmp/x state=directory mode=0755`) into a plain object.
// Values may be quoted. Returns {} if nothing key=value-shaped is found
// (e.g. a bare free-form command like `command: ls -la`).
function parseInlineArgs(str) {
  const result = {};
  const re = /(\w+)=("[^"]*"|'[^']*'|\S+)/g;
  let m = re.exec(str);
  while (m !== null) {
    let value = m[2];
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    result[m[1]] = value;
    m = re.exec(str);
  }
  return result;
}

// Builds a module_<name> block (which IS the task block — see blocks.js) if
// the module is in the ansible.builtin catalog AND every arg key maps to a
// known param with a scalar value; otherwise returns null so the caller
// falls back to raw_task (lossless).
function importModuleBlock(workspace, moduleKey, args) {
  const shortName = moduleKey.includes('.') ? moduleKey.split('.').pop() : moduleKey;
  // Ansible accepts args as a mapping OR as an inline "key=value" string —
  // normalize the inline form so those tasks still get a typed module block.
  let normalizedArgs = args;
  if (typeof args === 'string') {
    const inline = parseInlineArgs(args);
    if (Object.keys(inline).length) normalizedArgs = inline;
  }
  const argEntries = normalizedArgs && typeof normalizedArgs === 'object' && !Array.isArray(normalizedArgs)
    ? Object.entries(normalizedArgs)
    : null;

  if (!MODULE_NAME_SET.has(shortName) || (!argEntries && args !== null && args !== undefined)) {
    return null;
  }

  const moduleBlock = newBlock(workspace, moduleBlockType(shortName));
  const paramTypes = moduleBlock.paramTypes_ || {};
  const paramAliases = moduleBlock.paramAliases_ || {};
  // Real playbooks routinely use a param's alias instead of its canonical
  // name (ansible.builtin.file's `dest:`/`name:` for `path:`, apt's `pkg:`
  // for `name:`, systemd's `unit:` for `name:`, …) — resolve every incoming
  // key to its canonical param name up front so the rest of this function
  // (and the generated block) only ever deals with canonical names.
  const canonicalArgEntries = argEntries
    ? argEntries.map(([key, value]) => [paramAliases[key] || key, value])
    : null;
  // Optional params aren't shown by default — add their rows before setting
  // values. A non-scalar value (array/object) is only representable when the
  // param's own ansible-doc type declares it (list/dict/raw) — e.g. apt's
  // `name: [nginx, curl]` — since the field will parse it back via that same
  // type (see coerceModuleArgValue). An array/object on an otherwise
  // scalar-typed param is unexpected input we can't represent faithfully.
  const isScalar = (v) => v === null || v === undefined || typeof v !== 'object';
  const canRepresent = (canonicalArgEntries || []).every(([key, value]) => {
    if (!isScalar(value)) {
      const declaredType = paramTypes[key];
      if (declaredType !== 'list' && declaredType !== 'dict' && declaredType !== 'raw') {
        return false;
      }
    }
    if (moduleBlock.getField(key)) return true;
    moduleBlock.addOptionalParam(key);
    return !!moduleBlock.getField(key);
  });
  if (!canRepresent) {
    moduleBlock.dispose();
    return null;
  }
  (canonicalArgEntries || []).forEach(([key, value]) => {
    // A dict-typed param whose value is a mapping, or a list-typed param
    // whose value is an array, is built visually with a `dict`/`list` block
    // plugged into the param's BLOCK_<key> input (see blocks.js); everything
    // else goes into the param's text field as before.
    const isMapping = value && typeof value === 'object' && !Array.isArray(value);
    const isArray = Array.isArray(value);
    const useBlock = (paramTypes[key] === 'dict' && isMapping) || (paramTypes[key] === 'list' && isArray);
    const blockInput = useBlock ? moduleBlock.getInput(`BLOCK_${key}`) : null;
    if (blockInput) {
      const valueBlock = isMapping ? buildDictBlock(workspace, value) : buildListBlock(workspace, value);
      blockInput.connection.connect(valueBlock.outputConnection);
    } else {
      setField(moduleBlock, key, value);
    }
  });
  return moduleBlock;
}

function importTask(workspace, taskObj) {
  const moduleKeys = Object.keys(taskObj).filter((k) => !KNOWN_TASK_ENVELOPE_KEYS.has(k));

  // Zero or more-than-one remaining key: can't unambiguously identify the
  // module (e.g. block:/rescue:/always:, or an empty task) — preserve the
  // whole task verbatim rather than guessing wrong.
  const moduleBlock = moduleKeys.length === 1
    ? importModuleBlock(workspace, moduleKeys[0], taskObj[moduleKeys[0]])
    : null;

  if (!moduleBlock) {
    const rawTask = newBlock(workspace, 'raw_task');
    setField(rawTask, 'RAW_YAML', yaml.dump(taskObj).trim());
    return rawTask;
  }

  if (taskObj.name) setField(moduleBlock, 'NAME', taskObj.name);
  ENVELOPE_FIELDS.forEach((envelope) => {
    // `with_items` is the legacy alias for `loop:` (see KNOWN_TASK_ENVELOPE_KEYS) —
    // both populate the same LOOP setting; regeneration always emits `loop:`.
    const sourceKey = envelope.key === 'LOOP' && !('loop' in taskObj) && 'with_items' in taskObj
      ? 'with_items'
      : envelope.yamlKey;
    if (!(sourceKey in taskObj)) return;
    let value = taskObj[sourceKey];
    // Each task setting is its own standalone block chained onto the
    // module's SETTINGS statement input (see blocks.js) — addEnvelopeField
    // creates (or returns the existing) one.
    const settingBlock = moduleBlock.addEnvelopeField(envelope.key);
    if (envelope.kind === 'value') {
      // when: may be a single Jinja expression string, or a list of strings
      // that Ansible implicitly ANDs together — normalize to one string
      // before handing it to the condition parser (see conditionParser.js).
      const exprText = Array.isArray(value) ? value.join(' and ') : String(value);
      const condBlock = parseConditionToBlock(workspace, exprText);
      settingBlock.getInput('VALUE').connection.connect(condBlock.outputConnection);
      return;
    }
    if (envelope.key === 'TAGS' || envelope.key === 'NOTIFY') {
      value = Array.isArray(value) ? value.join(', ') : value;
    } else if (envelope.key === 'LOOP' && typeof value !== 'string') {
      value = yaml.dump(value).trim();
    }
    setField(settingBlock, 'VALUE', value);
  });
  return moduleBlock;
}

// A `roles:` entry is either a plain role name string, or an object
// `{role: name, ...vars}` — the inverse of ansibleGenerator's
// blockToRoleObject().
function importRole(workspace, roleEntry) {
  const roleBlock = newBlock(workspace, 'role_use');
  if (typeof roleEntry === 'string') {
    setField(roleBlock, 'ROLE_NAME', roleEntry);
  } else if (roleEntry && typeof roleEntry === 'object') {
    const { role, ...roleVars } = roleEntry;
    setField(roleBlock, 'ROLE_NAME', role);
    if (Object.keys(roleVars).length) {
      setField(roleBlock, 'VARS', yaml.dump(roleVars).trim());
    }
  }
  return roleBlock;
}

// A `vars:` entry becomes its own define_var block (the inverse of
// blockToVarValue in ansibleGenerator.js) — non-scalar values (list/dict)
// are YAML-dumped into the multiline VALUE field via setField's existing
// object handling.
// Builds a "value block" for a JS value — a nested `dict`/`list` block for a
// mapping/array, or a `cond_var` for a bare `{{ variable }}` reference — or
// null if the value is a plain scalar that belongs in a text field. Inverse
// of ansibleGenerator's valueBlockToValue.
function buildValueBlock(workspace, value) {
  if (Array.isArray(value)) {
    return buildListBlock(workspace, value);
  }
  if (value && typeof value === 'object') {
    return buildDictBlock(workspace, value);
  }
  if (typeof value === 'string') {
    // Only a single bare variable reference (e.g. {{ db_host }},
    // {{ ansible_facts['x'] }}) becomes a var block — a complex Jinja
    // expression ({{ a | default(b) }}) stays verbatim text.
    const m = value.match(/^\{\{\s*([\w[\]'".-]+)\s*\}\}$/);
    if (m) {
      const varRef = newBlock(workspace, 'cond_var');
      setField(varRef, 'NAME', m[1]);
      return varRef;
    }
  }
  return null;
}

// A plain mapping object → a `dict` block with a chain of `dict_entry`
// blocks. Nested mappings/variables recurse via buildValueBlock; plain
// scalars/lists go into each entry's text field.
function buildDictBlock(workspace, obj) {
  const dict = newBlock(workspace, 'dict');
  let prev = null;
  Object.entries(obj).forEach(([key, val]) => {
    const entry = newBlock(workspace, 'dict_entry');
    setField(entry, 'KEY', key);
    const vb = buildValueBlock(workspace, val);
    if (vb) {
      entry.getInput('VALUE_BLOCK').connection.connect(vb.outputConnection);
    } else {
      setField(entry, 'VALUE', val);
    }
    if (prev) {
      prev.nextConnection.connect(entry.previousConnection);
    } else {
      dict.getInput('ENTRIES').connection.connect(entry.previousConnection);
    }
    prev = entry;
  });
  return dict;
}

// A plain array → a `list` block with a chain of `list_item` blocks. Same
// recursion as buildDictBlock, just without keys.
function buildListBlock(workspace, arr) {
  const list = newBlock(workspace, 'list');
  let prev = null;
  arr.forEach((val) => {
    const item = newBlock(workspace, 'list_item');
    const vb = buildValueBlock(workspace, val);
    if (vb) {
      item.getInput('VALUE_BLOCK').connection.connect(vb.outputConnection);
    } else {
      setField(item, 'VALUE', val);
    }
    if (prev) {
      prev.nextConnection.connect(item.previousConnection);
    } else {
      list.getInput('ITEMS').connection.connect(item.previousConnection);
    }
    prev = item;
  });
  return list;
}

function importVar(workspace, varName, varValue) {
  const varBlock = newBlock(workspace, 'define_var');
  setField(varBlock, 'NAME', varName);
  // A mapping or bare {{ variable }} value becomes a structured block plugged
  // into VALUE_BLOCK; a plain scalar/list stays in the text field.
  const vb = buildValueBlock(workspace, varValue);
  if (vb) {
    varBlock.getInput('VALUE_BLOCK').connection.connect(vb.outputConnection);
  } else {
    setField(varBlock, 'VALUE', varValue);
  }
  return varBlock;
}

function importPlay(workspace, playObj) {
  const playBlock = newBlock(workspace, 'play');
  if (playObj.name) setField(playBlock, 'NAME', playObj.name);
  if (playObj.hosts) setField(playBlock, 'HOSTS', playObj.hosts);
  if (playObj.become) setField(playBlock, 'BECOME', true);

  // Only decompose vars: into typed blocks when it's a plain mapping (the
  // normal case) — anything unusual (list, scalar) falls through to EXTRA
  // below, lossless rather than silently dropped.
  const varsIsMapping = playObj.vars && typeof playObj.vars === 'object' && !Array.isArray(playObj.vars);

  const extraKeys = Object.keys(playObj).filter(
    (k) => !KNOWN_PLAY_KEYS.has(k) && !(k === 'vars' && varsIsMapping)
  );
  if (extraKeys.length) {
    const extra = {};
    extraKeys.forEach((k) => { extra[k] = playObj[k]; });
    setField(playBlock, 'EXTRA', yaml.dump(extra).trim());
  }

  let previousVar = null;
  if (varsIsMapping) {
    Object.entries(playObj.vars).forEach(([varName, varValue]) => {
      const varBlock = importVar(workspace, varName, varValue);
      if (previousVar) {
        previousVar.nextConnection.connect(varBlock.previousConnection);
      } else {
        playBlock.getInput('VARS').connection.connect(varBlock.previousConnection);
      }
      previousVar = varBlock;
    });
  }

  let previousRole = null;
  (playObj.roles || []).forEach((roleEntry) => {
    const roleBlock = importRole(workspace, roleEntry);
    if (previousRole) {
      previousRole.nextConnection.connect(roleBlock.previousConnection);
    } else {
      playBlock.getInput('ROLES').connection.connect(roleBlock.previousConnection);
    }
    previousRole = roleBlock;
  });

  chainTasksInto(workspace, playBlock, 'TASKS', playObj.tasks);
  // Handlers are the same block shape as tasks (module_*/raw_task), just
  // addressed by name via another task's notify: — see blocks.js.
  chainTasksInto(workspace, playBlock, 'HANDLERS', playObj.handlers);

  return playBlock;
}

// Imports a list of task objects into a module_*/raw_task chain plugged into
// `inputName` on `containerBlock` — shared by TASKS and HANDLERS (identical
// shape) and reusable by role-mode's bare task list.
function chainTasksInto(workspace, containerBlock, inputName, taskObjs) {
  let previousTask = null;
  (taskObjs || []).forEach((taskObj) => {
    const taskBlock = importTask(workspace, taskObj);
    if (previousTask) {
      previousTask.nextConnection.connect(taskBlock.previousConnection);
    } else {
      containerBlock.getInput(inputName).connection.connect(taskBlock.previousConnection);
    }
    previousTask = taskBlock;
  });
}

// Parses playbook YAML (a top-level list of plays) and rebuilds it as
// blocks on `workspace`, replacing whatever is currently on it. Returns the
// number of plays imported.
export function importPlaybookYaml(content, workspace) {
  const plays = yaml.load(content);
  if (!Array.isArray(plays)) {
    throw new Error('Expected a YAML list of plays at the top level.');
  }
  workspace.clear();
  plays.forEach((playObj, index) => {
    const playBlock = importPlay(workspace, playObj);
    // Fixed vertical spacing between top-level plays — precise layout isn't
    // functionally important (only generation correctness is), just enough
    // to keep multiple imported plays from rendering on top of each other.
    if (typeof playBlock.moveBy === 'function') {
      playBlock.moveBy(20, 20 + index * 400);
    }
  });
  return plays.length;
}

// Role-tasks document mode: a role's tasks/main.yml (and, identically
// shaped, handlers/main.yml) is a bare list of tasks. Rebuilds it as a
// single top-level stack of module/raw_task blocks (no play wrapper), the
// inverse of ansibleGenerator's workspaceToTasks(). An empty/null document
// (a freshly-scaffolded stub file, "---\n") is treated as zero tasks rather
// than an error, so a brand-new role's untouched sections still open.
export function importTasksYaml(content, workspace) {
  let tasks;
  try {
    tasks = yaml.load(content) || [];
    if (!Array.isArray(tasks)) throw new Error('Expected a YAML list of tasks at the top level.');
  } catch {
    // Content exists but js-yaml can't parse it at all (e.g. an Ansible
    // !unsafe/!vault tag) — preserve it verbatim via raw_section rather than
    // silently importing as "0 tasks" (which the caller can't tell apart
    // from a genuinely empty file, and would then overwrite on save).
    workspace.clear();
    const rawBlock = newBlock(workspace, 'raw_section');
    setField(rawBlock, 'RAW_YAML', content);
    if (typeof rawBlock.moveBy === 'function') rawBlock.moveBy(20, 20);
    return 0;
  }
  workspace.clear();
  let previousTask = null;
  tasks.forEach((taskObj, index) => {
    const taskBlock = importTask(workspace, taskObj);
    if (previousTask) {
      previousTask.nextConnection.connect(taskBlock.previousConnection);
    } else if (typeof taskBlock.moveBy === 'function') {
      taskBlock.moveBy(20, 20);
    }
    previousTask = taskBlock;
    return index;
  });
  return tasks.length;
}

// Role vars document mode: a role's defaults/main.yml (and, identically
// shaped, vars/main.yml) is a bare vars: mapping — no play/task wrapper.
// Rebuilds it as a top-level chain of define_var blocks, the inverse of
// ansibleGenerator's workspaceToVarsMapping(). An empty/null document (a
// freshly-scaffolded stub file) is treated as zero variables.
export function importVarsYaml(content, workspace) {
  let varsObj;
  try {
    varsObj = yaml.load(content) || {};
    if (typeof varsObj !== 'object' || Array.isArray(varsObj)) {
      throw new Error('Expected a YAML mapping of variables at the top level.');
    }
  } catch {
    // Same rationale as importTasksYaml's catch above — preserve verbatim
    // via raw_section instead of silently showing "0 variables" (this is
    // exactly what was happening for real roles using !unsafe, e.g. a
    // Docker daemon.json default containing a Go-template string that must
    // NOT be Jinja-rendered — the vars were on disk and in the Variables
    // panel's role_variables scan, but invisible on this tab and one
    // "Lint & Save" away from being wiped out).
    workspace.clear();
    const rawBlock = newBlock(workspace, 'raw_section');
    setField(rawBlock, 'RAW_YAML', content);
    if (typeof rawBlock.moveBy === 'function') rawBlock.moveBy(20, 20);
    return 0;
  }
  workspace.clear();
  let previousVar = null;
  const entries = Object.entries(varsObj);
  entries.forEach(([varName, varValue]) => {
    const varBlock = importVar(workspace, varName, varValue);
    if (previousVar) {
      previousVar.nextConnection.connect(varBlock.previousConnection);
    } else if (typeof varBlock.moveBy === 'function') {
      varBlock.moveBy(20, 20);
    }
    previousVar = varBlock;
  });
  return entries.length;
}
