/**
 * Stress test for the blueprint logic — drives the REAL editor modules (compose-io,
 * compose-resolver, compose-wiring) headlessly over EVERY config template in
 * configs/config_templates, building deliberately nasty deployment plans.
 *
 * Run:  npx esbuild scripts/stress-blueprint.ts --bundle --platform=node --format=esm \
 *         --outfile=/tmp/stress.mjs && node /tmp/stress.mjs
 *
 * The point is not "does it run" but "where does the model lie". Each check below
 * exists because it can plausibly break: service names derived from real template
 * names (dots, digits, capitals, collisions), env keys derived from those names,
 * YAML's type coercion (the Norway problem — `no` becomes false), deep dependency
 * chains, fan-in/fan-out, cycles, renames that must rewrite every reference, and
 * unwiring that must remove exactly what an edge added.
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import yaml from 'js-yaml';
import { BlueprintService, envPrefix, isValidEnvName, sanitizeServiceName } from '../src/app/features/blueprint/compose-model';
import { fromComposeText, toComposeJson, toComposeYaml } from '../src/app/features/blueprint/compose-io';
import { resolveService, startOrder } from '../src/app/features/blueprint/compose-resolver';
import { openRequirements, removeService, renameService, unwireEdge, wireEdge } from '../src/app/features/blueprint/compose-wiring';

const TEMPLATES = '/home/mutkluge/Dev/code/yolo-man/configs/config_templates';

interface Finding { kind: string; detail: string }
const findings: Finding[] = [];
const note = (kind: string, detail: string) => findings.push({ kind, detail });

// ---------------------------------------------------------------- templates

interface Tpl { name: string; schema: Record<string, { type?: string; default?: unknown; enum?: unknown[] }> }

function loadTemplates(): Tpl[] {
  const out: Tpl[] = [];
  for (const d of readdirSync(TEMPLATES)) {
    const dir = join(TEMPLATES, d);
    try {
      if (!statSync(dir).isDirectory()) continue;
      const schema = JSON.parse(readFileSync(join(dir, 'schema.json'), 'utf8'));
      if (schema && typeof schema === 'object') out.push({ name: d, schema });
    } catch { /* no schema.json / unreadable: not a usable template */ }
  }
  return out;
}

/** Turn a template's schema into an environment map the way the editor's
 * param-form → setValues path would (defaults, stringified). */
function envFromSchema(t: Tpl): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, spec] of Object.entries(t.schema)) {
    let d: unknown = spec?.default;
    if (d && typeof d === 'object' && !Array.isArray(d) && 'value' in (d as object)) {
      d = (d as { value: unknown }).value;                    // the {value,description} convention
    }
    if (d === undefined || d === null || d === '') d = (spec?.enum?.[0] ?? 'x');
    env[k] = typeof d === 'object' ? JSON.stringify(d) : String(d);
  }
  return env;
}

function svc(name: string, t: Tpl | null, i: number, kind: 'native' | 'docker'): BlueprintService {
  return {
    name, kind,
    icon: kind === 'docker' ? 'container' : 'server',
    role: t ? `install-${t.name}` : undefined,
    template: t?.name,
    image: kind === 'docker' ? 'img:1' : undefined,
    host: i % 3 === 0 ? 'docker-test' : undefined,          // some placed, some not
    address: i % 5 === 0 ? `10.0.0.${(i % 250) + 1}` : undefined,
    // schema data is ALWAYS template directives, whatever tier renders it;
    // `environment` is reserved for real env vars (wiring + hand-typed)
    environment: {},
    values: t ? envFromSchema(t) : {},
    ports: i % 4 === 0 ? [`${8000 + i}:${80 + (i % 20)}`] : [],
    dependsOn: [], bindings: {},
    x: 100 + (i % 6) * 180, y: 100 + Math.floor(i / 6) * 160,
  };
}

// ---------------------------------------------------------------- checks

/** The blueprint JSON is the source of truth, so it MUST round-trip exactly. */
function checkJsonRoundTrip(label: string, services: BlueprintService[]): void {
  const bp = { name: 'stress', services };
  const a = toComposeJson(bp);
  let back;
  try { back = fromComposeText(a); } catch (e) { note('json-import-throws', `${label}: ${(e as Error).message}`); return; }
  const b = toComposeJson(back);
  if (a !== b) {
    // find the first differing service for a usable report
    const A = JSON.parse(a).services as Record<string, unknown>;
    const B = JSON.parse(b).services as Record<string, unknown>;
    const bad = Object.keys(A).find((k) => JSON.stringify(A[k]) !== JSON.stringify(B[k]));
    const detail = bad
      ? `${label}: service "${bad}"\n      out: ${JSON.stringify(A[bad]).slice(0, 220)}\n      in : ${JSON.stringify(B[bad]).slice(0, 220)}`
      : `${label}: service SET differs (${Object.keys(A).length} → ${Object.keys(B).length})`;
    note('json-roundtrip', detail);
  }
}

