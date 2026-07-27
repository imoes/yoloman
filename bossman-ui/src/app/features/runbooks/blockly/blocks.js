// awx-ng: Blockly block definitions for the visual playbook builder.
// Static blocks (play/role/raw fallback) + one auto-generated block per
// ansible.builtin module from moduleCatalog.generated.json.
//
// Module blocks double as task blocks (no separate "task" wrapper): every
// module_<name> block is itself a statement block with a `name:` field and
// can plug directly into a play's tasks stack. Task-level modifiers
// (when/tags/notify/register/become/ignore_errors/delegate_to/loop) are
// available via the same "add parameter…" dropdown as the module's own
// optional arguments — one consolidated place to add anything.
import * as Blockly from 'blockly';
import { registerFieldMultilineInput, FieldMultilineInput } from '@blockly/field-multilineinput';
import moduleCatalog from './moduleCatalog.generated.json';

// The multiline text field is a plugin in Blockly v11 (removed from core).
registerFieldMultilineInput();

const MODULE_BLOCK_PREFIX = 'module_';
const ADD_PARAM_PLACEHOLDER = '';

// ansible-doc leaves some very common params without an explicit choices
// list because the module just forwards to a backend (package: apt/yum/dnf/
// etc.) — of the whole catalog, `package.state` is the only such case (every
// other state-like param already carries real choices from ansible-doc).
// Curated here since guessing at scale would misrepresent modules that
// genuinely accept freeform values.
const CURATED_CHOICES = {
  package: { state: ['present', 'absent', 'latest'] },
};

// Params shown by default for modules whose primary option isn't marked
// "required" in ansible-doc (so e.g. debug still shows `msg`, command shows
// `cmd`). Keeps module blocks small — required + these — while surfacing the
// option people actually reach for. Everything else is added on demand via
// the "add parameter…" dropdown.
const PRIMARY_PARAMS = {
  debug: ['msg'],
  command: ['cmd'],
  shell: ['cmd'],
  copy: ['src', 'dest', 'content'],
  file: ['path', 'state'],
  lineinfile: ['path', 'line'],
  blockinfile: ['path', 'block'],
  user: ['name', 'state'],
  group: ['name', 'state'],
  service: ['name', 'state'],
  systemd: ['name', 'state'],
  systemd_service: ['name', 'state'],
  apt: ['name', 'state'],
  yum: ['name', 'state'],
  dnf: ['name', 'state'],
  package: ['name', 'state'],
  pip: ['name', 'state'],
  get_url: ['url', 'dest'],
  uri: ['url', 'method'],
  set_fact: ['key_value'],
  cron: ['name', 'job'],
};

// Common Ansible task-level keywords, offered on every module block via the
// "add task setting…" dropdown. Each one is its OWN standalone, single-row,
// chainable "setting" block (see defineTaskSettingBlocks()) — NOT a row
// directly on the module block. Reason: Blockly only lets a block be
// "inline" (the recessed/embedded look for a plugged-in value, e.g. WHEN's
// condition) as a whole-block setting, not per-row — and the module block
// has 10+ other one-per-line param rows that must NOT be forced inline.
// Giving each setting its own tiny single-row block makes inline safe for
// that block alone, so a WHEN condition renders properly embedded instead of
// looking bolted on from outside.
export const COND_CHECK = 'Cond';
export const TASK_SETTING_CHECK = 'TaskSetting';
// A "value" is a variable reference, literal, or dict (later also list) that
// can fill a variable's value or a dict-/structured module param — as opposed
// to a condition (COND_CHECK). cond_var/cond_literal keep a wildcard output
// (null) so they still fit both a when: condition AND a value slot; the
// `dict` block outputs VALUE_CHECK so it fits value slots but NOT when:.
export const VALUE_CHECK = 'Value';
export const DICT_ENTRY_CHECK = 'DictEntry';
export const LIST_ITEM_CHECK = 'ListItem';
export const ENVELOPE_FIELDS = [
  { key: 'WHEN', label: 'when', yamlKey: 'when', kind: 'value', check: COND_CHECK },
  { key: 'TAGS', label: 'tags', yamlKey: 'tags', kind: 'field', fieldKind: 'text' },
  { key: 'NOTIFY', label: 'notify', yamlKey: 'notify', kind: 'field', fieldKind: 'text' },
  { key: 'REGISTER', label: 'register', yamlKey: 'register', kind: 'field', fieldKind: 'text' },
  { key: 'LOOP', label: 'loop', yamlKey: 'loop', kind: 'field', fieldKind: 'multiline' },
  { key: 'DELEGATE_TO', label: 'delegate_to', yamlKey: 'delegate_to', kind: 'field', fieldKind: 'text' },
  { key: 'BECOME', label: 'become', yamlKey: 'become', kind: 'field', fieldKind: 'checkbox' },
  { key: 'IGNORE_ERRORS', label: 'ignore_errors', yamlKey: 'ignore_errors', kind: 'field', fieldKind: 'checkbox' },
];
export const ENVELOPE_BY_KEY = {};
ENVELOPE_FIELDS.forEach((e) => { ENVELOPE_BY_KEY[e.key] = e; });

