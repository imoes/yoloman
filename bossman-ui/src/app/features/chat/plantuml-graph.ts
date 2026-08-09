/** Parse (common) PlantUML source into a node/edge graph so the chat can render
 * it INTERACTIVELY with Cytoscape (like CentralStation) instead of fetching an
 * SVG from an external PlantUML server. Handles the constructs the assistant
 * actually emits: sequence arrows (`A -> B : label`, `-->`, `->>`), activity
 * flows (`(*) --> "Step"`, `"A" --> "B"`) and participant/actor declarations.
 * Returns null when nothing graph-like is found (caller then leaves the block
 * as text — no silent empty diagram). */

export interface ParsedGraph {
  nodes: { id: string; label: string }[];
  edges: { from: string; to: string; label?: string }[];
}

const DECL_RE = /^(participant|actor|component|class|entity|database|node|usecase|boundary|control|collections|queue)\s+(?:"([^"]+)"|([A-Za-z0-9_]+))(?:\s+as\s+([A-Za-z0-9_]+))?/i;
// left  arrow  right  [: label]. The arrow must be whitespace-delimited (so a
// hyphen inside a label like "GPG-Key" is not mistaken for an arrow) and carry
// a real arrowhead (< or >). Direction comes from which side the head is on.
const ARROW_RE = /^(.+?)\s+(<{1,2}[-.=]{1,}|[-.=]{1,}(?:>{1,2}|\|>))\s+(.+?)(?:\s*:\s*(.*))?$/;

function clean(tok: string): string {
  return tok.trim().replace(/^"(.*)"$/, '$1').replace(/^\[|\]$/g, '')
    .replace(/\\n|\n/g, ' ').replace(/\s+/g, ' ').trim();
}

function slug(label: string): string {
  return label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'n';
}

export function plantumlToGraph(source: string): ParsedGraph | null {
  const nodes = new Map<string, string>(); // id -> label
  const aliases = new Map<string, string>(); // declared alias -> id
  const edges: { from: string; to: string; label?: string }[] = [];

  const ensure = (raw: string): string => {
    let label = clean(raw);
    if (!label) return '';
    if (label === '(*)' || label === '[*]') label = 'start';
    const aliased = aliases.get(label);
    if (aliased) return aliased;
    const id = slug(label);
    if (!nodes.has(id)) nodes.set(id, label);
    return id;
  };

  for (let line of source.split('\n')) {
    line = line.trim();
    if (!line) continue;
    const low = line.toLowerCase();
    if (
      low.startsWith('@start') || low.startsWith('@end') || low.startsWith("'") ||
      low.startsWith('title') || low.startsWith('skinparam') || low.startsWith('!') ||
      low.startsWith('note') || low.startsWith('end note') || low.startsWith('autonumber') ||
      low.startsWith('activate') || low.startsWith('deactivate') || low.startsWith('alt ') ||
      low.startsWith('else') || low.startsWith('end') || low.startsWith('loop') ||
      low.startsWith('group') || low.startsWith('opt ') || low.startsWith('par ') ||
      low === 'left to right direction' || low === 'top to bottom direction'
    ) {
      continue;
    }

    const decl = line.match(DECL_RE);
    if (decl) {
      const label = clean(decl[2] || decl[3] || '');
      if (!label) continue;
      const id = slug(label);
      nodes.set(id, label);
      if (decl[4]) aliases.set(decl[4], id); // "as X"
      continue;
    }

    const arrow = line.match(ARROW_RE);
    if (arrow) {
      // Direction from the arrowhead (`<…` at the left means reversed).
      const reversed = arrow[2].startsWith('<');
      const a = ensure(arrow[1]);
      const b = ensure(arrow[3]);
      const label = (arrow[4] || '').replace(/\\n|\n/g, ' ').replace(/\s+/g, ' ').trim() || undefined;
      if (a && b && a !== b) {
        edges.push(reversed ? { from: b, to: a, label } : { from: a, to: b, label });
      }
    }
  }

  if (!nodes.size || !edges.length) return null;
  return { nodes: [...nodes].map(([id, label]) => ({ id, label })), edges };
}
