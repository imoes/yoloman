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
}

export type ParamSchema = Record<string, ParamSpec>;
