aironet_default_strength_levels = (-25, -20)
aironet_default_quality_levels = (40, 35)

cisco_airs_oid = ".1.3.6.1.2.1.1.2.0"
cisco_airs_values = (
    ".1.3.6.1.4.1.9.1.525",
    ".1.3.6.1.4.1.9.1.618",
    ".1.3.6.1.4.1.9.1.685",
    ".1.3.6.1.4.1.9.1.758",
    ".1.3.6.1.4.1.9.1.1034",
    ".1.3.6.1.4.1.9.1.1247",
    ".1.3.6.1.4.1.9.1.1873",
    ".1.3.6.1.4.1.9.1.1875",
    ".1.3.6.1.4.1.9.1.1661",
    ".1.3.6.1.4.1.9.1.2240",
)

base_oid = ".1.3.6.1.4.1.9.9.273.1.3.1.1"
col_strength = "3"
col_quality = "4"


def _is_aironet(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ov", host, cisco_airs_oid],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    for oid in cisco_airs_values:
        if val == oid:
            return True
    return False


def _walk_column(ctx, params, column):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    oid = base_oid + "." + column
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0 or res.stdout.strip() == "":
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        full_oid = sp[0]
        value = sp[1]
        if not full_oid.startswith(oid + "."):
            continue
        index = full_oid[len(oid) + 1:]
        if index == "":
            continue
        rows.append((index, value))
    return rows


def _fetch_clients(ctx, params):
    strength_rows = _walk_column(ctx, params, col_strength)
    if len(strength_rows) == 0:
        return []
    strength_indexed = {}
    for index, value in strength_rows:
        strength_indexed[index] = value
    quality_rows = _walk_column(ctx, params, col_quality)
    quality_indexed = {}
    for index, value in quality_rows:
        quality_indexed[index] = value
    merged = {}
    for index in strength_indexed:
        s_val = strength_indexed[index]
        q_val = quality_indexed.get(index, "")
        if s_val != "" and q_val != "":
            merged[index] = (s_val, q_val)
    return [(v[0], v[1]) for v in merged.values()]


def main(ctx, params):
    if not _is_aironet(ctx, params):
        return {
            "changed": False,
            "msg": "not a Cisco Aironet device",
            "data": {
                "discovery": [],
            },
        }

    if params.get("_discover"):
        discovery = [
            {"item": "strength", "params": {}, "metrics": ["strength"]},
            {"item": "quality", "params": {}, "metrics": ["quality"]},
            {"item": "clients", "params": {}, "metrics": ["clients"]},
        ]
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {
                    "cmk/snmp": "on",
                },
            },
        }

    item = params.get("item", "")
    section = _fetch_clients(ctx, params)
    section = [line for line in section if (line[0] != "" and line[1] != "")]

    if len(section) == 0:
        return {
            "changed": False,
            "msg": "No clients currently logged in",
            "data": {
                "state": "OK",
                "metrics": {"clients": 0},
                "details": "",
            },
        }

    if item == "clients":
        count = len(section)
        return {
            "changed": False,
            "msg": "%d clients currently logged in" % count,
            "data": {
                "state": "OK",
                "metrics": {"clients": count},
                "details": "",
            },
        }

    if item == "quality":
        index = 1
        mmin = 0
        mmax = 100
        unit = "%"
        neg = 1
        warn, crit = aironet_default_quality_levels
    elif item == "strength":
        index = 0
        mmin = None
        mmax = 0
        unit = "dB"
        neg = -1
        warn, crit = aironet_default_strength_levels
    else:
        return {
            "changed": False,
            "msg": "unknown item: " + item,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    total = 0
    for line in section:
        v = line[index]
        if v.lstrip("-").isdigit():
            total += int(v)
        else:
            total += 0

    avg = float(total) / float(len(section))

    infotxt = "signal %s at %f%s (warn/crit at %s%s/%s%s)" % (
        item, avg, unit, warn, unit, crit, unit)

    state = "OK"
    if neg * avg <= neg * crit:
        state = "CRIT"
    elif neg * avg <= neg * warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": infotxt,
        "data": {
            "state": state,
            "metrics": {item: avg},
            "details": "",
        },
    }