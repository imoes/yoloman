# informix_locks.star — Checkmk informix_locks check, translated to read-only Starlark.
# Discovers IBM Informix instances via `onstat` (its lock statistics) and checks
# lock counts against warn/crit levels. Never mutates the system.

LEVELS_DEFAULT = (70, 80)


def _parse_onstat_locks(stdout):
    parsed = {}
    instance = None
    for line in stdout.splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0].startswith("[[[") and fields[0].endswith("]]]"):
            instance = fields[0][3:-3]
            continue
        if instance != None and len(fields) >= 3 and fields[0] == "LOCKS":
            parsed.setdefault(instance, {"locks": fields[1], "type": fields[2]})
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: the Informix onstat binary.
        probe = ctx.run(["onstat", "-"], mutates=False)
        if probe.rc == 127:
            # Not installed → does not apply here.
            return {"changed": False, "msg": "no Informix onstat found", "data": {"discovery": []}}
        # onstat -l dumps locks info per instance; the section format uses [[[instance]]] headers.
        res = ctx.run(["onstat", "-l"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "onstat query failed", "data": {"discovery": []}}
        section = _parse_onstat_locks(res.stdout)
        discovery = []
        for instance in section:
            discovery.append({
                "item": instance,
                "params": {"levels": LEVELS_DEFAULT},
                "metrics": ["locks"],
            })
        return {
            "changed": False,
            "msg": "discovered %d informix lock instances" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK mode — check one item.
    item = params.get("item", "")
    probe = ctx.run(["onstat", "-"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "no Informix onstat found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    res = ctx.run(["onstat", "-l"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "onstat query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _parse_onstat_locks(res.stdout)
    if item not in section:
        return {
            "changed": False,
            "msg": "no informix lock instance found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    data = section[item]
    locks_str = data["locks"]
    locks = int(locks_str) if locks_str.isdigit() else 0
    levels = params.get("levels", LEVELS_DEFAULT)
    warn = levels[0]
    crit = levels[1]
    if locks >= crit:
        state = "CRIT"
    elif locks >= warn:
        state = "WARN"
    else:
        state = "OK"
    return {
        "changed": False,
        "msg": "Type: %s, Locks: %d" % (data["type"], locks),
        "data": {
            "state": state,
            "metrics": {"locks": locks},
            "details": "Type: %s" % data["type"],
        },
    }