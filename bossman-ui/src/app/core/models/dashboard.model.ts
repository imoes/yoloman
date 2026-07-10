/** Matches bossman/api/dashboard.py's DashboardWidgetOut — one persisted
 * GridStack widget on the operator's Fleet Overview dashboard (see
 * docs/plan.md's monitoring-cockpit ergänzung Block F5). */
export type WidgetType =
  | 'top_hosts'
  | 'problems'
  | 'gauge'
  | 'timeseries'
  | 'donut'
  | 'stat'
  // Block W1 — additional AI-console widget types.
  | 'bar'
  | 'table'
  | 'status_tiles'
  | 'progress'
  | 'ai_summary'
  | 'war_room'
  | 'log'
  | 'callout';

export interface DashboardWidget {
  id: string;
  widget_type: WidgetType;
  title: string;
  gs_x: number;
  gs_y: number;
  gs_w: number;
  gs_h: number;
  config: Record<string, unknown>;
  pinned: boolean;
  hidden: boolean;
  created_at: string;
}

export interface CreateDashboardWidget {
  widget_type: WidgetType;
  title: string;
  gs_x?: number;
  gs_y?: number;
  gs_w?: number;
  gs_h?: number;
  config?: Record<string, unknown>;
}

export interface UpdateDashboardWidget {
  gs_x?: number;
  gs_y?: number;
  gs_w?: number;
  gs_h?: number;
  title?: string;
  config?: Record<string, unknown>;
  pinned?: boolean;
  hidden?: boolean;
}

/** Per-type payload shapes returned by GET .../data — matches
 * bossman/services/dashboard.py's widget_data() dispatch exactly. */
export interface TopHostsWidgetData {
  hosts: Array<{
    id: string;
    name: string;
    parent_name: string | null;
    state_rollup: 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN';
    cpu_load: number | null;
    mem_used_pct: number | null;
    disk_used_pct_max: number | null;
  }>;
}

export interface ProblemsWidgetData {
  problems: Array<{
    id: string;
    host: string;
    name: string;
    state: string;
    last_state_change: string;
  }>;
}

export interface DonutWidgetData {
  buckets: Array<{ key: string; count: number }>;
}

export interface StatWidgetData {
  value: number | null;
  label: string;
}

export interface GaugeWidgetData {
  value: number | null;
  warn?: number | null;
  crit?: number | null;
  error?: string;
}

export interface TimeseriesWidgetData {
  points: Array<{ time: string; value: number }>;
  error?: string;
}

// ---- Block W1: additional widget data shapes ----
export interface BarWidgetData {
  buckets: Array<{ key: string; count: number }>;
}
export interface TableWidgetData {
  columns: string[];
  rows: Array<Array<string | number>>;
}
export type TileState = 'OK' | 'WARN' | 'CRIT' | 'UNKNOWN';
export interface StatusTilesWidgetData {
  tiles: Array<{ label: string; state: TileState; sub?: string }>;
}
export interface ProgressWidgetData {
  items: Array<{ label: string; value: number; max?: number; state?: TileState }>;
}
export interface AiSummaryWidgetData {
  summary: string;
  findings?: string[];
  recommendations?: string[];
}
export interface WarRoomWidgetData {
  active?: boolean;
  severity?: TileState;
  findings?: string[];
  recommendations?: string[];
  blast_radius?: string[];
}
export interface LogWidgetData {
  lines?: string[];
  entries?: Array<{ timestamp?: string; unit?: string; message: string; priority?: string | number }>;
}
export interface CalloutWidgetData {
  level?: 'info' | 'warn' | 'error' | 'success';
  text: string;
}

export type WidgetData =
  | TopHostsWidgetData
  | ProblemsWidgetData
  | DonutWidgetData
  | StatWidgetData
  | GaugeWidgetData
  | TimeseriesWidgetData
  | BarWidgetData
  | TableWidgetData
  | StatusTilesWidgetData
  | ProgressWidgetData
  | AiSummaryWidgetData
  | WarRoomWidgetData
  | LogWidgetData
  | CalloutWidgetData;

/** Mirrors bossman/services/dashboard.py's DEFAULT_SIZE — used client-side
 * only for the add-widget dialog preview; the server applies its own copy
 * when gs_w/gs_h are omitted, so this never needs to be authoritative. */
export const WIDGET_CATALOG: Array<{ type: WidgetType; label: string; icon: string; defaultSize: [number, number] }> = [
  { type: 'top_hosts', label: 'Top hosts', icon: 'dns', defaultSize: [6, 4] },
  { type: 'problems', label: 'Problems', icon: 'warning', defaultSize: [6, 4] },
  { type: 'donut', label: 'Service states', icon: 'donut_large', defaultSize: [4, 4] },
  { type: 'stat', label: 'Stat', icon: 'looks_one', defaultSize: [2, 2] },
  { type: 'gauge', label: 'Gauge', icon: 'speed', defaultSize: [3, 3] },
  { type: 'timeseries', label: 'Time series', icon: 'show_chart', defaultSize: [5, 4] },
];
