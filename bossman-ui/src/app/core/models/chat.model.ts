// Block K — AI chat console models.

export type ChatBackendName = 'claude_cli' | 'codex' | 'hermes_web' | 'openrouter';

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
  hermes_base_url?: string;
  hermes_model?: string;
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
  forms?: ChatForm[]; // task → input-mask (bm-form blocks)
  tasks?: ChatTask[]; // full task dashboards (bm-task blocks)
}

/** A ```bm-form``` block the assistant emitted for the task → input-mask flow:
 * the AI-chosen fields for an actionable task, optionally mapped to a plan. */
export interface ChatFormField {
  name: string;
  label?: string;
  type: 'text' | 'textarea' | 'number' | 'bool' | 'select' | 'multiselect' | 'host' | 'hosts';
  required?: boolean;
  default?: unknown;
  options?: string[];
  help?: string;
}
/** An AI-authored plan carried inside a bm-form: stored then run on Execute.
 * Preferred shape: `plan_body` as a nested JSON object (the UI serializes it),
 * which avoids the model having to escape a JSON-in-JSON string. Legacy
 * source_text/source_format still accepted. */
export interface GeneratedPlan {
  prefix: string;
  name: string;
  plan_body?: unknown;
  source_format?: string; // json | yaml
  source_text?: string;
}
export interface ChatForm {
  intent: string;
  plan: string | null;
  generated_plan?: GeneratedPlan | null;
  needs_host?: boolean;
  fields: ChatFormField[];
}

/** A ```bm-task``` block — a full, designed task dashboard the AI generates for
 * an actionable task: a multi-section config grid, status cards, a generated
 * output (shell script) preview, and run actions. All JSON, so a rendered view
 * is fully cacheable (persisted in the message + re-parsed on reload). */
export interface ChatTaskField {
  name: string;
  label?: string;
  type: 'text' | 'textarea' | 'number' | 'select' | 'toggle' | 'checkbox' | 'upload' | 'host' | 'hosts';
  default?: unknown;
  options?: string[];
  help?: string;
  readonly?: boolean;
  placeholder?: string;
}
export interface ChatTaskSection {
  title: string;
  fields: ChatTaskField[];
}
export interface ChatTaskSummaryItem {
  label: string;
  value: string;
  icon?: string;
  state?: 'ok' | 'warn' | 'crit' | 'pending';
}
export interface ChatTaskOutput {
  language?: string;
  script?: string;
}
export interface ChatTask {
  title: string;
  intro?: string;
  plan: string | null;
  generated_plan?: GeneratedPlan | null;
  sections: ChatTaskSection[];
  summary?: ChatTaskSummaryItem[];
  output?: ChatTaskOutput;
}
