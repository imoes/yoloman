/**
 * Icon loader for the canvas.
 *
 * The vendored icons are line art with `stroke="currentColor"` — which is exactly
 * what we want in the DOM (the app sets the colour, so one file serves light/dark
 * and later a status tint). But Cytoscape draws nodes on a <canvas> and takes a
 * `background-image` URL: an SVG referenced as an image has NO colour context, so
 * `currentColor` there would fall back to black and vanish on a dark canvas.
 *
 * So we fetch each icon once as text, substitute the colour, and hand Cytoscape a
 * data URI. Same source of truth, tint preserved, and no extra HTTP per node.
 */
const BASE = 'assets/blueprint';

const text = new Map<string, string>();          // icon → raw svg source
const tinted = new Map<string, string>();        // `${icon}|${colour}` → data URI

/** Load every icon's source once. Missing files degrade to a blank icon rather
 * than breaking the canvas. */
export async function preloadIcons(keys: string[]): Promise<void> {
  await Promise.all(keys.map(async (k) => {
    if (text.has(k)) return;
    try {
      const res = await fetch(`${BASE}/${k}.svg`);
      if (res.ok) text.set(k, await res.text());
    } catch { /* offline / 404: iconFor() returns '' and the node keeps its shape */ }
  }));
}

/** A data-URI copy of `icon` drawn in `colour`. */
export function iconFor(icon: string, colour: string): string {
  const key = `${icon}|${colour}`;
  const hit = tinted.get(key);
  if (hit) return hit;
  const src = text.get(icon);
  if (!src) return '';
  // `currentColor` is the only colour token in our own icons; a user-supplied icon
  // with hard-coded fills is left as-is (it simply won't follow the tint).
  const svg = src.replace(/currentColor/g, colour);
  const uri = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  tinted.set(key, uri);
  return uri;
}
