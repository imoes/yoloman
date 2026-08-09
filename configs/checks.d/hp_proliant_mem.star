def main(ctx, params):
    if params.get("_discover"):
        proliant = _detect_proliant(ctx)
        if not proliant:
            return {"changed": False, "msg": "no HP ProLiant system detected",
                    "data": {"discovery": []}}
        section = _fetch_memory(ctx, params)
        discovery = []
        for number in section:
            mod = section[number]
            if mod["size"] > 0 and mod["status"] != "notPresent":
                discovery.append({"item": number, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d modules" % len(discovery),
                "data": {"discovery": discovery}}

    if not _detect_proliant(ctx):
        return {"changed": False,
                "msg": "no HP ProLiant system detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    item = params.get("item", "")
    section = _fetch_memory(ctx, params)
    module = section.get(item)
    if module == None:
        return {"changed": False,
                "msg": "module %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = []
    parts.append("Board: %s" % module["board"])
    parts.append("Number: %s" % module["number"])
    parts.append("Type: %s" % module["typ"])
    parts.append("Size: %s" % _render_bytes(module["size"]))

    status_state = _MEM_TEXT2STATE_MAP.get(module["status"], "UNKNOWN")
    parts.append("Status: %s [%s]" % (module["status"], status_state))

    cond_state = _COND_TEXT2STATE_MAP.get(module["condition"], "UNKNOWN")
    parts.append("Condition: %s [%s]" % (module["condition"], cond_state))

    states = [status_state, cond_state]
    if "CRIT" in states:
        level = "CRIT"
    elif "WARN" in states:
        level = "WARN"
    else:
        level = "OK"
    return {"changed": False, "msg": "; ".join(parts),
            "data": {"state": level, "metrics": {}, "details": "; ".join(parts)}}


def _detect_proliant(ctx):
    oid = ".1.3.6.1.4.1.232.2.2.4.2.0"
    community = params_get(ctx, "community", "public")
    host = params_get(ctx, "host", "localhost")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                  mutates=False)
    if res.rc == 127 or not res.stdout:
        return False
    val = res.stdout.strip().strip('"')
    v = val.lower()
    return "proliant" in v or "storeeasy" in v or "synergy" in v


def params_get(ctx, key, default):
    p = getattr(ctx, "params", None)
    if p == None:
        return default
    return p.get(key, default)


def _fetch_memory(ctx, params):
    base = ".1.3.6.1.4.1.232.6.2.14.13.1"
    cols = {
        "1": "number", "2": "board", "3": "cpu_num", "6": "size",
        "7": "typ", "12": "serial", "19": "status", "20": "condition",
    }
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    raw = {}
    for col_oid in cols:
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                       base + "." + col_oid], mutates=False)
        if res.rc != 0:
            return {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            line_oid = parts[0]
            val = parts[1].strip()
            idx = line_oid[len(base + "." + col_oid) + 1:]
            if not raw.get(idx):
                raw[idx] = {}
            raw[idx][cols[col_oid]] = val
    section = {}
    for idx in raw:
        r = raw[idx]
        typ_raw = r.get("typ", "")
        size_str = r.get("size", "0")
        size_bytes = int(size_str) * 1024 if size_str.isdigit() else 0
        cpu_str = r.get("cpu_num", "0")
        cpu_num = int(cpu_str) if cpu_str.isdigit() else 0
        module = {
            "number": r.get("number", idx),
            "board": r.get("board", ""),
            "cpu_num": cpu_num,
            "size": size_bytes,
            "typ": _MAP_TYPES_MEMORY.get(typ_raw, "unknown (%s)" % typ_raw),
            "serial": r.get("serial", ""),
            "status": _STATUS_MAP.get(r.get("status", ""), "unknown"),
            "condition": _CONDITION_MAP.get(r.get("condition", ""), "unknown"),
        }
        section[module["number"]] = module
    return section


_STATUS_MAP = {
    "1": "other", "2": "notPresent", "3": "present", "4": "good",
    "5": "add", "6": "upgrade", "7": "missing", "8": "doesNotMatch",
    "9": "notSupported", "10": "badConfig", "11": "degraded",
    "12": "spare", "13": "partial",
}

_CONDITION_MAP = {
    "1": "other", "2": "ok", "3": "degraded",
    "4": "degradedModuleIndexUnknown",
}

_MEM_TEXT2STATE_MAP = {
    "other": "UNKNOWN", "notPresent": "UNKNOWN", "present": "WARN",
    "good": "OK", "add": "WARN", "upgrade": "WARN", "missing": "CRIT",
    "doesNotMatch": "CRIT", "notSupported": "CRIT", "badConfig": "CRIT",
    "degraded": "CRIT", "spare": "OK", "partial": "WARN",
}

_COND_TEXT2STATE_MAP = {
    "other": "UNKNOWN", "ok": "OK", "degraded": "CRIT",
    "failed": "CRIT", "degradedModuleIndexUnknown": "UNKNOWN",
}

_MAP_TYPES_MEMORY = {
    "1": "other", "2": "board", "3": "cpqSingleWidthModule",
    "4": "cpqDoubleWidthModule", "5": "simm", "6": "pcmcia",
    "7": "compaq-specific", "8": "DIMM", "9": "smallOutlineDimm",
    "10": "RIMM", "11": "SRIMM", "12": "FB-DIMM", "13": "DIMM DDR",
    "14": "DIMM DDR2", "15": "DIMM DDR3", "16": "DIMM FBD2",
    "17": "FB-DIMM DDR2", "18": "FB-DIMM DDR3", "19": "DIMM DDR4",
    "20": "HPE Specific", "21": "DIMM DDR5",
}


def _render_bytes(n):
    if n < 1024:
        return "%d B" % n
    if n < 1024 * 1024:
        return "%f KB" % (n / 1024.0)
    if n < 1024 * 1024 * 1024:
        return "%f MB" % (n / (1024.0 * 1024))
    return "%f GB" % (n / (1024.0 * 1024 * 1024))