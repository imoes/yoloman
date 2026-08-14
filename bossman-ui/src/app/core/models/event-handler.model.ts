/** Event handlers (API: /api/v1/event-handlers, execution: services/event_handlers.py).
 *
 * An event handler is the reusable ACTION an event rule performs. Two independent axes:
 *   body      'runbook' | 'script'   WHAT runs
 *   location  'managed' | 'local'    WHERE the body comes from (scripts only)
 *
 * A runbook cannot be local (it is a row in Bossman's database) and a local handler declares no
 * parameters — both are enforced by CHECK constraints in the schema, not by this UI. The screen's
 * job is to show the REASON, which the server also serves (`HandlerMeta`), so the two never drift.
 *
 * See docs/event-handling.md.
 */

export type HandlerBody = 'runbook' | 'script';
export type HandlerLocation = 'managed' | 'local';

export interface HandlerParameter {
  name: string;
  type: string;
  default: string | null;
  description: string;
  required: boolean;
}

export interface EventHandler {
  id: string;
  name: string;
  description: string;
  body: HandlerBody;
  location: HandlerLocation;
  runbook_name: string | null;
  interpreter: string | null;
  source: string | null;
  local_name: string | null;
  parameters: HandlerParameter[];
  timeout_s: number;
  enabled: boolean;
  created_at: string;
  /** Where a script lives on the host — null for a runbook. */
  script_path: string | null;
  /** How many event rules use this handler. Deleting one that is in use is refused, so the
   * count is the reason, readable before the attempt. */
  used_by_rules: number;
  /** Send back as If-Match on PUT: a concurrent edit becomes a 412 instead of a silent
   * overwrite. */
  version: string;
}

export interface EventHandlerInput {
  name: string;
  description: string;
  body: HandlerBody;
  location: HandlerLocation;
  runbook_name: string | null;
  interpreter: string | null;
  source: string | null;
  local_name: string | null;
  parameters: HandlerParameter[];
  timeout_s: number;
  enabled: boolean;
}

/** The legal values, served by the API rather than repeated here — hard-coding them would drift
 * the moment either side gains an interpreter. `local_no_parameters_reason` is the sentence the
 * form shows instead of only disabling a field. */
export interface HandlerMeta {
  bodies: HandlerBody[];
  locations: HandlerLocation[];
  interpreters: string[];
  handler_dir: string;
  local_no_parameters_reason: string;
}

/** present | missing | unreachable | unknown — four NAMED outcomes. "not there", "could not
 * ask" and "that is not a host" are different facts, and only the first means someone has to go
 * and install a file. */
export type AvailabilityState = 'present' | 'missing' | 'unreachable' | 'unknown';

export interface HostAvailability {
  agent_id: string;
  host: string;
  state: AvailabilityState;
  detail: string;
}

export interface HandlerAvailability {
  handler_id: string;
  name: string;
  location: HandlerLocation;
  script_path: string | null;
  hosts: HostAvailability[];
  present_on: number;
  checked: number;
}