/** The clean YAML deliberately drops meta, but the COMPOSE content (env/ports/
 * depends_on) must survive — that is what you hand to docker. */
function checkYamlContent(label: string, services: BlueprintService[]): void {
  const bp = { name: 'stress', services };
  let doc;
  try { doc = yaml.load(toComposeYaml(bp)) as { services?: Record<string, { environment?: Record<string, unknown> }> }; }
  catch (e) { note('yaml-dump-or-load-throws', `${label}: ${(e as Error).message}`); return; }
  for (const s of services) {
    const got = doc?.services?.[s.name];
    if (!got) { note('yaml-service-missing', `${label}: ${s.name}`); continue; }
    for (const [k, v] of Object.entries(s.environment)) {
      const back = got.environment?.[k];
      if (back === undefined) { note('yaml-env-key-lost', `${label}: ${s.name}.${k}`); continue; }
      if (String(back) !== v) {
        note('yaml-env-value-changed',
          `${label}: ${s.name}.${k}  "${v}" → ${JSON.stringify(back)} (${typeof back})`);
      }
    }
  }
}

function checkNames(tpls: Tpl[]): void {
  const seen = new Map<string, string>();
  for (const t of tpls) {
    const n = sanitizeServiceName(t.name);
    if (!n) { note('name-empty', `template "${t.name}" sanitises to ""`); continue; }
    const prev = seen.get(n);
    if (prev && prev !== t.name) note('name-collision', `"${prev}" + "${t.name}" → both "${n}"`);
    else seen.set(n, t.name);
    const p = envPrefix(n);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(p)) {
      note('env-prefix-invalid', `service "${n}" → "${p}_HOST" is not a valid env var name`);
    }
  }
}

/** A template's schema field becomes an `environment:` key — but a mined config
 * schema is keyed by DIRECTIVE, and directives are not env-var names (lvm.conf has
 * `devices.sysfs_scan`). Anything invalid here would be written into a compose file
 * that no runtime can actually apply. */
function checkSchemaKeysAsEnv(tpls: Tpl[]): void {
  let directiveish = 0;
  for (const t of tpls) {
    for (const k of Object.keys(t.schema)) if (!isValidEnvName(k)) directiveish++;
  }
  console.log(`Schema-Felder, die KEIN gültiger Env-Name sind: ${directiveish} ` +
              `(müssen als Template-Direktiven in x-yolo-values landen, nicht in environment)`);

  // The invariant that matters: whatever we emit into `environment` must be applicable.
  const natives = tpls.slice(0, 400).map((t, i) => svc(sanitizeServiceName(t.name) || `n${i}`, t, i, 'native'));
  const dockers = tpls.slice(0, 400).map((t, i) => svc(`d${i}`, t, i, 'docker'));
  for (const s of [...natives, ...dockers]) {
    const bad = Object.keys(s.environment).filter((k) => !isValidEnvName(k));
    if (bad.length) note('env-holds-directive', `${s.name} (${s.kind}): ${bad.slice(0, 3).join(', ')}`);
  }
  // and a native's directives must survive as values
  const lost = natives.filter((s) => Object.keys(s.values).length === 0 && Object.keys(tpls.find((t) => `install-${t.name}` === s.role)?.schema ?? {}).length > 0);
  if (lost.length) note('values-lost', `${lost.length} native Dienste ohne Template-Werte`);
}

/** Values that YAML likes to reinterpret. If any of these change across a dump/load
 * cycle, a rendered config would silently differ from what was authored. */
const NASTY: [string, string][] = [
  ['norway', 'no'], ['norway2', 'yes'], ['bool', 'true'], ['off', 'off'],
  ['num_leading_zero', '0755'], ['num_octalish', '0o755'], ['version', '1.10'],
  ['colon_space', 'key: value'], ['hash', 'a # b'], ['star', '*all'], ['amp', '&anchor'],
  ['pct', 'postgresql-%Y-%m-%d_%H%M%S.log'], ['tilde', '~'], ['null_word', 'null'],
  ['empty_braces', '{}'], ['dash', '- item'], ['multiline', 'line1\nline2'],
  ['trailing_space', 'v '], ['leading_space', ' v'], ['quote', 'it\'s "x"'],
  ['tab', 'a\tb'], ['unicode', 'grüß-øß-日本'], ['dollar', '${NOT_A_REF_}'],
  ['long', 'x'.repeat(500)], ['docstart', '---'], ['at', '@reboot'], ['backtick', '`cmd`'],
];

