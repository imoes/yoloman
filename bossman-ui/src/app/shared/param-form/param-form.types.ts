/** One typed parameter of a runbook's input mask (mirrors the backend
 * nt_runbook parameter spec). */
export interface ParamSpec {
  type: 'string' | 'number' | 'bool' | 'list' | 'object';
  description?: string;
  default?: unknown;
  secret?: boolean;
  enum?: unknown[];
  items?: Record<string, ParamSpec>; // element schema for a list-of-objects
  hidden?: boolean;
  required?: boolean;
  widget?: 'file';                    // render a remote file-picker (needs agentId)
  pattern?: string;                   // file-picker glob filter, e.g. "*.pem *.crt *.key"
}

export type ParamSchema = Record<string, ParamSpec>;
