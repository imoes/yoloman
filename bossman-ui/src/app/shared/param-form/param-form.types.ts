/** One typed parameter of a runbook's input mask (mirrors the backend
 * nt_runbook parameter spec). */
export interface ParamSpec {
  type: 'string' | 'number' | 'bool' | 'list' | 'object';
  description?: string;
  default?: unknown;
  secret?: boolean;
  enum?: unknown[];
  /** value -> what it MEANS, for a set whose values are opaque on their own.
   *
   * `log_level: 0|1|2|3` is a menu of nothing: the NUMBER is what gets written to the config file, and the
   * words ("error", "warn", …) exist only in the description, where a dropdown cannot show them. Measured,
   * 109 enums in the template corpus are all-numeric. The option shows the label and still submits the
   * value. */
  enum_labels?: Record<string, string>;
  items?: Record<string, ParamSpec>; // element schema for a list-of-objects
  hidden?: boolean;
  required?: boolean;
  widget?: 'file';                    // render a remote file-picker (needs agentId)
  pattern?: string;                   // file-picker glob filter, e.g. "*.pem *.crt *.key"
}

export type ParamSchema = Record<string, ParamSpec>;