function checkNastyValues(): void {
  const s0: BlueprintService = {
    name: 'nasty', kind: 'native', icon: 'server',
    environment: Object.fromEntries(NASTY), values: Object.fromEntries(NASTY),
    ports: [], dependsOn: [], bindings: {}, x: 0, y: 0,
  };
  checkJsonRoundTrip('nasty', [s0]);
  checkYamlContent('nasty', [s0]);
}

// ---------------------------------------------------------------- plans

function planChain(tpls: Tpl[], n: number, offset: number): BlueprintService[] {
  // a → b → c … : the deepest dependency the topological sort must handle
  let list = tpls.slice(offset, offset + n).map((t, i) => svc(`s${i}`, t, i, i % 2 ? 'docker' : 'native'));
  for (let i = 0; i < list.length - 1; i++) {
    const r = wireEdge(list, `s${i}`, `s${i + 1}`);
    if (r.error) note('wire-refused', `chain s${i}→s${i + 1}: ${r.error}`);
    list = r.services;
  }
  return list;
}

function planFan(tpls: Tpl[], n: number, offset: number): BlueprintService[] {
  // one consumer depending on n providers, and n consumers on one provider
  let list = tpls.slice(offset, offset + n + 1).map((t, i) => svc(`f${i}`, t, i, 'native'));
  for (let i = 1; i <= n; i++) {
    let r = wireEdge(list, 'f0', `f${i}`);
    if (r.error) note('wire-refused', `fan f0→f${i}: ${r.error}`);
    list = r.services;
  }
  return list;
}

function planCycle(tpls: Tpl[]): { services: BlueprintService[]; expect: boolean } {
  let list = tpls.slice(0, 3).map((t, i) => svc(`c${i}`, t, i, 'native'));
  for (const [a, b] of [['c0', 'c1'], ['c1', 'c2'], ['c2', 'c0']]) {
    const r = wireEdge(list, a, b);
    if (r.error) note('wire-refused', `cycle ${a}→${b}: ${r.error}`);
    list = r.services;
  }
  return { services: list, expect: true };
}

// ---------------------------------------------------------------- run

const tpls = loadTemplates();
console.log(`Templates mit schema.json: ${tpls.length}`);
const totalFields = tpls.reduce((a, t) => a + Object.keys(t.schema).length, 0);
console.log(`Schema-Felder insgesamt:   ${totalFields}`);

checkNames(tpls);
checkSchemaKeysAsEnv(tpls);
checkNastyValues();

// 1) EVERY template as one service in one giant plan
const mega = tpls.map((t, i) => svc(sanitizeServiceName(t.name) || `t${i}`, t, i, i % 3 === 0 ? 'docker' : 'native'));
const uniqueMega = mega.filter((s, i, arr) => arr.findIndex((o) => o.name === s.name) === i);
console.log(`Mega-Plan: ${uniqueMega.length} Dienste (nach Namens-Dedup von ${mega.length})`);
const t0 = Date.now();
checkJsonRoundTrip('mega', uniqueMega);
checkYamlContent('mega', uniqueMega);
const megaMs = Date.now() - t0;

