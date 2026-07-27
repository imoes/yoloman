/**
 * Bridge between the async module argspec (loaded by the Angular component via
 * ModuleService / a host's tool schema) and the synchronous Blockly block code.
 *
 * Blockly block `init`/`loadExtraState` run synchronously, but a module's option
 * schema is fetched over HTTP. So blocks read the argspec from a synchronous
 * cache here; if it's not loaded yet they subscribe, the component loads it and
 * calls `notifyArgspec`, and the block rebuilds its typed fields. The reference
 * ansible designer sidestepped this by committing a static catalog JSON — we
 * have thousands of modules loaded lazily, so this bridge replaces that.
 */
export interface ArgFieldSpec {
  key: string;
  type?: string;             // str | bool | int | float | list | dict | ...
  required?: boolean;
  choices?: unknown[];
  default?: unknown;
  description?: string;
}

type Provider = (module: string) => ArgFieldSpec[] | undefined;

let _provider: Provider = () => undefined;
let _loader: (module: string) => void = () => {};
const _waiters = new Map<string, Set<() => void>>();

/** The component wires its argspec cache (sync read) + loader (async fetch). */
export function configureArgspec(provider: Provider, loader: (module: string) => void): void {
  _provider = provider;
  _loader = loader;
}

/** Synchronous read — undefined means "not loaded yet". */
export function getArgspec(module: string): ArgFieldSpec[] | undefined {
  return module ? _provider(module) : [];
}

/** Ask to be called back once `module`'s argspec is available (immediately if
 * already cached), triggering a load if needed. */
export function subscribeArgspec(module: string, cb: () => void): void {
  if (!module) return;
  if (_provider(module)) { cb(); return; }
  let set = _waiters.get(module);
  if (!set) { set = new Set(); _waiters.set(module, set); }
  set.add(cb);
  _loader(module);
}

/** Component calls this after an argspec finishes loading. */
export function notifyArgspec(module: string): void {
  const set = _waiters.get(module);
  if (set) { _waiters.delete(module); set.forEach((cb) => cb()); }
}
