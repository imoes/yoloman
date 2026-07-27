import * as Blockly from 'blockly';
import { newBlock } from './util';

/**
 * Best-effort parser for a `when:` Jinja expression into the condition blocks
 * (cond_var/cond_literal/cond_compare/cond_test/cond_not/cond_logic). Covers the
 * common patterns: comparisons (== != > < >= <=), in/not in, and/or/not,
 * "is [not] <test>", parentheses, and a bare truthy variable. Anything outside
 * this grammar makes parseConditionExpr return null → the caller falls back to a
 * lossless cond_raw block holding the text verbatim. Ported from the reference
 * conditionParser.js.
 */

type Token =
  | { t: 'LPAREN' } | { t: 'RPAREN' } | { t: 'AND' } | { t: 'OR' } | { t: 'NOT' } | { t: 'IN' } | { t: 'IS' }
  | { t: 'OP'; v: string } | { t: 'STRING'; v: string } | { t: 'NUMBER'; v: string }
  | { t: 'IDENT'; v: string } | { t: 'TESTNAME'; v: string };

interface AstNode {
  op: 'var' | 'literal' | 'compare' | 'test' | 'not' | 'and' | 'or';
  v?: string; kind?: string; cmp?: string; test?: string; negate?: boolean;
  a?: AstNode; b?: AstNode; subject?: AstNode;
}

const KEYWORDS: Record<string, Token['t']> = { and: 'AND', or: 'OR', not: 'NOT', in: 'IN', is: 'IS' };
const TEST_NAMES = new Set(['defined', 'undefined', 'none', 'true', 'false', 'changed', 'failed', 'success', 'skipped']);

const isIdentStart = (c: string) => /[A-Za-z_]/.test(c);
const isIdentPart = (c: string) => /[A-Za-z0-9_]/.test(c);

function tokenize(str: string): Token[] | null {
  const tokens: Token[] = [];
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
      if (j >= n) return null;   // unterminated string
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
      if (KEYWORDS[bareWord]) { tokens.push({ t: KEYWORDS[bareWord] } as Token); i = j; continue; }
      // Extend through .attr / ['key'] / [0] so dotted/bracket paths are one token.
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
      tokens.push(k === j && TEST_NAMES.has(word) ? { t: 'TESTNAME', v: word } : { t: 'IDENT', v: word });
      i = k;
      continue;
    }
    return null;   // unrecognized character (filters, braces, …)
  }
  return tokens;
}

function parseTokens(tokens: Token[]): AstNode | null {
  let pos = 0;
  const peek = () => tokens[pos];
  const advance = () => { pos += 1; return tokens[pos - 1]; };

  function parseOr(): AstNode | null {
    let node = parseAnd();
    if (node === null) return null;
    while (peek() && peek().t === 'OR') {
      advance();
      const right = parseAnd();
      if (right === null) return null;
      node = { op: 'or', a: node, b: right };
    }
    return node;
  }
  function parseAnd(): AstNode | null {
    let node = parseNot();
    if (node === null) return null;
    while (peek() && peek().t === 'AND') {
      advance();
      const right = parseNot();
      if (right === null) return null;
      node = { op: 'and', a: node, b: right };
    }
    return node;
  }
  function parseNot(): AstNode | null {
    if (peek() && peek().t === 'NOT') {
      advance();
      const inner = parseNot();
      if (inner === null) return null;
      return { op: 'not', a: inner };
    }
    return parseTest();
  }
  function parseTest(): AstNode | null {
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
  function parseCompare(): AstNode | null {
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
  function parsePrimary(): AstNode | null {
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
    if (tok.t === 'STRING') { advance(); return { op: 'literal', kind: 'string', v: tok.v }; }
    if (tok.t === 'NUMBER') { advance(); return { op: 'literal', kind: 'number', v: tok.v }; }
    if (tok.t === 'IDENT') { advance(); return { op: 'var', v: tok.v }; }
    if (tok.t === 'TESTNAME') { advance(); return { op: 'var', v: tok.v }; }
    return null;
  }

  const result = parseOr();
  if (result === null || pos !== tokens.length) return null;
  return result;
}

/** string → AST or null if unparseable (exported for focused unit tests). */
export function parseConditionExpr(str: string): AstNode | null {
  const text = (str || '').trim();
  if (!text) return null;
  const tokens = tokenize(text);
  if (!tokens || !tokens.length) return null;
  return parseTokens(tokens);
}

function astToBlock(workspace: Blockly.Workspace, node: AstNode): Blockly.Block {
  switch (node.op) {
    case 'var': {
      const b = newBlock(workspace, 'cond_var');
      b.setFieldValue(node.v ?? '', 'NAME');
      return b;
    }
    case 'literal': {
      const b = newBlock(workspace, 'cond_literal');
      b.setFieldValue(node.kind === 'string' ? `"${node.v}"` : (node.v ?? ''), 'VALUE');
      return b;
    }
    case 'compare': {
      const b = newBlock(workspace, 'cond_compare');
      b.setFieldValue(node.cmp ?? '==', 'OP');
      b.getInput('LEFT')!.connection!.connect(astToBlock(workspace, node.a!).outputConnection!);
      b.getInput('RIGHT')!.connection!.connect(astToBlock(workspace, node.b!).outputConnection!);
      return b;
    }
    case 'test': {
      const b = newBlock(workspace, 'cond_test');
      b.setFieldValue(node.test ?? 'defined', 'TEST');
      b.setFieldValue(node.negate ? 'TRUE' : 'FALSE', 'NEGATE');
      b.getInput('SUBJECT')!.connection!.connect(astToBlock(workspace, node.subject!).outputConnection!);
      return b;
    }
    case 'not': {
      const b = newBlock(workspace, 'cond_not');
      b.getInput('A')!.connection!.connect(astToBlock(workspace, node.a!).outputConnection!);
      return b;
    }
    case 'and':
    case 'or': {
      const b = newBlock(workspace, 'cond_logic');
      b.setFieldValue(node.op, 'OP');
      b.getInput('A')!.connection!.connect(astToBlock(workspace, node.a!).outputConnection!);
      b.getInput('B')!.connection!.connect(astToBlock(workspace, node.b!).outputConnection!);
      return b;
    }
    default:
      throw new Error(`conditionParser: unknown AST node op "${(node as AstNode).op}"`);
  }
}

/** string → Blockly block, NEVER null — cond_raw fallback keeps it lossless. */
export function parseConditionToBlock(workspace: Blockly.Workspace, exprText: string): Blockly.Block {
  const ast = parseConditionExpr(exprText);
  if (ast) return astToBlock(workspace, ast);
  const raw = newBlock(workspace, 'cond_raw');
  raw.setFieldValue(exprText, 'EXPR');
  return raw;
}
