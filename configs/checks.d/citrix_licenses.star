def _license_levels(total, levels_param):
    if levels_param == False:
        return None, None
    if levels_param == None:
        return float(total), float(total)
    if type(levels_param) == "list" or type(levels_param) == "tuple":
        if len(levels_param) >= 2:
            first = levels_param[0]
            if type(first) == "int" or type(first) == "float":
                warn = max(0, total - first) if type(first) == "int" else None
                sec = levels_param[1]
                if type(sec) == "int" or type(sec) == "float":
                    crit = max(0, total - sec) if type(sec) == "int" else None
                else:
                    crit = None
                if type(first) == "float":
                    warn = total * (1 - first / 100.0)
                    crit = total * (1 - sec / 100.0) if (type(sec) == "int" or type(sec) == "float") else None
                return warn, crit
    return None, None


def _gather_licenses(ctx):
    res = ctx.run(["lmutil", "lmstat", "-c", "/opt/citrix/LICENSES/license.lic"], mutates=False)
    if res.rc != 0:
        if ctx.file_exists("/opt/citrix/LICENSES/license.lic"):
            content = ctx.file_read("/opt/citrix/LICENSES/license.lic")
            return _parse_license_file(content)
        return {}
    return _parse_lmstat(res.stdout)


def _parse_license_file(content):
    parsed = {}
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            lic_type = parts[0]
            have = int(parts[1]) if parts[1].isdigit() else 0
            used = int(parts[2]) if parts[2].isdigit() else 0
            if have > 0 and used >= 0:
                existing = parsed.get(lic_type, [0, 0])
                existing[0] += have
                existing[1] += used
                parsed[lic_type] = tuple(existing)
    return parsed


def _parse_lmstat(output):
    parsed = {}
    current_lic = None
    total = 0
    used = 0
    for line in output.splitlines():
        s = line.strip()
        if s.startswith("Users of "):
            colon_idx = s.find(":")
            if colon_idx > 0:
                current_lic = s[len("Users of "):colon_idx].strip()
                total = 0
                used = 0
        elif s.startswith("Total of "):
            parts = s.replace("Total of ", "").strip().split()
            if len(parts) >= 1:
                total = int(parts[0]) if parts[0].isdigit() else total
            if current_lic != None:
                existing = parsed.get(current_lic, [0, 0])
                existing[0] += total
                existing[1] += used
                parsed[current_lic] = tuple(existing)
        elif current_lic != None and "license" in s.lower():
            used += 1
    return parsed


def main(ctx, params):
    if params.get("_discover"):
        section = _gather_licenses(ctx)
        if not section:
            return {
                "changed": False,
                "msg": "Citrix licenses not found",
                "data": {"discovery": []},
            }
        out = []
        for license_type in section:
            out.append({
                "item": license_type,
                "params": {"levels": ("crit_on_all", None)},
                "metrics": ["licenses"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    section = _gather_licenses(ctx)
    if not section:
        return {
            "changed": False,
            "msg": "no Citrix licenses found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no data for license type: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    have, used = data
    if not have:
        return {
            "changed": False,
            "msg": "No licenses of that type found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    levels_param = None
    plevels = params.get("levels", ("crit_on_all", None))
    if type(plevels) == "list" or type(plevels) == "tuple":
        if len(plevels) >= 2:
            levels_param = plevels[1]
    warn, crit = _license_levels(have, levels_param)
    if used <= have:
        infotext = "used %d out of %d licenses" % (used, have)
    else:
        infotext = "used %d licenses, but you have only %d" % (used, have)
    state = "OK"
    if warn != None and crit != None:
        if used >= crit:
            state = "CRIT"
        elif used >= warn:
            state = "WARN"
        if state != "OK":
            infotext += " (warn/crit at %d/%d)" % (int(warn), int(crit))
    metrics = {"licenses": float(used)}
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }