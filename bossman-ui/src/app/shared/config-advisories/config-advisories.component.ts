import { Component, computed, input } from '@angular/core';

/** The subset of a /config-fields answer this component reads. Exported so a caller can type its own signal
 * without restating the shape — one declaration, and the component's own input is the only place it lives. */
export interface ConfigAdvisories {
  path_verdict?: { verdict: string; package?: string; family?: string; created_at_install?: boolean;
                   reason: string } | null;
  machine_written?: { line: number; quote: string; marker?: string } | null;
  provenance?: { source?: string; measured?: boolean; confidence?: string; note?: string;
                 probe?: { verdict?: string; active_lines?: number; keys?: number } | null } | null;
}

@Component({
  selector: 'app-config-advisories',
  standalone: true,
  template: `
    @if (verdict(); as v) {
      <p class="bm-adv bm-adv-warn">
        <strong>No file here.</strong> {{ v.reason }}.
        @if (v.verdict === 'directory') {
          A directory cannot be written as a file.
        } @else {
          Applying would create a new file that nothing reads.
        }
      </p>
    }
    @if (generated(); as g) {
      <p class="bm-adv bm-adv-warn">
        <strong>This file says it is generated</strong> (line {{ g.line }}):
        <em>“{{ g.quote }}”</em> — a value set here is discarded the next time the generator runs.
      </p>
    }
    @if (grammarNote(); as n) {
      <p class="bm-adv bm-adv-note">{{ n }}</p>
    }
  `,
  styles: [`
    .bm-adv { margin: 6px 0; padding: 8px 10px; border-radius: 6px; font-size: 13px; line-height: 1.5; }
    .bm-adv-warn { background: rgba(255, 138, 128, 0.12); border-left: 3px solid #ff8a80; }
    .bm-adv-note { background: rgba(255, 255, 255, 0.04); border-left: 3px solid rgba(255, 255, 255, 0.25);
      opacity: 0.85; }
    .bm-adv em { font-style: italic; }
  `],
})
/** What is known ABOUT a config file, said before it is edited — one component, both editors.
 *
 * `/config-fields` carries four measured statements that no screen showed. Measuring them and then not
 * displaying them is the same as not knowing them, so they lived in JSON nobody reads:
 *
 *   path_verdict    the package ships no file at this path — measured by extracting the real .deb/.rpm.
 *                   THE MOST IMPORTANT ONE, because both write paths act anyway: a whole-file render CREATES
 *                   the file, so /etc/aide would gain a rendered text that aide never reads (its config is
 *                   /etc/aide.conf). Per family, because 20 of 83 paths measured on both distributions
 *                   disagree — /etc/named.conf is absent on Debian and a real file on EL.
 *   machine_written the file's OWN header says it is generated. Not a refusal: /etc/munin/munin.conf is
 *                   parsable and editable and still asks not to be edited. The file's sentence is quoted
 *                   verbatim and the operator decides — a value applied here is dropped by the next
 *                   generator run, and the returning drift then has no visible cause.
 *   provenance      whether the GRAMMAR was decided by round-tripping a real file, or merely asserted. An
 *                   unverified codec means a per-key merge on a grammar nobody checked, which can corrupt the
 *                   file it writes. `probe.verdict === 'no-evidence'` is a third state: the shipped file has
 *                   no active setting at all, so its bytes cannot confirm or refute the claim.
 *   withheld/unsettable/renderer_gaps  stay in the template editor, since they are about a template rather
 *                   than about the file.
 *
 * Severity is deliberate and small: `warn` for the two that make a write pointless or lossy, `note` for what
 * is merely worth knowing. Colouring everything the same would make the operator read none of it.
 */
export class ConfigAdvisoriesComponent {
  /** The /config-fields answer, passed whole: these are its fields, and picking them apart at every call
   * site would put the same four reads in three places. */
  spec = input<ConfigAdvisories | null>(null);

  verdict = computed(() => {
    const v = this.spec()?.path_verdict;
    // `created_at_install` is not a warning: a config the maintainer script writes exists on every installed
    // host and is merely missing from the archive. The API already withholds it, and this is the second
    // reader — cheap, and it means a future caller cannot reintroduce the false warning.
    return v && !v.created_at_install ? v : null;
  });

  generated = computed(() => this.spec()?.machine_written ?? null);

  /** One sentence about the grammar, or none. Silence is correct for a measured codec: an operator does not
   * need to be told that the normal case is normal. */
  grammarNote = computed(() => {
    const p = this.spec()?.provenance;
    if (!p || p.measured) { return null; }
    if (p.probe?.verdict === 'no-evidence') {
      return `The grammar could not be verified: the file this package ships contains no active setting `
        + `(${p.probe.active_lines ?? 0} lines), so its bytes can neither confirm nor refute it.`;
    }
    return p.note || 'This grammar has never been checked against a real file.';
  });
}