export function settingBlockType(key) {
  return `setting_${key.toLowerCase()}`;
}

// Every field id that is part of the module block's own fixed scaffolding —
// never a module argument. Used by the generator to know which fields to
// skip when collecting a module's own args. Task-setting keys (when/tags/…)
// no longer live here — they're fields on their own separate blocks now.
export const RESERVED_FIELD_NAMES = new Set(['MODULE_LABEL', 'ADD_PARAM', 'ADD_TASKOPT', 'NAME']);

function moduleBlockType(shortName) {
  return `${MODULE_BLOCK_PREFIX}${shortName}`;
}

function effectiveChoices(moduleShortName, param) {
  if (param.choices && param.choices.length) return param.choices;
  return (CURATED_CHOICES[moduleShortName] || {})[param.name] || null;
}

function fieldForParam(param, choices) {
  // Fields start blank/unchecked; dropdowns lead with an "(unset)" option
  // (value '') so an untouched field emits nothing at generation time.
  if (choices && choices.length) {
    const options = [['(unset)', ''], ...choices.map((c) => [String(c), String(c)])];
    return new Blockly.FieldDropdown(options);
  }
  if (param.type === 'bool') {
    return new Blockly.FieldCheckbox('FALSE');
  }
  // Text params use a multiline field so values can contain line breaks
  // (shell scripts, copy content, multi-line messages, or one-item-per-line
  // for list/dict params — see ansibleGenerator's type-aware parsing). It
  // stays compact for single-line values and grows as lines are added.
  return new FieldMultilineInput('');
}

// list/dict/raw params accept structured values (e.g. a package list) that a
// single flat field can't self-document — the label hints at the expected
// shape so users don't have to guess (comma list OR one-per-line OR full
// YAML — see ansibleGenerator.coerceModuleArgValue).
function typeHint(param) {
  if (param.type === 'list') return ' [list]';
  if (param.type === 'dict') return ' {dict}';
  return '';
}

function appendParamRow(block, param, moduleShortName) {
  // Required params are marked with a trailing "*".
  const label = `${param.name}${param.required ? ' *' : ''}${typeHint(param)}`;
  const choices = effectiveChoices(moduleShortName, param);
  block
    .appendDummyInput(`ROW_${param.name}`)
    .appendField(`${label}:`)
    .appendField(fieldForParam(param, choices), param.name);
  // dict-/list-typed params can be built visually with a `dict`/`list` block
  // instead of typing YAML into the text field — the block (when connected)
  // wins over the field (see ansibleGenerator blockToModuleArgs).
  if (param.type === 'dict' || param.type === 'list') {
    const kind = param.type === 'dict' ? 'dict' : 'list';
    block
      .appendValueInput(`BLOCK_${param.name}`)
      .setCheck(VALUE_CHECK)
      .appendField(`${param.name} (${kind} block):`);
  }
}

