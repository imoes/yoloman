import * as Blockly from 'blockly';
import { ArgFieldSpec, getArgspec, subscribeArgspec } from './argspec-bridge';
import { COND_CHECK, registerConditionBlocks } from './conditions';

/**
 * Runbook block definitions (ported from ansible-manager's playbookBuilder/
 * blocks.js, adapted to Bossman runbooks). A runbook is a LINEAR list of steps
 * (no play/role wrapper), so the step block chains via previous/nextStatement.
 *
 * ONE dynamic `runbook_module` block represents a step. Its module is a field;
 * when set, it renders one TYPED field per option from the module's argspec
 * (bool→checkbox, choices→dropdown, else→text), plus an "add parameter…"
 * dropdown for the rest — the same shape as the reference's per-module blocks,
 * but driven by the runtime argspec (see argspec-bridge). Arg values live in
 * `values_` (the source of truth) and are persisted in the block's extra state,
 * so they survive rebuilds and the async argspec arriving late.
 */
export const STEP_CHECK = 'Step';
const HUE_STEP = 210;

interface RunbookModuleBlock extends Blockly.Block {
  values_: Record<string, string>;   // arg key -> stringified value (source of truth)
  shown_: string[];                   // arg keys currently rendered as rows
  moduleName_: string;
  captureValues_(): void;
  rebuildArgs_(): void;
  setModuleName_(m: string): void;
  addParam_(key: string): void;
  importArgs_(module: string, args: Record<string, unknown>): void;
}

const ARG_PREFIX = 'ARGROW_';

let registered = false;

