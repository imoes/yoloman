/** The single source of truth for Bossman's Rastafari accent palette, in
 * literal hex — needed because canvas-rendered libraries (cytoscape,
 * ngx-echarts) don't resolve CSS custom properties at style-application
 * time, unlike every plain DOM element, which reads `--bm-*` directly
 * from styles.scss. Every component that needs the same colours outside
 * the DOM (topology graph, metric charts) imports these constants instead
 * of re-hardcoding its own hex literals, so the two can never drift apart
 * (see docs/plan.md's monitoring-cockpit ergänzung Block F6). */
// Kept equal to styles.scss --bm-* (raised to WCAG AA there; these had drifted to the old values).
export const BM_GREEN = '#34b814';
export const BM_GOLD = '#ffc800';
export const BM_RED = '#ff5c6a';
export const BM_BLACK = '#0d0d0d';
export const BM_UNKNOWN = '#a8a8a8';

/** The app has ONE theme, dark (styles.scss mat.theme theme-type: dark), whatever the OS prefers. Editors and
 * canvases pick their palette from this, not from prefers-color-scheme — on a light OS that query drew a light
 * Monaco / light-mode chart text onto the dark app. */
export const APP_IS_DARK = true;
