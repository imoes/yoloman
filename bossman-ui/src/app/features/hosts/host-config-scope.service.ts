import { Injectable, inject, signal } from '@angular/core';
import { HostGroupService } from '../../core/services/host-group.service';

/** "Where does this write go?" — the apply scope of the host page's configuration editors.
 *
 * WHY A SERVICE AND NOT INPUTS. The Configuration editor is being split into its panes (thresholds,
 * settings, file edit, template edit, rollback, …) and MEASURABLY several of them share this state:
 * applyScope is read at four places in the threshold pane and the file/settings/template panes alike,
 * hostGroups at four more. Threading it through as inputs would mean every one of the nine slices
 * carries the same three bindings, and the host page would hold state on behalf of children that all
 * agree about it anyway.
 *
 * The scope is a property of the PAGE, not of a pane: "I am editing this host, and my edits should
 * land on the host / its OU / a group" is one answer the whole screen shares. So it lives once, and
 * panes inject it.
 *
 * PROVIDE IT ON THE HOST COMPONENT, never in root. Two host pages must not share an apply scope — a
 * scope silently carried from one host to another is how an edit meant for one machine lands on a
 * whole OU. Component-level `providers: [HostConfigScopeService]` gives one instance per host page and
 * destroys it with the page.
 */
@Injectable()
export class HostConfigScopeService {
  private hostGroupService = inject(HostGroupService);

  /** 'host' | 'ou' | 'group:<id>'. Block K4: an OU/group apply saves a config policy and converges
   * every member host, which is why the default is the narrowest one — 'host'. A default that wrote
   * to an OU would make the blast radius of a careless click the whole subtree. */
  readonly applyScope = signal<string>('host');

  /** Groups offered for the group scope. ALL groups are offered, not just this host's: targeting a
   * group the host is not in still creates the policy and converges that group's members, and
   * agents.groups can lag the membership table — filtering by it would hide valid targets. */
  readonly hostGroups = signal<{ id: string; name: string }[]>([]);

  /** The scope as the API expects it, or undefined for a plain host write. */
  scopeArg(ouId: string | null | undefined): { ouId?: string; groupId?: string } | undefined {
    const s = this.applyScope();
    if (s === 'ou') return { ouId: ouId ?? undefined };
    if (s.startsWith('group:')) return { groupId: s.slice(6) };
    return undefined;
  }

  /** The group NAME behind a 'group:<id>' scope, for the rules that are written by name. */
  groupName(): string {
    const s = this.applyScope();
    if (!s.startsWith('group:')) return '';
    return this.hostGroups().find((g) => 'group:' + g.id === s)?.name ?? '';
  }

  /** Load the group list once. Idempotent: called from several panes' init without coordinating, and
   * a second call must not refetch — the list does not change while a page is open. */
  loadGroups(): void {
    if (this.hostGroups().length) return;
    this.hostGroupService.list().subscribe({
      next: (gs) => this.hostGroups.set((gs || []).map((g) => ({ id: g.id, name: g.name }))),
      error: () => this.hostGroups.set([]),
    });
  }
}