export function registerRunbookBlocks(): void {
  if (registered) return;   // Blockly.Blocks is a global registry — define once
  registered = true;
  registerConditionBlocks();   // the cond_* blocks that plug into a step's `when`

  Blockly.Blocks['runbook_module'] = {
    init(this: RunbookModuleBlock) {
      this.values_ = {};
      this.shown_ = [];
      this.moduleName_ = '';
      this.appendDummyInput('HEAD').appendField('step');
      this.appendDummyInput('NAMEROW')
        .appendField('name')
        .appendField(new Blockly.FieldTextInput(''), 'NAME');
      this.appendDummyInput('MODROW')
        .appendField('module')
        .appendField(new Blockly.FieldTextInput('', (v: string) => {
          // Commit-time (blur/enter), not per keystroke. Defer the mutation out
          // of the field-change event; skip when unchanged (e.g. during load) and
          // for flyout/preview blocks (a toolbox category full of MODULE-preset
          // blocks would otherwise fire one argspec load each on open).
          if (v !== this.moduleName_ && !this.isInFlyout) setTimeout(() => this.setModuleName_(v), 0);
          return v;
        }), 'MODULE');
      // arg rows + the "add parameter" row are inserted here, before FLOWHDR.
      this.appendDummyInput('FLOWHDR').appendField('— flow —');
      // `when` is a visual condition: a cond_* block plugs into this socket
      // (build/edit it from the Conditions toolbox category). Empty = no when.
      this.appendValueInput('WHEN').setCheck(COND_CHECK).appendField('when');
      this.appendDummyInput('LOOPROW').appendField('loop').appendField(new Blockly.FieldTextInput(''), 'LOOP');
      this.appendDummyInput('REGROW').appendField('register').appendField(new Blockly.FieldTextInput(''), 'REGISTER');
      this.appendDummyInput('IGNROW').appendField('ignore errors').appendField(new Blockly.FieldCheckbox('FALSE'), 'IGNORE');
      this.setPreviousStatement(true, STEP_CHECK);
      this.setNextStatement(true, STEP_CHECK);
      this.setColour(HUE_STEP);
      this.setTooltip('One runbook step: a module and its typed options, plus flow controls.');
    },

    /** Pull the current arg field values back into values_ (before a rebuild or
     * serialize) so edits aren't lost when the rows are recreated. */
    captureValues_(this: RunbookModuleBlock): void {
      for (const key of this.shown_) {
        const f = this.getField('ARG_' + key);
        if (f) this.values_[key] = String(f.getValue() ?? '');
      }
    },

    setModuleName_(this: RunbookModuleBlock, m: string): void {
      this.captureValues_();
      this.moduleName_ = m;
      const spec = getArgspec(m);
      if (spec === undefined) subscribeArgspec(m, () => this.rebuildArgs_());
      const required = (spec ?? []).filter((s) => s.required).map((s) => s.key);
      // keep any keys the user already filled, add the module's required ones
      this.shown_ = Array.from(new Set([...required, ...Object.keys(this.values_)]));
      this.rebuildArgs_();
    },

    addParam_(this: RunbookModuleBlock, key: string): void {
      if (key && !this.shown_.includes(key)) {
        this.captureValues_();
        this.shown_.push(key);
        this.rebuildArgs_();
      }
    },

    /** (Re)render the arg rows from values_/shown_ + the module argspec. */
    rebuildArgs_(this: RunbookModuleBlock): void {
      this.captureValues_();
      for (const inp of [...this.inputList]) {
        if (inp.name && (inp.name.startsWith(ARG_PREFIX) || inp.name === 'ADDROW')) {
          this.removeInput(inp.name, true);
        }
      }
      const spec = getArgspec(this.moduleName_);
      const byKey = new Map<string, ArgFieldSpec>((spec ?? []).map((s) => [s.key, s]));
      for (const key of this.shown_) {
        const s = byKey.get(key);
        const val = this.values_[key] ?? (s?.default != null ? String(s.default) : '');
        let field: Blockly.Field;
        if (s && (s.type === 'bool' || s.type === 'boolean')) {
          field = new Blockly.FieldCheckbox(/^(true|yes|on|1)$/i.test(val) ? 'TRUE' : 'FALSE');
        } else if (s && Array.isArray(s.choices) && s.choices.length) {
          const opts: [string, string][] = [['(unset)', '']];
          for (const c of s.choices) opts.push([String(c), String(c)]);
          const dd = new Blockly.FieldDropdown(opts);
          try { if (val) dd.setValue(val); } catch { /* value not in choices — leave unset */ }
          field = dd;
        } else {
          field = new Blockly.FieldTextInput(val);
        }
        (field as unknown as { setValidator(fn: (v: unknown) => unknown): void })
          .setValidator((v: unknown) => { this.values_[key] = String(v ?? ''); return v; });
        this.appendDummyInput(ARG_PREFIX + key)
          .appendField(key + (s?.required ? ' *' : ''))
          .appendField(field, 'ARG_' + key);
        this.moveInputBefore(ARG_PREFIX + key, 'FLOWHDR');
      }
      // "add parameter…" dropdown of not-yet-shown argspec keys.
      const addable = (spec ?? []).map((s) => s.key).filter((k) => !this.shown_.includes(k));
      const opts: [string, string][] = [['+ add parameter…', '']];
      for (const k of addable) opts.push([k, k]);
      this.appendDummyInput('ADDROW').appendField(
        new Blockly.FieldDropdown(opts, (v: string) => {
          if (v) setTimeout(() => this.addParam_(v), 0);
          return '';   // snap back to the placeholder
        }),
        'ADD_PARAM',
      );
      this.moveInputBefore('ADDROW', 'FLOWHDR');
    },

    importArgs_(this: RunbookModuleBlock, module: string, args: Record<string, unknown>): void {
      this.moduleName_ = module;
      this.setFieldValue(module, 'MODULE');   // moduleName_ already set → validator no-ops
      this.values_ = {};
      for (const [k, v] of Object.entries(args ?? {})) {
        this.values_[k] = v != null && typeof v === 'object' ? JSON.stringify(v) : String(v);
      }
      this.shown_ = Object.keys(this.values_);
      this.rebuildArgs_();
      if (getArgspec(module) === undefined) subscribeArgspec(module, () => this.rebuildArgs_());
    },

    saveExtraState(this: RunbookModuleBlock) {
      this.captureValues_();
      return { module: this.moduleName_, shown: this.shown_.slice(), values: { ...this.values_ } };
    },

    loadExtraState(this: RunbookModuleBlock, state: { module?: string; shown?: string[]; values?: Record<string, string> }) {
      this.moduleName_ = state.module || '';
      this.setFieldValue(this.moduleName_, 'MODULE');   // moduleName_ set first → validator no-ops
      this.values_ = { ...(state.values || {}) };
      this.shown_ = (state.shown || []).slice();
      this.rebuildArgs_();
      if (this.moduleName_ && getArgspec(this.moduleName_) === undefined) {
        subscribeArgspec(this.moduleName_, () => this.rebuildArgs_());
      }
    },
  };
}
