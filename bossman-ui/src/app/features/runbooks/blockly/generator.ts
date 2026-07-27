import * as Blockly from 'blockly';
import { ArgFieldSpec, getArgspec } from './argspec-bridge';

/** The canonical runbook step shape (matches the backend /runbooks/lint doc and
 * the editor's DocStep). The Blockly workspace is walked into a list of these,
 * then the editor serializes them to NestedText — the "walk to an object tree,
 * don't string-concatenate" approach of the reference generator. */
export interface DocStep {
  name?: string;
  module: string;
  args?: Record<string, unknown>;
  when?: string;
  loop?: unknown;
  register?: string;
  ignore_errors?: boolean;
}

const ARG_PREFIX = 'ARGROW_';

/** Walk the workspace's top-to-bottom block chains into an ordered step list. */
export function workspaceToSteps(ws: Blockly.Workspace): DocStep[] {
  const steps: DocStep[] = [];
  for (const top of ws.getTopBlocks(true)) {
    let b: Blockly.Block | null = top;
    while (b) {
      if (b.type === 'runbook_module' && b.isEnabled()) steps.push(blockToStep(b));
      b = b.getNextBlock();
    }
  }
  return steps;
}

function blockToStep(b: Blockly.Block): DocStep {
  const module = (b.getFieldValue('MODULE') || '').trim();
  const step: DocStep = { module };
  const name = (b.getFieldValue('NAME') || '').trim();
  if (name) step.name = name;

  const byKey = new Map<string, ArgFieldSpec>((getArgspec(module) ?? []).map((s) => [s.key, s]));
  const args: Record<string, unknown> = {};
  for (const inp of b.inputList) {
    if (!inp.name || !inp.name.startsWith(ARG_PREFIX)) continue;
    const key = inp.name.slice(ARG_PREFIX.length);
    const coerced = coerceArg(String(b.getFieldValue('ARG_' + key) ?? ''), byKey.get(key));
    if (coerced !== undefined) args[key] = coerced;
  }
  if (Object.keys(args).length) step.args = args;

  const when = (b.getFieldValue('WHEN') || '').trim();
  if (when) step.when = when;
  const loop = (b.getFieldValue('LOOP') || '').trim();
  if (loop) step.loop = loop;
  const register = (b.getFieldValue('REGISTER') || '').trim();
  if (register) step.register = register;
  if (b.getFieldValue('IGNORE') === 'TRUE') step.ignore_errors = true;
  return step;
}

/** Field string → typed value, using the arg's declared type. Blank/false are
 * omitted (the reference's "don't emit empty/false" rule); a value that looks
 * like a JSON object/array is parsed so dict/list args keep their structure. */
function coerceArg(raw: string, spec: ArgFieldSpec | undefined): unknown {
  const t = spec?.type;
  if (t === 'bool' || t === 'boolean') return /^(true|yes|on|1)$/i.test(raw) ? true : undefined;
  const v = raw.trim();
  if (v === '') return undefined;
  if ((v.startsWith('{') && v.endsWith('}')) || (v.startsWith('[') && v.endsWith(']'))) {
    try { return JSON.parse(v); } catch { /* not JSON — fall through */ }
  }
  if (t === 'int') { const n = parseInt(v, 10); return Number.isNaN(n) ? raw : n; }
  if (t === 'float' || t === 'number') { const n = parseFloat(v); return Number.isNaN(n) ? raw : n; }
  return raw;
}
