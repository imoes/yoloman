# ===== Checkmk check: checkmk.zorp_connections =====
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# Source plugin reads data from the Checkmk "zorp_connections" agent section,
# which is produced by `zorpctl szig -r zorp.stats.active_connections`.
# On our host we reproduce that same underlying data source directly via
# the zorpctl binary (no Checkmk / cmk agent present).

_ZORP_LEVELS_DEFAULT = [15, 20]


def _is_int(s):
    if s == None or s == "":
        return False
    stripped = s.strip()
    if stripped.startswith("-"):
        return stripped[1:].isdigit()
    return stripped.isdigit()


def _run_zorpctl(ctx):
    """Run the real underlying data source the Checkmk agent section would read.
    Returns the RunResult."""
    return ctx.run(
        ["zorpctl", "szig", "-r", "zorp.stats.active_connections"],
        mutates=False,
    )


def _probe_installed(ctx):
    """Probe for the real thing first. rc == 127 means not installed."""
    res = ctx.run(["zorpctl", "--version"], mutates=False)
    return res.rc == 0


def _parse_output(stdout):
    """Parse `zorpctl szig -r zorp.stats.active_connections` output.

    The raw output lists, for each instance, lines like:
        Instance <name>: walking
        zorp.stats.active_connections: <Number or 'None'>

    We pair them into dict {instance_name -> connection_count}.
    """
    section = {}
    if stdout == None:
        return section
    lines = stdout.splitlines()
    n = len(lines)
    i = 0
    while i < n:
        line = lines[i].strip()
        if line.startswith("Instance ") and line.endswith(":"):
            instance_name = line[len("Instance "):-1].strip()
            i += 1
            found_value = False
            j = i
            inner_done = False
            while j < n and not inner_done:
                cur = lines[j].strip()
                if cur.startswith("Instance ") and cur.endswith(":"):
                    inner_done = True
                elif cur.startswith("zorp.stats.active_connections:"):
                    value_part = cur[len("zorp.stats.active_connections:"):].strip()
                    if value_part == "None" or value_part == "":
                        section[instance_name] = 0
                    elif _is_int(value_part):
                        section[instance_name] = int(value_part)
                    else:
                        section[instance_name] = 0
                    i = j + 1
                    inner_done = True
                    found_value = True
                else:
                    j += 1
            if not found_value:
                i = j
        else:
            i = i + 1
    return section


def _dict_values_sum(section):
    total = 0
    for v in section.values():
        total += v
    return total


def _grade_levels(total, levels):
    """grade against upper levels: WARN if >= warn, CRIT if >= crit.
    levels is a pair (warn, crit) — Checkmk default fixed (15, 20)."""
    warn = levels[0] if len(levels) >= 1 else None
    crit = levels[1] if len(levels) >= 2 else None
    if crit != None and total >= crit:
        return "CRIT"
    if warn != None and total >= warn:
        return "WARN"
    return "OK"


def _resolve_levels(params):
    """Resolve the check_levels 'levels' parameter to a plain [warn, crit] list.
    Accepts either ("fixed", (warn, crit)) or already (warn, crit)."""
    levels_raw = params.get("levels", _ZORP_LEVELS_DEFAULT)
    if type(levels_raw) == "tuple" or type(levels_raw) == "list":
        if len(levels_raw) >= 2 and type(levels_raw[1]) == "tuple":
            return list(levels_raw[1])
        return list(levels_raw)
    return list(_ZORP_LEVELS_DEFAULT)


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        if not _probe_installed(ctx):
            # Product not on host -> honest absence: empty discovery
            return {
                "changed": False,
                "msg": "no zorp installation found",
                "data": {"discovery": []},
            }
        section = _parse_output(_run_zorpctl(ctx).stdout)
        if not section:
            # No instances / data -> not applicable on this host
            return {
                "changed": False,
                "msg": "no zorp connections found",
                "data": {"discovery": []},
            }
        metric_names = ["connections"]
        discovery = []
        for instance_name in section.keys():
            discovery.append({
                "item": instance_name,
                "params": {},
                "metrics": metric_names,
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE ----
    # Single-service check in Checkmk: one Service with item "".
    # On our host we mirror that: check the whole section as one item.
    if not _probe_installed(ctx):
        return {
            "changed": False,
            "msg": "no zorp installation found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _parse_output(_run_zorpctl(ctx).stdout)
    if not section:
        return {
            "changed": False,
            "msg": "no zorp instances found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build per-instance summary lines (State.OK for each)
    details_lines = []
    for elem in section.items():
        details_lines.append("%s: %d" % elem)

    total = _dict_values_sum(section)
    levels = _resolve_levels(params)
    state = _grade_levels(total, levels)

    summary = "Total connections: %d" % total
    details = ";\n".join(details_lines) + "\n" + summary

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"connections": total},
            "details": details,
        },
    }