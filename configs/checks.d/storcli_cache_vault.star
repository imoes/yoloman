def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["storcli", "/c0", "/v0", "show", "all"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "storcli not installed", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "storcli failed: " + res.stderr, "data": {"discovery": []}}
        raw = res.stdout
        section = parse_section(raw)
        if not section:
            return {"changed": False, "msg": "no cache vaults found", "data": {"discovery": []}}
        discovery = []
        for item in sorted(section.keys()):
            discovery.append({"item": item, "params": {}, "metrics": ["capacitance_perc"]})
        return {"changed": False, "msg": "discovered %d cache vaults" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["storcli", item, "show", "all"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "storcli not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "msg": "storcli not installed"}}
    if res.rc != 0:
        return {"changed": False, "msg": "storcli failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = parse_section(res.stdout)
    vault = section.get(item)
    if vault == None:
        return {"changed": False, "msg": "no cache vault " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    metrics = {"capacitance_perc": vault.capacitance_perc}
    details = "State: " + vault.state + ", Capacitance: " + ("%f%%" % vault.capacitance_perc)
    if vault.needs_replacement:
        details = details + ", Replacement required"
    state = "OK" if vault.state == "Optimal" else "CRIT"
    if vault.needs_replacement and state == "OK":
        state = "WARN"
    if vault.state != "Optimal":
        state = "CRIT"
    msg = vault.state.capitalize()
    if vault.needs_replacement:
        msg = msg + ", Replacement required"
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}


def parse_section(raw):
    section = {}
    cur_item = None
    props = {}
    known = ["State", "Replacement required", "Capacitance"]
    for line in raw.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("Controller ="):
            if cur_item != None:
                section[cur_item] = props
            cid = s.split("=", 1)[1].strip().split()[0]
            cur_item = "/c" + cid
            props = {}
            continue
        for prop in known:
            if s.startswith(prop + " =") or s.startswith(prop + "="):
                val = s[len(prop):].strip()
                if val.startswith("="):
                    val = val[1:].strip()
                props[prop] = val
    if cur_item != None:
        section[cur_item] = props
    result = {}
    for k, v in section.items():
        if "State" not in v:
            continue
        state = expand_abbreviation(v["State"])
        needs_rep = v.get("Replacement required", "No").lower() != "no"
        cap_raw = v.get("Capacitance", "0")
        cap_str = cap_raw.split("%")[0].strip()
        cap = float(cap_str) if cap_str.replace(".", "", 1).isdigit() else 0.0
        result[k] = {"state": state, "needs_replacement": needs_rep, "capacitance_perc": cap}
    return result


def expand_abbreviation(s):
    m = {
        "Opt": "Optimal",
        "Optl": "Optimal",
        "Dgd": "Degraded",
        "Dgd.": "Degraded",
        "Rbld": "Rebuild",
        "Rbl": "Rebuild",
        "Unk": "Unknown",
        "Unkn": "Unknown",
        "Msng": "Missing",
        "Off": "Offline",
        "Onl": "Online",
    }
    for abbr, full in sorted(m.keys(), key=len, reverse=True):
        if s == abbr or s.startswith(abbr):
            return full
    return s