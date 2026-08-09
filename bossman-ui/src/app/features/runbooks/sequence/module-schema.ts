import { ModuleOptionSpec } from '../../../core/models/module.model';
import { ParamSchema, ParamSpec } from '../../../shared/param-form/param-form.types';

/**
 * A module's argspec → the typed form schema `app-param-form` renders.
 *
 * This is the tie between slice 2 and slice 3 (docs/ui-workspaces.md): a step in the Sequence tree is a
 * Resource, its `schema()` is its module's argspec, and the form is generated from it — so the operator
 * fills real typed fields (with dropdowns for choices) instead of hand-writing JSON, and a newly
 * translated module gets a form for free.
 *
 * Pure on purpose, so the mapping is unit-testable without a browser.
 */

/** Ansible argspec types → the widget types param-form understands. */
function mapType(t: string | undefined): ParamSpec['type'] {
  switch ((t || '').toLowerCase()) {
    case 'int':
    case 'integer':
    case 'float':
      return 'number';
    case 'bool':
    case 'boolean':
      return 'bool';
    case 'list':
      return 'list';
    case 'dict':
    case 'json':
      return 'object';
    // 'str', 'path', 'raw', unknown, or absent — a text field is the honest default.
    default:
      return 'string';
  }
}

/** A description may be a string or Ansible's list-of-lines; the form wants one line. */
function mapDescription(d: string | string[] | undefined): string | undefined {
  if (!d) return undefined;
  return Array.isArray(d) ? d.join(' ') : d;
}

export function optionToParamSpec(opt: ModuleOptionSpec): ParamSpec {
  const spec: ParamSpec = { type: mapType(opt.type) };
  const desc = mapDescription(opt.description);
  if (desc) spec.description = desc;
  if (opt.default !== undefined) spec.default = opt.default;
  if (opt.required) spec.required = true;
  // `choices` is what turns a free-text field into a dropdown — the enum-coverage goal.
  if (Array.isArray(opt.choices) && opt.choices.length) spec.enum = opt.choices;
  return spec;
}

/**
 * The whole argspec → ParamSchema. Returns null when the module declares no options, so a caller can fall
 * back to raw editing rather than showing an empty form (a module the catalog does not know must still be
 * editable).
 */
export function optionsToParamSchema(options: Record<string, ModuleOptionSpec> | undefined | null): ParamSchema | null {
  if (!options) return null;
  const out: ParamSchema = {};
  for (const [name, opt] of Object.entries(options)) {
    if (!opt || typeof opt !== 'object') continue;
    out[name] = optionToParamSpec(opt);
  }
  return Object.keys(out).length ? out : null;
}

// ---- the agent's own registry ------------------------------------------------------------------

/**
 * The second schema source. Bossman's module library only holds the ~693 DISCOVERED collection modules —
 * the native Go builtins (`apt`, `service`, `command`, …) and the embedded `yoloman.*` modules live in the
 * agent, which publishes them as JSON Schema via `GET /api/v1/agents/{id}/tools` (`input_schema`). Convert
 * that too, so a step gets a typed form for those modules as well instead of raw JSON.
 */
interface JsonSchemaProp {
  type?: string | string[];
  description?: string;
  default?: unknown;
  enum?: unknown[];
}
interface JsonSchema {
  type?: string;
  properties?: Record<string, JsonSchemaProp>;
  required?: string[];
}

function mapJsonType(t: string | string[] | undefined): ParamSpec['type'] {
  // A union type (`["string","null"]`) is an optional string as far as a form is concerned.
  const first = Array.isArray(t) ? t.find((x) => x !== 'null') : t;
  switch ((first || '').toLowerCase()) {
    case 'boolean': return 'bool';
    case 'integer':
    case 'number': return 'number';
    case 'array': return 'list';
    case 'object': return 'object';
    default: return 'string';
  }
}

export function jsonSchemaToParamSchema(schema: JsonSchema | undefined | null): ParamSchema | null {
  const props = schema?.properties;
  if (!props) return null;
  const required = new Set(schema?.required ?? []);
  const out: ParamSchema = {};
  for (const [name, p] of Object.entries(props)) {
    if (!p || typeof p !== 'object') continue;
    // `dry_run` is the runtime's own check-mode switch, not a module argument — the runbook engine sets it.
    if (name === 'dry_run') continue;
    const spec: ParamSpec = { type: mapJsonType(p.type) };
    if (p.description) spec.description = p.description;
    if (p.default !== undefined) spec.default = p.default;
    if (Array.isArray(p.enum) && p.enum.length) spec.enum = p.enum;
    if (required.has(name)) spec.required = true;
    out[name] = spec;
  }
  return Object.keys(out).length ? out : null;
}
