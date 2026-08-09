// awx-ng: best-effort parser for Ansible `when:` Jinja expressions into the
// condition blocks defined in blocks.js (cond_var/cond_literal/cond_compare/
// cond_test/cond_not/cond_logic). Covers the documented common patterns:
// comparisons (== != > < >= <=), in/not in, and/or/not, "is [not] <test>",
// parentheses, and a bare truthy variable. Anything outside this grammar
// (filters like `| int`, list literals, function calls, string concat `~`,
// jinja templating braces, …) makes parseConditionExpr() return null so the
// caller falls back to a lossless cond_raw block holding the text verbatim —
// same escape-hatch pattern as raw_task for whole unrecognized tasks.
import { newBlock } from './blocklyUtil';

const KEYWORDS = { and: 'AND', or: 'OR', not: 'NOT', in: 'IN', is: 'IS' };
const TEST_NAMES = new Set([
  'defined', 'undefined', 'none', 'true', 'false', 'changed', 'failed', 'success', 'skipped',
]);

function isIdentStart(c) {
  return /[A-Za-z_]/.test(c);
}
function isIdentPart(c) {
  return /[A-Za-z0-9_]/.test(c);
}

// Hand-written tokenizer (not one giant regex) so the "extend an identifier
// through .dots and ['bracket'] segments" logic stays readable. Returns
// null on any character it doesn't recognize.
function tokenize(str) {
  const tokens = [];
  const n = str.length;
  let i = 0;
  while (i < n) {
    const c = str[i];
    if (/\s/.test(c)) { i += 1; continue; }
    if (c === '(') { tokens.push({ t: 'LPAREN' }); i += 1; continue; }
    if (c === ')') { tokens.push({ t: 'RPAREN' }); i += 1; continue; }
    if (str.startsWith('==', i)) { tokens.push({ t: 'OP', v: '==' }); i += 2; continue; }
    if (str.startsWith('!=', i)) { tokens.push({ t: 'OP', v: '!=' }); i += 2; continue; }
    if (str.startsWith('>=', i)) { tokens.push({ t: 'OP', v: '>=' }); i += 2; continue; }
    if (str.startsWith('<=', i)) { tokens.push({ t: 'OP', v: '<=' }); i += 2; continue; }
    if (c === '>') { tokens.push({ t: 'OP', v: '>' }); i += 1; continue; }
    if (c === '<') { tokens.push({ t: 'OP', v: '<' }); i += 1; continue; }
    if (c === "'" || c === '"') {
      const quote = c;
      let j = i + 1;
      let val = '';
      while (j < n && str[j] !== quote) {
        if (str[j] === '\\' && j + 1 < n) { val += str[j + 1]; j += 2; } else { val += str[j]; j += 1; }
      }
      if (j >= n) return null; // unterminated string literal
      tokens.push({ t: 'STRING', v: val });
      i = j + 1;
      continue;
    }
    if (/[0-9]/.test(c)) {
      let j = i + 1;
      while (j < n && /[0-9.]/.test(str[j])) j += 1;
      tokens.push({ t: 'NUMBER', v: str.slice(i, j) });
      i = j;
      continue;
    }
    if (isIdentStart(c)) {
      let j = i + 1;
      while (j < n && isIdentPart(str[j])) j += 1;
      const bareWord = str.slice(i, j);
      if (KEYWORDS[bareWord]) {
        tokens.push({ t: KEYWORDS[bareWord] });
        i = j;
        continue;
      }
      // Extend through .attr / ['key'] / [0] path segments so dotted/bracket
      // variable paths (ansible_facts['distribution'], motd.stdout) become a
      // single token — but only for words that AREN'T bare keywords/tests.
      let k = j;
      for (;;) {
        if (str[k] === '.' && isIdentStart(str[k + 1] || '')) {
          let m = k + 1;
          while (m < n && isIdentPart(str[m])) m += 1;
          k = m;
        } else if (str[k] === '[') {
          const close = str.indexOf(']', k);
          if (close === -1) break;
          k = close + 1;
        } else break;
      }
      const word = str.slice(i, k);
      if (k === j && TEST_NAMES.has(word)) {
        tokens.push({ t: 'TESTNAME', v: word });
      } else {
        tokens.push({ t: 'IDENT', v: word });
      }
      i = k;
      continue;
    }
    return null; // unrecognized character (filters, braces, operators we don't model, …)
  }
  return tokens;
}