// 2) many complex plans across the whole catalogue
let plans = 0;
for (let off = 0; off + 30 < tpls.length; off += 137) {
  const chain = planChain(tpls, 12, off);
  checkJsonRoundTrip(`chain@${off}`, chain);
  checkYamlContent(`chain@${off}`, chain);
  const ord = startOrder({ name: 'x', services: chain });
  if (ord.cycle.length) note('false-cycle', `chain@${off}: ${ord.cycle.join('→')}`);
  if (ord.order.length !== chain.length) note('order-incomplete', `chain@${off}: ${ord.order.length}/${chain.length}`);

  const fan = planFan(tpls, 8, off + 12);
  checkJsonRoundTrip(`fan@${off}`, fan);
  const fanOrd = startOrder({ name: 'x', services: fan });
  if (fanOrd.order[fanOrd.order.length - 1] !== 'f0') {
    note('order-wrong', `fan@${off}: consumer f0 is not last (${fanOrd.order.join('→')})`);
  }

  // resolver must never throw, and must flag what it cannot know
  for (const s of chain) {
    try { resolveService({ name: 'x', services: chain }, s); }
    catch (e) { note('resolver-throws', `chain@${off} ${s.name}: ${(e as Error).message}`); }
  }

  // wiring symmetry: unwire must restore the pre-wire environment exactly
  const before = JSON.stringify(chain.find((s) => s.name === 's0')!.environment);
  const w = wireEdge(chain, 's0', 's5');
  if (!w.error) {
    const u = unwireEdge(w.services, 's0', 's5');
    const after = JSON.stringify(u.find((s) => s.name === 's0')!.environment);
    if (before !== after) note('unwire-asymmetric', `chain@${off}: ${before.slice(0, 120)} vs ${after.slice(0, 120)}`);
  }

  // rename must rewrite every reference
  const rn = renameService(chain, 's5', 'renamed-5');
  if (rn.error) note('rename-refused', `chain@${off}: ${rn.error}`);
  else {
    const dangling = rn.services.filter((s) => s.dependsOn.includes('s5') || Object.values(s.bindings).includes('s5'));
    if (dangling.length) note('rename-dangling', `chain@${off}: ${dangling.map((s) => s.name).join(',')} still point at s5`);
    const stale = rn.services.filter((s) => Object.entries(s.bindings).some(([k]) => s.environment[k] === 's5'));
    if (stale.length) note('rename-stale-value', `chain@${off}: ${stale.map((s) => s.name).join(',')}`);
  }

  // deleting a provider must drop the edges AND the vars it wired
  const del = removeService(chain, 's5');
  const leftover = del.filter((s) => s.dependsOn.includes('s5') || Object.values(s.bindings).includes('s5'));
  if (leftover.length) note('remove-leftover', `chain@${off}: ${leftover.map((s) => s.name).join(',')}`);

  plans += 2;
}

const cyc = planCycle(tpls);
const cycOrd = startOrder({ name: 'x', services: cyc.services });
if (!cycOrd.cycle.length) note('cycle-undetected', 'a→b→c→a was not reported');

// ---- capability plausibility (require/provide) ------------------------------
// The editor must only allow an edge when the target provides a capability the source requires, and
// must report a placed role's unfilled requirements. Built with real archetype icons, not generic
// servers, so the seeded provides/requires actually bite.
{
  const cap = (name: string, icon: string): BlueprintService => ({
    name, kind: 'native', icon, environment: {}, values: {}, ports: [], dependsOn: [], bindings: {},
    x: 0, y: 0,
  });
  const web = cap('web', 'proxy');      // requires ['database'], provides ['web']
  const db = cap('db', 'database');     // provides ['database']
  const web2 = cap('web2', 'proxy');    // provides ['web'] — but NOT database
  const list = [web, db, web2];

  // Placing the web role must surface its open requirement.
  const open0 = openRequirements(web, list);
  if (open0.join() !== 'database') note('cap-open-wrong', `web open reqs = [${open0}], want [database]`);

  // Implausible: web needs a database, web2 offers only 'web' → refused.
  const bad = wireEdge(list, 'web', 'web2');
  if (!bad.error) note('cap-implausible-allowed', 'web→web2 was allowed but web2 provides no database');

  // Plausible: db provides 'database' → allowed, and then web has no open requirement left.
  const good = wireEdge(list, 'web', 'db');
  if (good.error) note('cap-plausible-refused', `web→db refused: ${good.error}`);
  else {
    const open1 = openRequirements(good.services.find((s) => s.name === 'web')!, good.services);
    if (open1.length) note('cap-open-after-wire', `web still open after db: [${open1}]`);
  }

  // A generic server (no requires) stays unconstrained — it may depend on anything.
  const srv = cap('srv', 'server');
  const free = wireEdge([srv, web2], 'srv', 'web2');
  if (free.error) note('cap-generic-constrained', `generic server refused an edge: ${free.error}`);
}

// ---------------------------------------------------------------- report

console.log(`Pläne geprüft: ${plans} (+ Mega-Plan in ${megaMs} ms) + 1 Zyklus-Plan\n`);
if (!findings.length) {
  console.log('KEINE Auffälligkeiten.');
} else {
  const byKind = new Map<string, Finding[]>();
  for (const f of findings) (byKind.get(f.kind) ?? byKind.set(f.kind, []).get(f.kind)!).push(f);
  console.log(`BEFUNDE: ${findings.length} in ${byKind.size} Kategorien\n`);
  for (const [kind, list] of [...byKind.entries()].sort((a, b) => b[1].length - a[1].length)) {
    console.log(`  ${kind}  (${list.length})`);
    for (const f of list.slice(0, 4)) console.log(`    - ${f.detail}`);
    if (list.length > 4) console.log(`    … ${list.length - 4} weitere`);
    console.log('');
  }
}