// One standalone block type per task-setting keyword (see ENVELOPE_FIELDS
// above) — each has exactly one row, so `setInputsInline(true)` is always
// safe (there's nothing else on the block it could wrongly merge with),
// which is what gives WHEN's plugged-in condition its recessed/embedded
// look instead of appearing bolted on from outside.
function defineTaskSettingBlocks() {
  ENVELOPE_FIELDS.forEach((envelope) => {
    Blockly.Blocks[settingBlockType(envelope.key)] = {
      init() {
        if (envelope.kind === 'value') {
          this.appendValueInput('VALUE').setCheck(envelope.check || null).appendField(`${envelope.label}:`);
        } else if (envelope.fieldKind === 'checkbox') {
          this.appendDummyInput().appendField(envelope.label).appendField(new Blockly.FieldCheckbox('TRUE'), 'VALUE');
        } else if (envelope.fieldKind === 'multiline') {
          this.appendDummyInput().appendField(`${envelope.label}:`).appendField(new FieldMultilineInput(''), 'VALUE');
        } else {
          this.appendDummyInput().appendField(`${envelope.label}:`).appendField(new Blockly.FieldTextInput(''), 'VALUE');
        }
        this.setInputsInline(true);
        this.setPreviousStatement(true, TASK_SETTING_CHECK);
        this.setNextStatement(true, TASK_SETTING_CHECK);
        this.setColour(230);
        this.settingKey_ = envelope.key;
        this.setTooltip(`Task setting: ${envelope.yamlKey}:`);
      },
    };
  });
}

