/** Saved charts (API: /api/v1/graphs, data: services/graph_data.py).
 *
 * A graph is the NAMED, reusable definition of a chart: several items, each its own
 * host+metric with a colour, a draw style, an axis side and an aggregate function. A
 * dashboard `timeseries` widget is a PLACE that renders one (`config.graph_id`).
 *
 * That split is why the dialog authors graphs rather than per-widget series: a chart with
 * one item and a "single metric widget" would be the same result reached two ways. */

export type GraphDrawStyle = 'line' | 'bold_line' | 'filled' | 'dot' | 'dashed' | 'gradient';
export type GraphAxisSide = 'left' | 'right';
/** "last" is Zabbix's pie-only function; these charts are line-based, so it plots like avg. */
export type GraphFunction = 'avg' | 'min' | 'max' | 'last';

export interface GraphItemInput {
  agent_id: string;
  metric: string;
  label?: string | null;
  color?: string;
  draw_style?: GraphDrawStyle;
  axis_side?: GraphAxisSide;
  function?: GraphFunction;
  sort_order?: number;
}

export interface GraphItem extends GraphItemInput {
  id: string;
}

export interface GraphInput {
  name: string;
  graph_type?: 'normal' | 'stacked';
  y_axis_mode?: string;
  show_legend?: boolean;
  show_working_time?: boolean;
  items: GraphItemInput[];
}

export interface Graph {
  id: string;
  name: string;
  graph_type: string;
  y_axis_mode: string;
  show_legend: boolean;
  show_working_time: boolean;
  created_at: string;
  items: GraphItem[];
}
