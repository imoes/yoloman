_STATUS_MAP = {
    "0": ("UNKNOWN", "unknown"),
    "1": ("CRIT", "removed"),
    "2": ("CRIT", "off"),
    "3": ("WARN", "underspeed"),
    "4": ("WARN", "overspeed"),
    "5": ("OK", "ok"),
    "6": ("UNKNOWN", "maxstate"),
}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.11.2.14.11.5.1.54.2.1.1"

    if params.get("_discover"):
        sys_desc_res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sys_desc_res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP get failed for sysDescr",
                "data": {"discovery": []},
            }
        sys_desc = sys_desc_res.stdout.strip()
        if not sys_desc or "hp" not in sys_desc.lower():
            return {
                "changed": False,
                "msg": "host is not an HP device",
                "data": {"discovery": []},
            }
        if "5406rzl2" not in sys_desc.lower() and "5412rzl2" not in sys_desc.lower():
            return {
                "changed": False,
                "msg": "host does not match HP 5406zl/5412zl",
                "data": {"discovery": []},
            }
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []},
            }
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0]
            tray_index = parts[1]
            fan_index = oid_full[len(base_oid) + 1:]
            if fan_index == "":
                continue
            discovery.append({
                "item": "%s/%s" % (tray_index, fan_index),
                "params": {},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d fans" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if "/" not in item:
        return {
            "changed": False,
            "msg": "invalid item format: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
        tray_index, fan_index = item.split("/", 1)
    tray_index, fan_index = item.split("/", 1)
    oid = "%s.%s.%s" % (base_oid, tray_index, fan_index)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    raw = res.stdout.strip()
    if raw == "":
        return {
            "changed": False,
            "msg": "no data for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    entry = _STATUS_MAP.get(raw)
    if entry == None:
        return {
            "changed": False,
            "msg": "unknown fan state %s for %s" % (raw, item),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    state, status_txt = entry
    return {
        "changed": False,
        "msg": "Fan %s: %s" % (item, status_txt),
        "data": {"state": state, "metrics": {}, "details": ""},
    }