function defineModuleBlocks() {
  moduleCatalog.forEach((mod) => {
    const blockType = moduleBlockType(mod.short_name);
    const paramByName = {};
    mod.params.forEach((p) => { paramByName[p.name] = p; });
    // Real playbooks routinely use a param's alias instead of its canonical
    // name (file's `dest:`/`name:` for `path:`, apt's `pkg:` for `name:`,
    // systemd's `unit:` for `name:`, …) — map every alias to the canonical
    // param so the importer can recognize either spelling.
    const aliasToCanonical = {};
    mod.params.forEach((p) => {
      (p.aliases || []).forEach((alias) => { aliasToCanonical[alias] = p.name; });
    });

    const requiredNames = mod.params.filter((p) => p.required).map((p) => p.name);
    const primary = (PRIMARY_PARAMS[mod.short_name] || []).filter((n) => paramByName[n]);
    let defaultNames = [...new Set([...requiredNames, ...primary])];
    if (defaultNames.length === 0 && mod.params.length) {
      defaultNames = [mod.params[0].name];
    }
    const defaultSet = new Set(defaultNames);
    const optionalNames = mod.params.map((p) => p.name).filter((n) => !defaultSet.has(n));

    Blockly.Blocks[blockType] = {
      init() {
        this.appendDummyInput('HEAD').appendField(mod.short_name, 'MODULE_LABEL');
        // "task name:" (not "name:") — many modules (apt/yum/user/package/…)
        // have their OWN required "name" param; using a plain "name:" label
        // here made the block show "name:" twice with no way to tell them
        // apart. This is the task's description; the module's own `name`
        // param (if any) appears below with its own row.
        this.appendDummyInput('ROW_NAME')
          .appendField('task name:')
          .appendField(new Blockly.FieldTextInput(''), 'NAME');
        this.activeOptional_ = [];
        // Looked up by the generator/importer to parse each field's raw text
        // into the right shape (list/dict/int/float/raw) — see
        // ansibleGenerator.coerceModuleArgValue().
        this.paramTypes_ = {};
        mod.params.forEach((p) => { this.paramTypes_[p.name] = p.type; });
        // Looked up by the importer to resolve an incoming YAML key that's an
        // alias (e.g. `dest:`) to the canonical param name (`path`) whose
        // field actually exists on this block.
        this.paramAliases_ = aliasToCanonical;
        defaultNames.forEach((name) => appendParamRow(this, paramByName[name], mod.short_name));
        // Two separate "add …" dropdowns so task settings (when/notify/…) are
        // clearly discoverable and not buried among the module's own params.
        this.appendDummyInput('ADD_OPT').appendField(
          new Blockly.FieldDropdown(() => this.addOptOptions_()),
          'ADD_PARAM'
        );
        this.getField('ADD_PARAM').setValidator((sel) => this.onAddParam_(sel));
        // Chain of standalone task-setting blocks (when/tags/register/…) —
        // see defineTaskSettingBlocks(). A statement input (not fields
        // directly on this block) so each setting can safely be its own
        // "inline" single-row block without disturbing this block's own
        // one-row-per-param layout. Must exist BEFORE the ADD_TASKOPT
        // dropdown below, since FieldDropdown evaluates its option generator
        // immediately and addTaskOptOptions_() reads this input.
        this.appendStatementInput('SETTINGS').setCheck(TASK_SETTING_CHECK).appendField('settings');
        this.appendDummyInput('ADD_TASKOPT').appendField(
          new Blockly.FieldDropdown(() => this.addTaskOptOptions_()),
          'ADD_TASKOPT'
        );
        this.getField('ADD_TASKOPT').setValidator((sel) => this.onAddTaskOpt_(sel));
        // Visually the settings stack belongs BELOW the "add task setting…"
        // button (constructed above only for the null-check ordering reason
        // noted there) — move it to the end now that both inputs exist.
        this.moveInputBefore('SETTINGS', undefined);
        // A module block IS a task — plugs directly into a play's tasks
        // stack (or a role's bare task list). No separate wrapper needed.
        this.setPreviousStatement(true, 'Task');
        this.setNextStatement(true, 'Task');
        this.setColour(210);
        const reqText = requiredNames.length
          ? `Required (*): ${requiredNames.join(', ')}`
          : 'No required parameters';
        this.setTooltip(`${mod.short_description || mod.name}\n${reqText}`);
        // Consumed by the generator (which module?) and importer.
        this.ansibleModuleFqcn = mod.name;
        this.moduleShortName_ = mod.short_name;
      },
      // Options for the "add parameter…" dropdown: the module's own optional
      // arguments not yet shown.
      addOptOptions_() {
        const opts = [['＋ add parameter…', ADD_PARAM_PLACEHOLDER]];
        optionalNames
          .filter((n) => !this.activeOptional_.includes(n))
          .forEach((n) => opts.push([n, n]));
        return opts;
      },
      onAddParam_(sel) {
        if (sel && sel !== ADD_PARAM_PLACEHOLDER) {
          const name = sel;
          setTimeout(() => this.addOptionalParam(name), 0);
        }
        return ADD_PARAM_PLACEHOLDER; // dropdown snaps back to the placeholder
      },
      // Options for the "add task setting…" dropdown: Ansible task-level
      // keywords (when/tags/notify/register/loop/…) not yet in the SETTINGS
      // chain.
      addTaskOptOptions_() {
        const opts = [['＋ add task setting…', ADD_PARAM_PLACEHOLDER]];
        ENVELOPE_FIELDS
          .filter((e) => !this.getSetting_(e.key))
          .forEach((e) => opts.push([e.label, e.key]));
        return opts;
      },
      onAddTaskOpt_(sel) {
        if (sel && sel !== ADD_PARAM_PLACEHOLDER) {
          const key = sel;
          setTimeout(() => this.addEnvelopeField(key), 0);
        }
        return ADD_PARAM_PLACEHOLDER;
      },
      // Public: adds an optional param row (used by the dropdown UI and by
      // the importer when a YAML task sets a param that isn't shown by
      // default). Idempotent.
      addOptionalParam(name) {
        if (this.activeOptional_.includes(name) || defaultSet.has(name)) return;
        if (!paramByName[name]) return;
        this.activeOptional_.push(name);
        appendParamRow(this, paramByName[name], mod.short_name);
        this.moveInputBefore(`ROW_${name}`, 'ADD_OPT');
        // dict/list params also get a `BLOCK_<name>` value input (appendParamRow) —
        // keep it grouped right after its row, before the "add param" dropdown.
        if (this.getInput(`BLOCK_${name}`)) this.moveInputBefore(`BLOCK_${name}`, 'ADD_OPT');
      },
      // Finds an existing task-setting block of the given key already
      // chained into the SETTINGS stack, or null.
      getSetting_(key) {
        let b = this.getInput('SETTINGS').connection.targetBlock();
        while (b) {
          if (b.settingKey_ === key) return b;
          b = b.getNextBlock();
        }
        return null;
      },
      // Public: adds a task-setting block (when/tags/register/…) to the end
      // of the SETTINGS chain and returns it (existing block if already
      // present — idempotent, and lets the importer plug a value into it,
      // e.g. WHEN's parsed condition).
      addEnvelopeField(key) {
        const existing = this.getSetting_(key);
        if (existing) return existing;
        if (!ENVELOPE_BY_KEY[key]) return null;
        const child = this.workspace.newBlock(settingBlockType(key));
        if (typeof child.initSvg === 'function') { child.initSvg(); child.render(); }
        const settingsInput = this.getInput('SETTINGS');
        let last = settingsInput.connection.targetBlock();
        if (!last) {
          settingsInput.connection.connect(child.previousConnection);
        } else {
          while (last.getNextBlock()) last = last.getNextBlock();
          last.nextConnection.connect(child.previousConnection);
        }
        return child;
      },
      // JSON serialization (sidecar save/load): only the set of added
      // optional param names — field values, AND the SETTINGS chain's child
      // blocks, are (de)serialized by Blockly itself automatically (they're
      // real connected blocks now, not custom-tracked fields).
      saveExtraState() {
        if (!this.activeOptional_.length) return null;
        return { optional: this.activeOptional_ };
      },
      loadExtraState(state) {
        this.activeOptional_ = [];
        ((state && state.optional) || []).forEach((name) => this.addOptionalParam(name));
      },
    };
  });
}

