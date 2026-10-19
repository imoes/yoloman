#!/usr/bin/env node
// Lint: a Material ACTION button must not be natively [disabled] for a validation/precondition reason.
//
// A natively disabled button is not focusable and not announced, so the operator cannot learn WHY it is
// blocked (NN/g Button States, GOV.UK button guidance). The pattern instead: `[aria-disabled]="!!reason()"`
// (the Material INPUT, not [attr.aria-disabled]), keep (click) and return early in the handler, and put the
// reason text next to the button, linked by [attr.aria-describedby]. See deploy-vm-wizard.component.ts.
//
// The accepted exception (Carbon): a button disabled ONLY while a request is in flight. So every operand of
// the [disabled] expression (split on || and &&) must name a busy flag — busy, loading, saving, pending,
// running, inflight, … — or the button is reported as file:line. Exit 1 when anything is reported.
//
// No dependencies: node scripts/check-disabled-buttons.mjs   (npm run lint:disabled)

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(fileURLToPath(new URL('.', import.meta.url)), '..');
const SRC = join(ROOT, 'src');

// Paths owned by another work stream right now; their findings are still PRINTED (as "skipped") and
// counted, they just do not fail this check. Remove an entry once that stream has converted its buttons.
const SKIP = [
  'src/app/features/diagnosis/',
  'src/app/features/rollouts/',
];

// A word that names "a request is in flight". Matched case-insensitively against each operand.
const BUSY = /(busy|loading|saving|pending|running|inflight|in_flight|inFlight|submitting|deleting|applying|fetching|working|progress|probing|testing|refreshing|starting|stopping|restarting|installing|importing|exporting|uploading|downloading|deploying|syncing|generating|resolving|scanning|checking|sending|creating|removing|updating|validating|cloning|launching|rendering|streaming|polling|discovering|previewing|connecting|correcting)/i;

const MAT_BUTTON = /\b(mat-(?:button|flat-button|raised-button|stroked-button|icon-button|fab|mini-fab)|matButton|matIconButton|matFab|matMiniFab)\b/;

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (p.endsWith('.ts') && !p.endsWith('.spec.ts')) yield p;
  }
}

/** Every `<button …>` / `<a …>` start tag in the text, with the offset it starts at. Quote-aware, so a `>`
 *  inside an attribute value (`a > b`) does not end the tag. */
function* startTags(text) {
  const open = /<(button|a)\b/g;
  let m;
  while ((m = open.exec(text))) {
    let i = m.index + m[0].length;
    let quote = null;
    for (; i < text.length; i++) {
      const c = text[i];
      if (quote) { if (c === quote) quote = null; }
      else if (c === '"' || c === "'") quote = c;
      else if (c === '>') break;
    }
    yield { at: m.index, tag: text.slice(m.index, i + 1) };
  }
}

/** Split a template expression on top-level || and &&. */
function operands(expr) {
  return expr.split(/\|\||&&/).map((s) => s.trim()).filter(Boolean);
}

const lineOf = (text, offset) => text.slice(0, offset).split('\n').length;

const failing = [];
const skipped = [];
for (const file of walk(SRC)) {
  const text = readFileSync(file, 'utf8');
  const rel = relative(ROOT, file).split(sep).join('/');
  for (const { at, tag } of startTags(text)) {
    if (!MAT_BUTTON.test(tag)) continue;
    const d = /\[disabled\]\s*=\s*"([^"]*)"/.exec(tag);
    if (!d) continue;
    const bad = operands(d[1]).filter((op) => !BUSY.test(op));
    if (!bad.length) continue;
    const entry = `${rel}:${lineOf(text, at + d.index)}  [disabled]="${d[1]}"`;
    (SKIP.some((s) => rel.startsWith(s)) ? skipped : failing).push(entry);
  }
}

for (const e of failing) console.log(e);
if (skipped.length) {
  console.log(`\n${skipped.length} finding(s) in skipped paths (not failing; see SKIP in this script):`);
  for (const e of skipped) console.log(`  skipped  ${e}`);
}
if (failing.length) {
  console.log(`\n${failing.length} Material button(s) natively [disabled] for a non-busy reason.`);
  console.log('Use [aria-disabled]="!!reason()" + an early return in (click) + the reason next to the button,');
  console.log('linked by [attr.aria-describedby]. [disabled] is only for a request in flight (busy/loading/…).');
  process.exit(1);
}
console.log('check-disabled-buttons: OK — no Material button is natively disabled for a non-busy reason.');
