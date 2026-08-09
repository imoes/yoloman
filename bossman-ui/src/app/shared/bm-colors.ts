/** The single source of truth for Bossman's Rastafari accent palette, in
 * literal hex — needed because canvas-rendered libraries (cytoscape,
 * ngx-echarts) don't resolve CSS custom properties at style-application
 * time, unlike every plain DOM element, which reads `--bm-*` directly
 * from styles.scss. Every component that needs the same colours outside
 * the DOM (topology graph, metric charts) imports these constants instead
 * of re-hardcoding its own hex literals, so the two can never drift apart
 * (see docs/plan.md's monitoring-cockpit ergänzung Block F6). */
export const BM_GREEN = '#1e9600';
export const BM_GOLD = '#ffc800';
export const BM_RED = '#d0021b';
export const BM_BLACK = '#0d0d0d';
export const BM_UNKNOWN = '#8a8a8a';