function defineStaticBlocks() {
  Blockly.Blocks.play = {
    init() {
      this.appendDummyInput()
        .appendField('Play')
        .appendField(new Blockly.FieldTextInput('play name'), 'NAME');
      this.appendDummyInput()
        .appendField('hosts:')
        .appendField(new Blockly.FieldTextInput('all'), 'HOSTS');
      this.appendDummyInput()
        .appendField('become')
        .appendField(new Blockly.FieldCheckbox('FALSE'), 'BECOME');
      this.appendDummyInput()
        .appendField('extra (environment, …):');
      this.appendDummyInput()
        .appendField(new FieldMultilineInput(''), 'EXTRA');
      this.appendStatementInput('VARS').setCheck('Var').appendField('vars');
      this.appendStatementInput('ROLES').setCheck('Role').appendField('roles');
      this.appendStatementInput('TASKS').setCheck('Task').appendField('tasks');
      // Same block shape as tasks (module_*/raw_task) — a handler is just a
      // task addressed by name via another task's notify:. notify: is
      // already free text (see ENVELOPE_FIELDS), so no separate handler-name
      // picker is needed for it to work.
      this.appendStatementInput('HANDLERS').setCheck('Task').appendField('handlers');
      this.setColour(120);
      this.setDeletable(true);
      this.setTooltip(
        'An Ansible play — a set of tasks (and/or roles) run against a group ' +
        'of hosts. "vars" holds typed variable-definition blocks; "handlers" ' +
        'holds tasks addressed by name via another task\'s notify:; "extra" ' +
        'preserves any other play-level key without a dedicated block yet ' +
        '(e.g. environment:) as raw YAML.'
      );
    },
  };

  // Defines one play-level variable (one entry of the play's vars: mapping).
  // Chained via the play's VARS statement input, same pattern as role_use/
  // ROLES and module blocks/TASKS.
  Blockly.Blocks.define_var = {
    init() {
      this.appendDummyInput()
        .appendField('var')
        .appendField(new Blockly.FieldTextInput('name'), 'NAME');
      this.appendDummyInput()
        .appendField('=')
        .appendField(new FieldMultilineInput(''), 'VALUE');
      // Optional structured value: plug a `dict` (or variable) block here to
      // give the variable a mapping/variable value without typing YAML — it
      // overrides the text field above when connected (see ansibleGenerator
      // valueBlockToValue). "field for scalars, block for structure."
      this.appendValueInput('VALUE_BLOCK').setCheck(VALUE_CHECK).appendField('or');
      this.setPreviousStatement(true, 'Var');
      this.setNextStatement(true, 'Var');
      this.setColour(65);
      this.setTooltip(
        'Defines one play-level variable (an entry in vars:). Plain text is ' +
        'kept as a string; numbers/lists/mappings can be entered as YAML ' +
        '(e.g. a comma list or one "- item" per line). For a dict/variable ' +
        'value, plug a block into "or".'
      );
    },
  };

  Blockly.Blocks.role_use = {
    init() {
      this.appendDummyInput()
        .appendField('role:')
        .appendField(new Blockly.FieldTextInput('role name'), 'ROLE_NAME');
      this.appendDummyInput()
        .appendField('vars (optional):');
      this.appendDummyInput()
        .appendField(new FieldMultilineInput(''), 'VARS');
      this.setPreviousStatement(true, 'Role');
      this.setNextStatement(true, 'Role');
      this.setColour(290);
      this.setTooltip(
        'Applies a project role to this play (equivalent to an entry in ' +
        'the roles: list). "vars" holds optional role variables as inline YAML.'
      );
    },
  };

  // Escape hatch: preserves any task shape not covered by a typed module
  // block — critical for lossless import of existing YAML (unrecognized
  // modules, block:/rescue:/always:, or task-level keys we don't model).
  Blockly.Blocks.raw_task = {
    init() {
      this.appendDummyInput().appendField('raw task (unrecognized shape)');
      this.appendDummyInput().appendField(new FieldMultilineInput('debug:\n  msg: unrecognized'), 'RAW_YAML');
      this.setPreviousStatement(true, 'Task');
      this.setNextStatement(true, 'Task');
      this.setColour(0);
      this.setTooltip('Fallback block: holds raw task YAML verbatim (round-trip safety).');
    },
  };

  // Whole-FILE escape hatch for a role's tasks/handlers/defaults/vars
  // section: created by the importer (never dragged from the toolbox — like
  // cond_raw, it's programmatic-only) when a file's content fails to parse
  // at all, e.g. Ansible's `!unsafe`/`!vault` YAML tags (unknown to js-yaml's
  // default schema) or an unexpected top-level shape. Without this, such a
  // section used to come up looking empty (silently swallowed by the
  // open-role catch block) — and worse, hitting "Lint & Save" would then
  // overwrite the real file with an empty stub. No previous/next connection:
  // it floats alone as the section's sole content, standing in for the
  // entire file rather than one item within it.
  Blockly.Blocks.raw_section = {
    init() {
      this.appendDummyInput().appendField("raw file (couldn't be parsed into blocks)");
      this.appendDummyInput().appendField(new FieldMultilineInput(''), 'RAW_YAML');
      this.setColour(0);
      this.setTooltip(
        "This file's content is preserved here verbatim because it couldn't be broken " +
        'down into blocks — commonly an Ansible !unsafe/!vault YAML tag, which js-yaml ' +
        "doesn't know natively. Nothing is lost: edit the raw YAML directly, or fix it " +
        'in the raw file editor and reopen. Saving re-emits this text unchanged.'
      );
    },
  };
}

