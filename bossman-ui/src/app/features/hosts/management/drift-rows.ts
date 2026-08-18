import { StateResourceChange } from '../../../core/models/agent.model';

/** A config value as one line of text. Strings pass through; anything else is JSON, so a list or a map
 * is shown rather than rendered as "[object Object]". */
export function scalarText(v: unknown): string {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v;
  return JSON.stringify(v);
}

/** Per-key drift rows for one managed file: what the host HAS versus what the policy WANTS.
 *
 * MIND THE DIRECTION. A plan diff records `before → after`, i.e. observed → desired. For drift the
 * question is the other way round — "the file says X, policy says Y" — so `before` is the LIVE value and
 * `after` is the DESIRED one. Getting that backwards would label every drift row inside out, and the
 * table would read as a correct system with wrong policies.
 *
 * `null` desired means the policy enforces the key's ABSENCE, which is a state of its own and is shown as
 * "(remove)" rather than as an empty cell — an empty cell reads as "no opinion", the opposite of what a
 * Removed policy asserts. A missing live value shows as "—" for the same reason: absent is not empty.
 *
 * A plain function, shared by the drift banner and the per-file drift table under the settings list. It
 * used to be a method on the host page that both places reached for; two copies of a direction-sensitive
 * derivation is how the two tables would eventually disagree.
 */
export function driftRows(change: StateResourceChange | null | undefined):
    { key: string; desired: string; live: string }[] {
  const changed = change?.changed;
  if (!changed) return [];
  return Object.entries(changed).map(([key, [live, desired]]) => ({
    key,
    desired: desired === null || desired === undefined ? '(remove)' : scalarText(desired),
    live: live === null || live === undefined ? '—' : scalarText(live),
  }));
}
