"""A registry value as a DECLARED resource — and the conflict report against Group Policy.

Two things live here because they are two halves of one idea: what *we* declare a Windows registry value
should be, and what *Group Policy* declares it should be. The report is the reason the declaration is worth
having at all.

WHY A REGISTRY RESOURCE AT ALL, and why it is not a file. The config plane declares FILE paths and merges
values into them through a codec. A registry key is a config file that is not a file: it is typed (a DWORD is
not the string "1"), hierarchical, and a value's absence differs from a value set to empty — three
distinctions a file-shaped resource flattens. So it reuses the whole authoring/merge/generation machinery
(ConfigPolicy and HostConfigResource, keyed by `path`, merged per key, with `key_sources` naming the winning
scope) and changes exactly one thing: `type = "registry"`, and each value carries its own registry type.

WHY THE HIVE IS NOT IN HERE. Measured on the test host: 323 995 keys in HKLM\\SOFTWARE alone, 70 MB, three
minutes to enumerate. Declared keys cost the size of what you declare; the hive costs more than everything
this system manages put together (docs/windows-management.md §8a). A value nobody declared is not drift, it is
the operating system.

THE CONFLICT REPORT is the payoff. Where a GPO and a declaration touch the same value, **the GPO wins on the
host** — Windows re-applies it on every policy refresh — so a convergence run fights it forever: the value
reverts, the report says "changed" again next pass, and nothing in the system explains why. Naming the
conflict is the difference between a mystery and a decision.
"""

from __future__ import annotations

from typing import Any

#: Where Group Policy writes. A declared value under one of these prefixes is in the GPO's territory even
#: when no GPO currently sets that exact name — the next policy refresh may claim it, and the report says so.
#: Measured: these subtrees hold 57 values on the test host, against 324 000 keys in the hive.
POLICY_PREFIXES = (
    r"HKEY_LOCAL_MACHINE\SOFTWARE\Policies",
    r"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies",
    r"HKEY_CURRENT_USER\SOFTWARE\Policies",
    r"HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies",
)

#: The abbreviations an operator types, and the long form the registry itself reports. Both spellings must
#: resolve to one key or a comparison silently finds nothing: `HKLM:\SOFTWARE\X` and
#: `HKEY_LOCAL_MACHINE\SOFTWARE\X` are the same place, and the agent reports the second.
_HIVES = {
    "HKLM": "HKEY_LOCAL_MACHINE",
    "HKCU": "HKEY_CURRENT_USER",
    "HKCR": "HKEY_CLASSES_ROOT",
    "HKU": "HKEY_USERS",
    "HKCC": "HKEY_CURRENT_CONFIG",
}


def canonical_key(path: str) -> str:
    """One spelling for one key: long hive name, backslashes, no trailing separator, case preserved.

    Case is PRESERVED rather than folded, because a registry key's case is cosmetic to Windows but meaningful
    to a person reading a report — and the comparison below folds case itself, where folding belongs.
    """
    text = (path or "").strip().replace("/", "\\").rstrip("\\")
    text = text.replace(":", "", 1) if ":\\" in text[:6] else text
    head, _, rest = text.partition("\\")
    return f"{_HIVES.get(head.upper(), head)}\\{rest}" if rest else _HIVES.get(head.upper(), head)