// Condition ("when:") blocks — value-returning blocks that compose into a
// Jinja boolean expression, so `when:` is built visually (drag/drop
// comparisons, and/or/not, "is" tests) instead of hand-typed Jinja text.
// cond_var/cond_literal have no output check (`null`) so they can plug
// directly into a WHEN slot too — Ansible allows a bare truthy variable as
// `when: some_flag`, same as any of the boolean-producing blocks below.
export const COND_TEST_NAMES = [
  ['defined', 'defined'],
  ['undefined', 'undefined'],
  ['none', 'none'],
  ['true', 'true'],
  ['false', 'false'],
  ['changed', 'changed'],
  ['failed', 'failed'],
  ['success', 'success'],
  ['skipped', 'skipped'],
];

function defineConditionBlocks() {
  Blockly.Blocks.cond_var = {
    init() {
      this.appendDummyInput()
        .appendField('var')
        .appendField(new Blockly.FieldTextInput('foo'), 'NAME');
      this.setOutput(true, null);
      this.setColour(65);
      this.setTooltip(
        "A variable/fact reference, e.g. foo, motd_contents.stdout, " +
        "ansible_facts['distribution']. Emitted verbatim (no {{ }})."
      );
    },
  };

  Blockly.Blocks.cond_literal = {
    init() {
      this.appendDummyInput()
        .appendField('value')
        .appendField(new Blockly.FieldTextInput(''), 'VALUE');
      this.setOutput(true, null);
      this.setColour(65);
      this.setTooltip(
        'A literal value — plain numbers/true/false are emitted unquoted, ' +
        'anything else is quoted as a string (e.g. Debian → \'Debian\').'
      );
    },
  };

  Blockly.Blocks.cond_compare = {
    init() {
      this.appendValueInput('LEFT').appendField('compare');
      this.appendDummyInput().appendField(
        new Blockly.FieldDropdown([
          ['==', '=='], ['!=', '!='], ['>', '>'], ['<', '<'], ['>=', '>='], ['<=', '<='],
          ['in', 'in'], ['not in', 'not in'],
        ]),
        'OP'
      );
      this.appendValueInput('RIGHT');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(210);
      this.setTooltip("Compares two values, e.g. ansible_facts['distribution'] == 'Debian'.");
    },
  };

  Blockly.Blocks.cond_test = {
    init() {
      this.appendValueInput('SUBJECT').appendField('check');
      this.appendDummyInput()
        .appendField('is')
        .appendField(new Blockly.FieldCheckbox('FALSE'), 'NEGATE')
        .appendField('not')
        .appendField(new Blockly.FieldDropdown(COND_TEST_NAMES), 'TEST');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(210);
      this.setTooltip(
        'A Jinja "is" test, e.g. foo is defined, task_result is failed ' +
        '(tick the checkbox for "is not …").'
      );
    },
  };

  Blockly.Blocks.cond_not = {
    init() {
      this.appendValueInput('A').setCheck(COND_CHECK).appendField('not');
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(230);
      this.setTooltip('Negates a condition.');
    },
  };

  Blockly.Blocks.cond_logic = {
    init() {
      this.appendValueInput('A').setCheck(COND_CHECK);
      this.appendDummyInput().appendField(
        new Blockly.FieldDropdown([['and', 'and'], ['or', 'or']]),
        'OP'
      );
      this.appendValueInput('B').setCheck(COND_CHECK);
      this.setInputsInline(true);
      this.setOutput(true, COND_CHECK);
      this.setColour(230);
      this.setTooltip('Combines two conditions with and/or — chain multiple blocks for more than two.');
    },
  };

  // Escape hatch: preserves any when: expression the parser couldn't
  // decompose into the blocks above — same lossless-fallback pattern as
  // raw_task for whole tasks.
  Blockly.Blocks.cond_raw = {
    init() {
      this.appendDummyInput().appendField('raw condition (unrecognized expression)');
      this.appendDummyInput().appendField(new FieldMultilineInput(''), 'EXPR');
      this.setOutput(true, COND_CHECK);
      this.setColour(0);
      this.setTooltip('Fallback: holds a when: expression verbatim that could not be decomposed into blocks.');
    },
  };
}