// Recursive-descent parser over the token stream, following (roughly) Jinja/
// Python precedence: or < and < not < is-test < comparison < primary.
function parseTokens(tokens) {
  let pos = 0;
  const peek = () => tokens[pos];
  const advance = () => tokens[pos += 1] && tokens[pos - 1];

  function parseOr() {
    const left = parseAnd();
    if (left === null) return null;
    let node = left;
    while (peek() && peek().t === 'OR') {
      advance();
      const right = parseAnd();
      if (right === null) return null;
      node = { op: 'or', a: node, b: right };
    }
    return node;
  }
  function parseAnd() {
    const left = parseNot();
    if (left === null) return null;
    let node = left;
    while (peek() && peek().t === 'AND') {
      advance();
      const right = parseNot();
      if (right === null) return null;
      node = { op: 'and', a: node, b: right };
    }
    return node;
  }
  function parseNot() {
    if (peek() && peek().t === 'NOT') {
      advance();
      const inner = parseNot();
      if (inner === null) return null;
      return { op: 'not', a: inner };
    }
    return parseTest();
  }
  function parseTest() {
    const subject = parseCompare();
    if (subject === null) return null;
    if (peek() && peek().t === 'IS') {
      advance();
      let negate = false;
      if (peek() && peek().t === 'NOT') { negate = true; advance(); }
      const tok = peek();
      if (!tok || tok.t !== 'TESTNAME') return null;
      advance();
      return { op: 'test', subject, test: tok.v, negate };
    }
    return subject;
  }
  function parseCompare() {
    const left = parsePrimary();
    if (left === null) return null;
    const nxt = peek();
    if (nxt && nxt.t === 'OP') {
      advance();
      const right = parsePrimary();
      if (right === null) return null;
      return { op: 'compare', cmp: nxt.v, a: left, b: right };
    }
    if (nxt && nxt.t === 'IN') {
      advance();
      const right = parsePrimary();
      if (right === null) return null;
      return { op: 'compare', cmp: 'in', a: left, b: right };
    }
    if (nxt && nxt.t === 'NOT' && tokens[pos + 1] && tokens[pos + 1].t === 'IN') {
      advance(); advance();
      const right = parsePrimary();
      if (right === null) return null;
      return { op: 'compare', cmp: 'not in', a: left, b: right };
    }
    return left;
  }
  function parsePrimary() {
    const tok = peek();
    if (!tok) return null;
    if (tok.t === 'LPAREN') {
      advance();
      const inner = parseOr();
      if (inner === null) return null;
      if (!peek() || peek().t !== 'RPAREN') return null;
      advance();
      return inner;
    }
    // Tag the literal's original kind so an explicitly-quoted numeral (e.g.
    // "6", common for string-typed facts like distribution_major_version)
    // round-trips as a string, not a bare number — see astToBlock().
    if (tok.t === 'STRING') { advance(); return { op: 'literal', kind: 'string', v: tok.v }; }
    if (tok.t === 'NUMBER') { advance(); return { op: 'literal', kind: 'number', v: tok.v }; }
    if (tok.t === 'IDENT') { advance(); return { op: 'var', v: tok.v }; }
    // A bare test name outside "is …" (e.g. "when: true") is just a variable-
    // shaped truthy value from the generator's point of view.
    if (tok.t === 'TESTNAME') { advance(); return { op: 'var', v: tok.v }; }
    return null;
  }

  const result = parseOr();
  if (result === null || pos !== tokens.length) return null;
  return result;
}

// Public: string → AST (plain JS object) or null if unparseable. Exported
// mainly for focused unit tests independent of Blockly block construction.
export function parseConditionExpr(str) {
  const text = (str || '').trim();
  if (!text) return null;
  const tokens = tokenize(text);
  if (!tokens || !tokens.length) return null;
  return parseTokens(tokens);
}

function astToBlock(workspace, node) {
  switch (node.op) {
    case 'var': {
      const b = newBlock(workspace, 'cond_var');
      b.setFieldValue(node.v, 'NAME');
      return b;
    }
    case 'literal': {
      const b = newBlock(workspace, 'cond_literal');
      // A string-kind literal is stored WITH its quotes so the field itself
      // shows what will be emitted (and a plain 6-that-was-really-a-string
      // doesn't silently become an unquoted number on regeneration).
      b.setFieldValue(node.kind === 'string' ? `"${node.v}"` : node.v, 'VALUE');
      return b;
    }
    case 'compare': {
      const b = newBlock(workspace, 'cond_compare');
      b.setFieldValue(node.cmp, 'OP');
      b.getInput('LEFT').connection.connect(astToBlock(workspace, node.a).outputConnection);
      b.getInput('RIGHT').connection.connect(astToBlock(workspace, node.b).outputConnection);
      return b;
    }
    case 'test': {
      const b = newBlock(workspace, 'cond_test');
      b.setFieldValue(node.test, 'TEST');
      b.setFieldValue(node.negate ? 'TRUE' : 'FALSE', 'NEGATE');
      b.getInput('SUBJECT').connection.connect(astToBlock(workspace, node.subject).outputConnection);
      return b;
    }
    case 'not': {
      const b = newBlock(workspace, 'cond_not');
      b.getInput('A').connection.connect(astToBlock(workspace, node.a).outputConnection);
      return b;
    }
    case 'and':
    case 'or': {
      const b = newBlock(workspace, 'cond_logic');
      b.setFieldValue(node.op, 'OP');
      b.getInput('A').connection.connect(astToBlock(workspace, node.a).outputConnection);
      b.getInput('B').connection.connect(astToBlock(workspace, node.b).outputConnection);
      return b;
    }
    default:
      throw new Error(`conditionParser: unknown AST node op "${node.op}"`);
  }
}

// Public: string → Blockly block, NEVER null — falls back to a cond_raw
// block holding the text verbatim when it can't be decomposed (lossless).
export function parseConditionToBlock(workspace, exprText) {
  const ast = parseConditionExpr(exprText);
  if (ast) return astToBlock(workspace, ast);
  const raw = newBlock(workspace, 'cond_raw');
  raw.setFieldValue(exprText, 'EXPR');
  return raw;
}