def declared_values(resources: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The registry values a host's effective config declares: [{path, name, type, value, source}].

    Takes `config_desired.effective_resources()` output, so a declaration inherits the whole GPO-style
    precedence (group < OU < site < host) and arrives with `source` already naming the winning scope. A
    registry resource is one whose `type` is "registry"; everything else here is a file and is skipped.
    """
    out: list[dict[str, Any]] = []
    for entry in resources or []:
        resource = entry.get("resource") or {}
        if (resource.get("type") or entry.get("type")) != "registry":
            continue
        key = canonical_key(entry.get("path") or "")
        key_sources = entry.get("key_sources") or {}
        for name, spec in (resource.get("values") or {}).items():
            # A value is {"type": …, "data": …}; a bare scalar is accepted and its type left unstated, since
            # an operator who wrote `{"Foo": 1}` has said what they mean and the agent's registry module
            # refuses to guess a type it was not given.
            typed = isinstance(spec, dict)
            out.append({
                "path": key,
                "name": name,
                "type": (spec.get("type") if typed else None),
                "value": (spec.get("data") if typed else spec),
                # The scope that won this key, not the resource's overall source: a per-key merge whose report
                # names only the strongest contributor would hide where an individual value came from.
                "source": key_sources.get(name) or entry.get("source"),
            })
    return out


#: What the imposed side of the comparison actually is, and the reason the outcomes below are worded as
#: carefully as they are. MEASURED on the test host: `gpresult /X` reports WHICH GPOs applied and which
#: client-side extensions ran, and carries NO per-setting data at all (element census: ExtensionGuid,
#: ExtensionName, ExtensionStatus — no RegistrySetting anywhere). So the values we compare against are read
#: from the Group-Policy-OWNED REGISTRY AREA, which tells us what is in there right now but not who put it
#: there — and we write into that same area ourselves.
#:
#: That distinction is the whole difference between a report and a report that confirms itself: after applying
#: our own declaration, the area holds OUR value, and a naive reading would call that "Group Policy agrees
#: with us". It proves nothing. Hence: a DIFFERING value is evidence of a foreign authority (we would have
#: written ours), an EQUAL value is evidence of nothing.
IMPOSED_SOURCE_AREA = "registry-policy-area"
#: Reserved for the day a source can name the author per value (RSoP extension data where a GPO provides it,
#: or the GPO's own registry.pol). Then an equal value really does mean agreement.
IMPOSED_SOURCE_RSOP = "rsop-extension-data"


def conflicts(declared: list[dict[str, Any]], imposed: list[dict[str, Any]],
              imposed_source: str = IMPOSED_SOURCE_AREA) -> dict[str, Any]:
    """Compare our declarations against the Group-Policy-owned registry area.

    Four outcomes, exhaustive and named — the point being that three of them are NOT conflicts and must not be
    reported as if they were:

      overridden   the area holds a DIFFERENT value under the same name. Another authority owns it: we would
                   have written ours, so something else did. A policy refresh restores that authority's value,
                   every refresh, forever, and a convergence run fights it. This is the finding.
      same_value   the area holds our value. NOT reported as agreement — with `imposed_source` =
                   registry-policy-area this may simply be our own write reflected back (see above), so the
                   honest claim is "nothing here contradicts us", and the explanation says so.
      in_gp_scope  we declare a value under a policy prefix where nothing currently sets that name. Not a
                   conflict yet — and the one to watch, because the next policy refresh can claim it.
      ours_alone   we declare it outside policy territory. The normal case; counted, not listed.

    Compared case-insensitively on (path, name) because Windows is, and by STRING on the value because that is
    what both sides report — a DWORD 3 and the string "3" are the same state as far as this report can
    honestly claim, and overstating certainty here would produce conflicts that are not real.
    """
    trusted_author = imposed_source == IMPOSED_SOURCE_RSOP
    by_key = {
        (canonical_key(i.get("path") or "").lower(), (i.get("name") or "").lower()): i
        for i in imposed or []
    }
    overridden: list[dict[str, Any]] = []
    same_value: list[dict[str, Any]] = []
    in_scope: list[dict[str, Any]] = []
    ours_alone = 0

    for value in declared or []:
        key = (canonical_key(value["path"]).lower(), (value.get("name") or "").lower())
        gp = by_key.get(key)
        if gp is not None:
            row = {
                **value,
                "gp_value": gp.get("value"),
                "gp_type": gp.get("type"),
            }
            if str(value.get("value")) == str(gp.get("value")):
                row["explanation"] = (
                    f"{value['name']} already holds {value.get('value')!r} in the Group-Policy-owned area, so "
                    f"nothing here contradicts this declaration."
                ) + ("" if trusted_author else (
                    " This is NOT proof that Group Policy agrees: the value was read from the registry area "
                    "both authorities write to, and it may be this declaration's own last write reflected "
                    "back. It becomes a conflict the moment a GPO sets it to something else."
                ))
                same_value.append(row)
            else:
                who = "Group Policy" if trusted_author else "Another authority"
                row["explanation"] = (
                    f"{who} holds {value['name']} = {gp.get('value')!r} in the Group-Policy-owned registry "
                    f"area and this policy declares {value.get('value')!r}. That value is not ours — we would "
                    f"have written ours — and Windows restores the policy area on every refresh, so a "
                    f"convergence run will report a change, write ours, and find it reverted on every pass. "
                    f"Change it in Group Policy, or stop declaring it here."
                )
                overridden.append(row)
            continue

        if any(canonical_key(value["path"]).lower().startswith(p.lower()) for p in POLICY_PREFIXES):
            in_scope.append({
                **value,
                "explanation": (
                    "This value sits under a Group Policy prefix that no GPO currently sets. It converges "
                    "today, and the next policy refresh can claim it without anything changing on our side."
                ),
            })
            continue

        ours_alone += 1

    return {
        # WHERE THE OTHER SIDE CAME FROM travels with the report, because the strength of every claim below
        # depends on it and a consumer (a UI, an AI summarising it) has no other way to know.
        "imposed_source": imposed_source,
        "imposed_names_author": trusted_author,
        "overridden": overridden,
        "same_value": same_value,
        "in_gp_scope": in_scope,
        "ours_alone": ours_alone,
        "declared_total": len(declared or []),
        "imposed_total": len(imposed or []),
        # The headline number is the one that needs action. Reporting "3 findings" when two of them are
        # agreements is how a report teaches people to ignore it.
        "conflict_count": len(overridden),
    }