// Structured-value blocks (dict; later also list). A `dict` is an ordered
// chain of `dict_entry` (key→value) blocks and outputs VALUE_CHECK so it fits
// a variable's value or a dict-typed module param — never a when: condition.
function defineValueBlocks() {
  Blockly.Blocks.dict = {
    init() {
      this.appendDummyInput().appendField('dict');
      this.appendStatementInput('ENTRIES').setCheck(DICT_ENTRY_CHECK);
      this.setOutput(true, VALUE_CHECK);
      this.setColour(160);
      this.setTooltip(
        'A dictionary (key→value mapping). Chain "entry" blocks inside; each ' +
        'value can be typed text, a variable (var block → {{ … }}), or a ' +
        'nested dict.'
      );
    },
  };

  // One key→value pair. The value is a typed scalar by default (VALUE text
  // field); plugging a value block (variable / nested dict) into VALUE_BLOCK
  // overrides it — same "field for scalars, block for structure" pattern as
  // define_var.
  Blockly.Blocks.dict_entry = {
    init() {
      this.appendDummyInput()
        .appendField(new Blockly.FieldTextInput('key'), 'KEY')
        .appendField(':')
        .appendField(new FieldMultilineInput(''), 'VALUE');
      this.appendValueInput('VALUE_BLOCK').setCheck(VALUE_CHECK).appendField('or');
      this.setInputsInline(true);
      this.setPreviousStatement(true, DICT_ENTRY_CHECK);
      this.setNextStatement(true, DICT_ENTRY_CHECK);
      this.setColour(160);
      this.setTooltip(
        'One key→value pair. Type a scalar value, or plug a variable/dict ' +
        'block into "or" for a variable reference or a nested dict.'
      );
    },
  };

  // A list (sequence of values) — same "value block with a statement chain
  // inside" shape as `dict`, just with unkeyed items. Fits anywhere a `dict`
  // does (define_var's value, a dict_entry's value, a list-typed module
  // param like apt.name), and can itself hold nested dicts/lists/variables.
  Blockly.Blocks.list = {
    init() {
      this.appendDummyInput().appendField('list');
      this.appendStatementInput('ITEMS').setCheck(LIST_ITEM_CHECK);
      this.setOutput(true, VALUE_CHECK);
      this.setColour(200);
      this.setTooltip(
        'A list (ordered sequence of values). Chain "item" blocks inside; ' +
        'each item can be typed text, a variable (var block → {{ … }}), or ' +
        'a nested dict/list.'
      );
    },
  };

  // One list entry. Same "field for scalars, block for structure" pattern as
  // dict_entry, minus the key.
  Blockly.Blocks.list_item = {
    init() {
      this.appendDummyInput().appendField(new FieldMultilineInput(''), 'VALUE');
      this.appendValueInput('VALUE_BLOCK').setCheck(VALUE_CHECK).appendField('or');
      this.setInputsInline(true);
      this.setPreviousStatement(true, LIST_ITEM_CHECK);
      this.setNextStatement(true, LIST_ITEM_CHECK);
      this.setColour(200);
      this.setTooltip(
        'One list item. Type a scalar value, or plug a variable/dict/list ' +
        'block into "or".'
      );
    },
  };
}

export const CONDITION_BLOCK_TYPES = [
  'cond_var', 'cond_literal', 'cond_compare', 'cond_test', 'cond_not', 'cond_logic', 'cond_raw',
];

export const TASK_SETTING_BLOCK_TYPES = ENVELOPE_FIELDS.map((e) => settingBlockType(e.key));

export const DATA_BLOCK_TYPES = ['dict', 'dict_entry', 'list', 'list_item'];

export function registerBlocks() {
  defineStaticBlocks();
  defineModuleBlocks();
  defineConditionBlocks();
  defineTaskSettingBlocks();
  defineValueBlocks();
}

export { moduleBlockType };
export const MODULE_NAMES = moduleCatalog.map((m) => m.short_name);
