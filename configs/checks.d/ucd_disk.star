# Constants (module-level)
OID_BASE = ".1.3.6.1.4.1.2021.9.1"
OID_PATH = OID_BASE + ".2"
OID_TOTAL = OID_BASE + ".6"
OID_AVAIL = OID_BASE + ".7"

def _parse_snmp_value(value_str):
    """Convert SNMP value string to int; return 0 on error."""
    if value_str == None:
        return 0
    v = value_str.strip()
    if v == "":
        return 0
    # Handle negative numbers
    if v.startswith("-"):
        v = v[1:]
        if v == "" or not v.isdigit():
            return 0
        return -int(v)
    if not v.isdigit():
        return 0
    return int(v)

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"), OID_BASE
        ], mutates=False)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)

        paths = {}
        totals = {}
        avails = {}

        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            suffix = oid_part.rsplit(".", 1)[-1]
            value_type, value = value_part.split(":", 1)
            value = value.strip()
            base_oid = oid_part.rsplit(".", 1)[0]
            if base_oid == OID_PATH:
                paths[suffix] = value.strip('"')
            elif base_oid == OID_TOTAL:
                totals[suffix] = _parse_snmp_value(value)
            elif base_oid == OID_AVAIL:
                avails[suffix] = _parse_snmp_value(value)

        discovered = []
        for suffix in paths:
            path = paths.get(suffix)
            if path and suffix in totals and suffix in avails:
                default_warn = params.get("levels", (80, 90))
                warn = default_warn[0] if len(default_warn) >= 1 else 80
                crit = default_warn[1] if len(default_warn) >= 2 else 90
                discovered.append({
                    "item": path,
                    "params": {"levels": (warn, crit)},
                    "metrics": ["used_percent"]
                })
        return {
            "changed": False,
            "msg": "discovered %d filesystems" % len(discovered),
            "data": {"discovery": discovered}
        }

    item = params.get("item", "")
    warn, crit = 80, 90
    if "levels" in params:
        levels = params["levels"]
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]

    def snmpget_single(oid):
        res = ctx.run([
            "snmpget", "-v2c", "-c", params.get("community", "public"),
            "-On", "-Oqn", params.get("host", "localhost"), oid
        ], mutates=False)
        if res.rc != 0 or res.stdout == None or res.stdout.strip() == "":
            return None
        return res.stdout.strip().split(": ", 1)[-1]

    path_val = snmpget_single(OID_PATH)
    if path_val != item:
        return {
            "changed": False,
            "msg": "filesystem not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    total_kb_str = snmpget_single(OID_TOTAL)
    avail_kb_str = snmpget_single(OID_AVAIL)

    if total_kb_str == None or avail_kb_str == None:
        return {
            "changed": False,
            "msg": "could not retrieve filesystem data for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    total_kb = _parse_snmp_value(total_kb_str)
    avail_kb = _parse_snmp_value(avail_kb_str)

    if total_kb == 0:
        return {
            "changed": False,
            "msg": "filesystem size is zero for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    size_mb = float(total_kb) / 1024.0
    avail_mb = float(avail_kb) / 1024.0
    used_mb = size_mb - avail_mb
    used_percent = (used_mb / size_mb) * 100.0 if size_mb > 0 else 0.0

    state = "OK"
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Size: %f MB, Used: %f%%" % (size_mb, used_percent),
        "data": {
            "state": state,
            "metrics": {"used_percent": used_percent},
            "details": ""
        }
    }