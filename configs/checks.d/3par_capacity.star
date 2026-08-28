# HPE 3PAR capacity check — translated from checkmk.3par_capacity
# READ-ONLY: never mutates, never writes. Data comes from the array CLI.

_DEFAULT_FS_LEVELS = (90.0, 95.0)
_DEFAULT_FAILED_LEVELS = (0.0, 0.0)


def _is_number(s):
    if s == "":
        return False
    i = 0
    if s[0] == "-" or s[0] == "+":
        i = 1
    if i == len(s):
        return False
    seen_dot = False
    # BY INDEX: a Starlark string is NOT iterable, so `for c in s[i:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_c in range(i, len(s)):
        c = s[_i_c]
        if c >= "0" and c <= "9":
            continue
        if c == "." and not seen_dot:
            seen_dot = True
            continue
        return False
    return True


def _to_float(v):
    if v == None:
        return 0.0
    t = type(v)
    if t == "string":
        if v == "" or not _is_number(v):
            return 0.0
        return float(v)
    if t == "int" or t == "float":
        return float(v)
    return 0.0


def _strip_suffix(s, suffix):
    if s.endswith(suffix):
        return s[:len(s) - len(suffix)]
    return s


def _percent(used, total):
    if total == 0:
        return 0.0
    return used * 100.0 / total


def _state_rank(s):
    ranks = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    return ranks.get(s, 3)


def _gather(ctx, params):
    host = params.get("host", "")
    if host == "":
        return None

    res = ctx.run(
        ["3parcli", "-host", host, "-community", params.get("community", "public"), "showvv", "-d"],
        mutates=False,
    )
    if res.rc != 0:
        return None

    raw = res.stdout.strip()
    if raw == "":
        return None

    # Guard json.decode: empty/invalid -> None
    if raw == "":
        return None
    data = json.decode(raw)
    if type(data) != "dict":
        return None

    section = {}
    for raw_name, raw_values in data.items():
        if type(raw_values) != "dict":
            continue
        total = _to_float(raw_values.get("totalMiB", 0))
        free = _to_float(raw_values.get("freeMiB", 0))
        failed = _to_float(raw_values.get("failedCapacityMiB", 0))
        name = _strip_suffix(raw_name, "Capacity")
        section[name] = {
            "name": name,
            "total_capacity": total,
            "free_capacity": free,
            "failed_capacity": failed,
        }
    return section


def main(ctx, params):
    # ---- DISCOVERY ----
    if params.get("_discover"):
        section = _gather(ctx, params)
        if section == None:
            return {
                "changed": False,
                "msg": "3par array not reachable; no items discovered",
                "data": {"discovery": []},
            }
        out = []
        for disk_name in sorted(section.keys()):
            disk = section[disk_name]
            if disk["total_capacity"] == 0:
                continue
            out.append({
                "item": disk["name"],
                "params": {"levels": _DEFAULT_FS_LEVELS,
                           "failed_capacity_levels": _DEFAULT_FAILED_LEVELS},
                "metrics": ["used_percent", "failed_percent"],
            })
        return {
            "changed": False,
            "msg": "discovered %d 3par capacity items" % len(out),
            "data": {"discovery": out},
        }

    # ---- CHECK ----
    item = params.get("item", "")
    fs_levels = params.get("levels", _DEFAULT_FS_LEVELS)
    failed_levels = params.get("failed_capacity_levels", _DEFAULT_FAILED_LEVELS)

    section = _gather(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "HPE 3PAR array not reachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    disk = section.get(item)
    if disk == None:
        return {
            "changed": False,
            "msg": "no such 3par disk: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = disk["total_capacity"]
    free = disk["free_capacity"]
    failed = disk["failed_capacity"]

    if total == 0:
        return {
            "changed": False,
            "msg": "total capacity is zero for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    used = total - free - failed
    used_pct = _percent(used, total)
    warn = fs_levels[0]
    crit = fs_levels[1]
    state = "CRIT" if used_pct >= crit else ("WARN" if used_pct >= warn else "OK")

    summary = "%s: %f MiB of %f MiB (%f%%)" % (
        item, used, total, used_pct,
    )
    details = "total=%f free=%f failed=%f used_pct=%f%%" % (
        total, free, failed, used_pct,
    )
    metrics = {"used_percent": used_pct}

    if failed != 0.0:
        failed_pct = _percent(failed, total)
        fw = failed_levels[0]
        fc = failed_levels[1]
        fstate = "CRIT" if failed_pct >= fc else ("WARN" if failed_pct >= fw else "OK")
        if _state_rank(fstate) > _state_rank(state):
            state = fstate
        summary = summary + " - Failed: %f%% (%f of %f)" % (
            failed_pct, failed, total,
        )
        metrics["failed_percent"] = failed_pct

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": metrics, "details": details},
    }