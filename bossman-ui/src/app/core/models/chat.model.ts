// Block K — AI chat console models.

export type ChatBackendName = 'claude_cli' | 'codex' | 'hermes_web';

export interface ChatBackendsResponse {
  backends: ChatBackendName[];
  default: ChatBackendName;
}

export interface ChatSession {
  id: string;
  label: string | null;
  backend: ChatBackendName;
  created_at: string | null;
  updated_at: string | null;
  msg_count: number | null;
}

export interface ChatHistoryMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  meta?: Record<string, unknown>;
}

/** One SSE frame from POST /chat/sessions/{sid}/message. */
export interface ChatEvent {
  type: 'delta' | 'tool_start' | 'tool_done' | 'reasoning' | 'widget' | 'error';
  text?: string;
  tool?: string;
  ok?: boolean;
  widget?: unknown; // Block K4: a widget spec
  [key: string]: unknown;
}

export interface OAuthStatusResponse {
  authenticated: Record<ChatBackendName, boolean>;
}

export interface CodexStartResponse {
  session_id: string;
  user_code: string;
  verification_uri: string;
  poll_interval_seconds: number;
  expires_in_minutes: number;
}

export interface CodexPollResponse {
  status: 'pending' | 'authorized' | 'timeout';
}

export interface ClaudeStartResponse {
  session_id: string;
  authorize_url: string;
  expires_in_minutes: number;
}

export interface ChatPrefs {
  default_backend: ChatBackendName;
  models: Record<string, string>;
}

/** W2 — a generated dashboard: AI-designed inline-data widget specs. */
export interface GeneratedWidgetSpec {
  widget_type: string;
  title: string;
  data: Record<string, unknown>;
  gs_w?: number;
  gs_h?: number;
}
export interface GeneratedDashboardResponse {
  prompt: string;
  widgets: GeneratedWidgetSpec[];
  created_at?: string | null;
  /** Block A3: the persisted named dashboard the generation created. */
  dashboard_id?: string;
  dashboard_name?: string;
}

/** A widget the assistant emitted (a ```bm-widget {json}``` block), parsed
 * into the DashboardWidget contract the shared renderer already understands. */
export interface ChatWidget {
  widget: import('./dashboard.model').DashboardWidget;
  data: import('./dashboard.model').WidgetData | null;
}

export interface PlanGraphSpec {
  title?: string;
  nodes: { id: string; label?: string }[];
  edges: { from: string; to: string; label?: string }[];
}

/** A rendered chat message in the dock. */
export interface ChatUiMessage {
  role: 'user' | 'assistant';
  text: string;
  streaming?: boolean;
  error?: boolean;
  tools?: { tool: string; done: boolean }[];
  widgets?: ChatWidget[];
  planGraphs?: PlanGraphSpec[];
  diagrams?: string[]; // rendered PlantUML image URLs
}
