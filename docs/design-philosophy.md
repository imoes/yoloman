# Design philosophy — macOS-derived

Bossman's UI follows Apple's macOS/HIG design ethos, translated into concrete
rules for this app. This is the reference every screen is measured against;
"make it as well-thought-out as macOS" means these rules, applied
consistently. Angular Material is the toolkit, but the *feel* is macOS: calm,
content-first, precise, forgiving.

## The three pillars (Apple HIG)

- **Clarity** — text is legible at every size, icons are precise, layout is
  generous, and nothing decorative competes with content. Negative space is a
  feature. Colour is used sparingly and with meaning.
- **Deference** — the interface defers to content. Chrome is minimal; the data
  (hosts, checks, config, topology) is the star. No gratuitous borders,
  shadows, or gradients.
- **Depth** — layering and motion convey hierarchy: a source list < content <
  an inspector; a sheet slides from the thing it acts on. Depth explains
  structure, it doesn't decorate.

## Concrete rules for Bossman

### 1. Colour — restraint
- Neutral dark surfaces. The green accent means exactly one of: primary action,
  current selection, or a healthy status. Gold = warning, red = critical/danger,
  grey = unknown. **Never** colour a table row, panel, or body text as
  decoration. If everything is green, nothing is.
- Status colour lives in small dots/pills/badges, never as fills behind text.

### 2. Typography — one clear hierarchy
- Page title (h1) → section (h2/h3) → body → caption/label, each a distinct
  step, from the Material type scale. Monospace only for machine tokens
  (paths, hashes, commands, keys). No more than these levels on a screen.

### 3. Spacing — generous & consistent
- One spacing scale (4 · 8 · 12 · 16 · 24 · 32). Pages breathe: 24px page
  padding, 16px between cards, 8–12px within. Consistency beats density — an
  ops tool is dense in *data*, not in cramped chrome.

### 4. Structure — source list → content → inspector (Finder/Mail)
- Left **source list** (the nav; and trees like Roles / OU / gpedit): quiet,
  selection is a subtle fill + accent bar, hairline separators, disclosure
  triangles for hierarchy.
- **Miller columns** for drilling hierarchy (gpedit: category → file →
  settings) — pick left, detail appears right.
- **Inspector** on the right for the selected object's facets (host detail,
  OU detail).

### 5. Direct manipulation
- Drag to place/move (roles into a Run, policies between OUs). The result is
  immediate and visible; dragging shows a valid drop target.

### 6. One primary action
- Each screen/dialog has exactly one filled (green) primary button; everything
  else is text/outline. The primary action is obvious and never ambiguous.

### 7. Feedback & forgiveness
- Every action is acknowledged (toast / inline state / spinner). Destructive
  actions confirm and are reversible where possible (config generations +
  rollback, dry-run before apply). Errors are quiet, specific, and in place —
  never a raw traceback.

### 8. Sheets & empty states
- Modal work happens in a focused sheet/dialog titled for its object; Cancel is
  always present and safe. Every list has a helpful empty state that tells you
  the next step (and links to it) — never a blank void.

### 9. Hairlines, not boxes — and grouped inset lists
- Separate with 1px hairline dividers and whitespace, not heavy borders/boxes.
  Cards are subtle raised surfaces, not outlined containers.
- Object lists/tables sit in **grouped inset lists** (macOS System Settings):
  a rounded, hairline-bordered group with a quiet header row — never a
  full-bleed grid stretching to the viewport edge. Content has a comfortable
  max width; columns are sized to their content.

### 10. Essential-only + auto-discovery (the biggest one)
- A screen offers **only the essential decisions** a person must actually make;
  everything else is **discovered and configured automatically** with sensible
  defaults. "Ask nothing you can find out yourself."
- **Progressive disclosure**: optional/defaulted settings live behind an
  *Advanced* disclosure, collapsed by default. The common path is one glance,
  one primary action.
- **Especially at deployment**: don't present a wall of knobs. Auto-discover
  what applies (the relevant checks, the role's variables, the target's facts),
  pre-fill safe defaults, and surface only the values the operator *must*
  supply (e.g. a required credential with no default). Optional variables that
  already have a default are hidden under *Advanced* — the deploy "just works"
  with defaults, and power users can still reach everything.
- A field the system can determine (an address, a codec, a section, a
  distro) is filled in, not asked.

### 11. Consistency
- The same concept is named the same everywhere (a "role" is a role on every
  screen), the same control does the same thing, icons are stable. Learn once,
  apply everywhere.

### 12. Humane data formatting
- Values shown to a person carry **units and sensible precision**: `37.1 %`,
  `15 d 3 h`, `4.5` — never a raw float (`37.05206631905181`) or raw seconds
  (`1306051`). Machine tokens (metric keys, hashes, paths) stay monospace and
  dim; human values are formatted.
- **Numbers right-align** in their column; text left-aligns. A column of
  numbers must be scannable top-to-bottom.
- If the UI knows the unit (a `_pct` metric, a seconds counter, bytes), it
  formats it — showing the raw value is a bug, not a style choice.

## Appearance: Rastafari (the skin over the macOS bones)

The *structure and behaviour* are macOS; the *skin* is Rastafari. The two
reconcile through restraint — the tricolour is an **identity signature**, not a
background flood (rule 1 still holds).

- **Palette**: green `#1e9600`, gold `#ffc800`, red `#d0021b`, on near-black
  surfaces `#0d0d0d`. These are exactly the status/accent tokens
  (`--bm-green/gold/red/black`), so brand and meaning share one language.
- **Semantics stay honest**: green = primary action / current selection /
  healthy; gold = warning; red = danger / critical. A user never has to wonder
  whether a colour means something — it always does.
- **The tricolour is the signature**, applied only at identity moments:
  the nav's top band, the brand block's underline, and a small accent on a
  page header. `--bm-tricolor` (red→gold→green) is the one gradient; use it as
  a thin rule/band, never as a fill behind content.
- **Black is the canvas**: dark, calm surfaces let the tricolour and the data
  read. No coloured panels, no coloured table rows.

## Implementation

Global tokens + rules live in `src/styles.scss` (the spacing scale, hairline,
focus ring, source-list + page-header treatment). Per-screen work references
those tokens rather than re-inventing spacing/colour. Screens are brought up to
this bar incrementally; this doc is the checklist.
