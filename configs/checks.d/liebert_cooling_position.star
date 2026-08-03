# Checkmk check: checkmk.liebert_cooling_position
# Translated to read-only Starlark for the yolo-man agent.
# Monitors Liebert cooling position (Free Cooling valve position, %) via SNMP.
# This is an SNMP-based check: it reads the same OIDs the Checkmk SNMP
# section (.1.3.6.1.4.1.476.1.42.3.9.20.1) uses, but talks net-snmp directly
# because the yolo-man runtime has no Checkmk agent installed.

# Column OIDs under the base .1.3.6.1.4.1.476.1.42.3.9.20.1
# From the agent plugin's SNMPTree: oids ["10.1.2.1.5303", "20.1.2.1.5303", "30.1.2.1.5303"]
# These are three columns sharing the same index. The index is the trailing
# numeric suffix after ".5303" in the walked OID.
# Column .10 = name, .20 = value, .30 = unit.

# Detection: the Checkmk plugin uses DETECT_LIEBERT = startswith(
#   ".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.476.1.42"), i.e. the sysObjectID must
# start with .1.3.6.1.4.1.476.1.42 (Emerson/Liebert enterprise OID).

def _walk_column(ctx, host, community, column_oid):
    # Use snmpwalk -Oqn: one line per row "<full-oid> <value>", numeric OID,
    # no type tag, no '='. Value may be quoted for strings.
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, column_oid],
        mutates=False,
    )
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        # Split on the FIRST space: left = OID, right = value.
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        rows[oid] = val
    return rows

def _parse_value(val):
    # snmpwalk -Oqn may quote string values; strip surrounding quotes.
    if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
        val = val[1:-1]
    return val

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")

        # PROBE FOR THE REAL THING FIRST. Liebert gear is identified by its
        # sysObjectID starting with .1.3.6.1.4.1.476.1.42. Verify the device
        # is actually a Liebert unit before offering any service. A rc==127
        # means snmp tools aren't even installed -> not applicable.
        sysid = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysid.rc != 0:
            # Not present / not reachable / not installed -> no services.
            return {"changed": False, "msg": "no Liebert device found",
                    "data": {"discovery": []}}

        base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
        names = _walk_column(ctx, host, community, base + ".10.1.2.1.5303")
        if len(names) == 0:
            # No cooling-position rows at all -> Liebert present but this
            # particular cooling table empty. Still no services to offer.
            return {"changed": False, "msg": "no Liebert cooling position items",
                    "data": {"discovery": []}}

        discovery = []
        # The value/unit columns are queried per index. Index = the OID suffix
        # after ".5303".
        suffix_len = len(base + ".10.1.2.1.5303.")
        for oid, name in names.items():
            if len(oid) <= suffix_len:
                continue
            index = oid[suffix_len:]
            if index == "":
                continue
            dname = _parse_value(name)
            # Only Free Cooling items are discovered (matches the plugin).
            if not dname.startswith("Free Cooling"):
                continue
            discovery.append({
                "item": dname,
                "params": {"warn": 90.0, "crit": 80.0},
                "metrics": ["capacity_perc"],
            })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # ---- CHECK MODE (one item) ----
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Re-probe for the real device first (absence is an answer).
    sysid = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if sysid.rc != 0:
        return {"changed": False,
                "msg": "no Liebert device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    base = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
    # Walk the name column to find the index for this item.
    names = _walk_column(ctx, host, community, base + ".10.1.2.1.5303")
    suffix_len = len(base + ".10.1.2.1.5303.")
    target_index = None
    for oid, name in names.items():
        if len(oid) <= suffix_len:
            continue
        index = oid[suffix_len:]
        if _parse_value(name) == item:
            target_index = index
            break

    if target_index == None:
        return {"changed": False,
                "msg": "item not found: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the value and unit for this index directly by index.
    val_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".20.1.2.1.5303." + target_index],
        mutates=False,
    )
    unit_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         base + ".30.1.2.1.5303." + target_index],
        mutates=False,
    )

    if val_res.rc != 0 or unit_res.rc != 0 or val_res.stdout == "" or unit_res.stdout == "":
        return {"changed": False,
                "msg": "could not read cooling position for " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw_val = _parse_value(val_res.stdout)
    unit = _parse_value(unit_res.stdout)
    if not raw_val.lstrip("-").replace(".", "", 1).isdigit():
        return {"changed": False,
                "msg": "non-numeric cooling position value for " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value = float(raw_val)

    # Thresholds: Checkmk default is min_capacity (90.0, 80.0) i.e. levels_lower.
    # min_capacity = (warn_lower, crit_lower). Warn/CRIT if value FALLS BELOW.
    warn = params.get("warn")
    crit = params.get("crit")
    if warn == None or crit == None:
        mc = params.get("min_capacity", (90.0, 80.0))
        if type(mc) == "list" or type(mc) == "tuple":
            warn = mc[0]
            crit = mc[1]
        else:
            warn = 90.0
            crit = 80.0

    # levels_lower: value <= crit -> CRIT, value <= warn -> WARN, else OK.
    # (warn > crit by Checkmk convention; the default (90,80) is a percentage.)
    state = "OK"
    if value <= crit:
        state = "CRIT"
    elif value <= warn:
        state = "WARN"

    return {"changed": False,
            "msg": "%s: %f %s" % (item, value, unit),
            "data": {"state": state,
                     "metrics": {"capacity_perc": value},
                     "details": ""}}