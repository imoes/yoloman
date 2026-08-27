import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { environment } from '../../../environments/environment';

/**
 * THE MANAGEMENT CONSOLE (MMC-shaped snap-in tree).
 *
 * Named `mmc`, not `console`: `console` in this product already means the interactive web shell, and one word
 * for two things is the equivocation that costs the most. The API says the same.
 */

/** available | unavailable (with a reason) | unknown (the host could not be asked). Never a boolean. */
export type SnapinState = 'available' | 'unavailable' | 'unknown';

export interface SnapinColumn {
  key: string;
  title: string;
  width?: number;
  grow?: boolean;
  badge?: boolean;
  numeric?: boolean;
  /** 'time' | 'bytes' — how to render the value; plain text when absent. */
  kind?: string;
  /** Read this key when the primary one is empty (a display name that some rows lack). */
  fallback?: string;
  /** Join an array value with this separator instead of showing JSON. */
  join?: string;
  /** Indent the cell by the row's value at this key — how a disk's partitions sit under it. */
  indent_key?: string;
}

export interface SnapinAction {
  id: string;
  title: string;
  icon?: string;
  tool: string;
  params: Record<string, unknown>;
  confirm?: boolean;
  /** An action that cannot apply to this row is not offered: {field, equals}. */
  hide_when?: { field: string; equals: unknown };
}

export interface SnapinNode {
  id: string;
  title: string;
  state: SnapinState;
  reason: string;
  columns: SnapinColumn[];
  actions: SnapinAction[];
  node_actions?: NodeAction[];
}

/**
 * An action that belongs to the NODE rather than to a row — "New user…". Its form is GENERATED from the
 * module's own input schema (see `ConsoleTree.schemas`), so a create dialog needs no markup and cannot offer a
 * parameter the module would refuse.
 */
export interface NodeAction {
  id: string;
  title: string;
  icon?: string;
  tool: string;
  prefill?: Record<string, unknown>;
  /** Open the form with the module's own dry-run switched on, so the first click previews. */
  dry_run_first?: boolean;
}

/** What a module says it accepts, straight from the agent: the authority on its own parameters. */
export interface ToolSchema {
  description?: string;
  input_schema: {
    type?: string;
    properties?: Record<string, {
      type?: string; description?: string; enum?: unknown[]; default?: unknown;
      items?: { type?: string };
    }>;
    required?: string[];
  };
  writes: boolean;
}

export interface Snapin {
  id: string;
  title: string;
  icon?: string;
  description?: string;
  /** The MMC program this mirrors — only set for Windows hosts, where the name means something. */
  mmc_equivalent?: string | null;
  state: SnapinState;
  reason: string;
  nodes: SnapinNode[];
}

export interface ConsoleTree {
  agent_id: string;
  host: string;
  os_family?: string | null;
  catalog_version?: number;
  /** Why states read `unknown`: the host could not be asked for its module list. */
  tools_error?: string | null;
  /** Per tool named by the catalog: its description and input schema, as the agent publishes them. */
  schemas?: Record<string, ToolSchema>;
  snapins: Snapin[];
}

export interface NodeResult {
  agent_id: string;
  host: string;
  snapin: string;
  node: string;
  title: string;
  columns: SnapinColumn[];
  actions: SnapinAction[];
  node_actions?: NodeAction[];
  rows: Record<string, unknown>[];
  count: number;
  /** Set when the host could not be read — the node still answers, with its columns and this reason. */
  error?: string | null;
}

@Injectable({ providedIn: 'root' })
export class MmcService {
  private http = inject(HttpClient);

  tree(agentId: string) {
    return this.http.get<ConsoleTree>(`${environment.apiUrl}/agents/${agentId}/mmc`);
  }

  node(agentId: string, snapin: string, node: string) {
    return this.http.get<NodeResult>(`${environment.apiUrl}/agents/${agentId}/mmc/${snapin}/${node}`);
  }

  /**
   * Run an action. Deliberately the SAME tool-call endpoint every other write in this product uses — the
   * console adds no write path of its own, so the agent's write gate, its ACL and the operation log see an
   * action from here exactly as they see one from a runbook.
   */
  runAction(agentId: string, tool: string, params: Record<string, unknown>, timeoutSeconds = 120) {
    return this.http.post<{ agent_id: string; tool: string; result: { changed: boolean; msg?: string; data?: unknown } }>(
      `${environment.apiUrl}/agents/${agentId}/tools/${tool}`,
      { params, timeout_seconds: timeoutSeconds },
    );
  }
}
