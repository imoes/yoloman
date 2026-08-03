/** Matches bossman/api/modules.py (Block H4) — the Starlark module
 * library's read-only management surface. */

export interface ModuleInfo {
  fqcn: string;
  collection: string;
  name: string;
  translated: boolean;
  /** Implemented in the agent's Go registry (no Starlark). A native module WINS its short name: the agent
   *  registers natives first and refuses duplicates, so it is the native one that actually runs. */
  native?: boolean;
  short_description?: string;
  writes?: boolean;
}

export interface ModuleCatalog {
  total: number;
  translated: number;
  collections: Record<string, { total: number; translated: number }>;
  modules: ModuleInfo[];
}

export interface ModuleOptionSpec {
  type?: string;
  required?: boolean;
  default?: unknown;
  choices?: unknown[];
  aliases?: string[];
  description?: string | string[];
}

export interface ModuleDetail {
  fqcn: string;
  translated: boolean;
  metadata: {
    name?: string;
    collection?: string;
    short_description?: string;
    description?: string;
    options?: Record<string, ModuleOptionSpec>;
    writes?: boolean;
    runtime?: string;
    source?: string;
  };
  star_code: string;
}
