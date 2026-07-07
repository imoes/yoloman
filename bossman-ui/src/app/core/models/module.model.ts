/** Matches bossman/api/modules.py (Block H4) — the Starlark module
 * library's read-only management surface. */

export interface ModuleInfo {
  fqcn: string;
  collection: string;
  name: string;
  translated: boolean;
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
