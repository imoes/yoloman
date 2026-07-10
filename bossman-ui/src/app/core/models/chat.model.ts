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

/** A rendered chat message in the dock. */
export interface ChatUiMessage {
  role: 'user' | 'assistant';
  text: string;
  streaming?: boolean;
  error?: boolean;
  tools?: { tool: string; done: boolean }[];
}
