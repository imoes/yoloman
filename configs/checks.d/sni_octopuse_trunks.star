# Checkmk check: checkmk.sni_octopuse_trunks
# Translated to a read-only Starlark check module for the yolo-man agent.
#
# This check monitors Siemens HiPath Octopus trunk ports via SNMP.
# The SNMP Tree base is: .1.3.6.1.4.1.231.7.2.9.3.8.1
# Columns walked: 1=portindex, 2=cardindex, 3=porttype, 4=portstate

def _snmp_get(ctx, host, community, oid, version):
    res = ctx.run(
        ["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res

def _snmp_walk(ctx, host, community, oid, version):
    res = ctx.run(
        ["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res

def _probe_sys_descr(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    res = _snmp_get(ctx, host, community, "1.3.6.1.2.1.1.1.0", version)
    if res == None:
        return None
    return res.stdout.strip()

def _detect_octopuse(ctx, params):
    descr = _probe_sys_descr(ctx, params)
    if descr == None:
        return False
    return "agent for hipath" in descr.lower()

def _parse_walk_table(ctx, params, column_base):
    """Walk an SNMP table column with -Oqn and return index->value dict."""
    res = _snmp_walk(ctx, params.get("host", "localhost"),
                     params.get("community", "public"),
                     column_base, params.get("version", "2c"))
    if res == None:
        return None
    table = {}
    for line in res.stdout.splitlines():
        # Format: <oid> <value>  (value may be empty for end-of-table)
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        # index is the suffix after the column base
        idx = oid[len(column_base) + 1:]
        # Skip the final row marker (e.g., .0 at end of walk)
        table[idx] = value
    return table

def _get_trunk_table(ctx, params):
    """Fetch the octoPortTable columns and assemble rows.

    Returns list of (portindex, cardindex, porttype, portstate) or None.
    Column base: .1.3.6.1.4.1.231.7.2.9.3.8.1
    Columns: 1=portindex, 2=cardindex, 3=porttype, 4=portstate
    """
    base = "1.3.6.1.4.1.231.7.2.9.3.8.1"

    col1 = _parse_walk_table(ctx, params, base + ".3")   # portindex
    col2 = _parse_walk_table(ctx, params, base + ".4")   # cardindex
    col3 = _parse_walk_table(ctx, params, base + ".5")   # porttype
    col4 = _parse_walk_table(ctx, params, base + ".6")   # portstate

    if col1 == None or col2 == None or col3 == None or col4 == None:
        return None

    # Correlate rows by index
    indices = []
    for idx in col1:
        indices.append(idx)
    # Deduplicate while preserving order
    seen = {}
    unique_indices = []
    for idx in indices:
        if idx not in seen:
            seen[idx] = True
            unique_indices.append(idx)

    rows = []
    for idx in unique_indices:
        portindex = col1.get(idx, "")
        cardindex = col2.get(idx, "")
        porttype = col3.get(idx, "")
        portstate = col4.get(idx, "")
        # Skip end-of-table markers (empty values)
        if portindex == "" and cardindex == "" and porttype == "" and portstate == "":
            continue
        rows.append((portindex, cardindex, porttype, portstate))

    return rows

def main(ctx, params):
    _TRUNKPORTS = ("S0 trunk: extern",)

    # Discovery mode
    if params.get("_discover"):
        if not _detect_octopuse(ctx, params):
            return {"changed": False, "msg": "Siemens Octopus not detected",
                    "data": {"discovery": []}}

        rows = _get_trunk_table(ctx, params)
        if rows == None:
            return {"changed": False, "msg": "no trunk ports found",
                    "data": {"discovery": []}}

        discovery = []
        seen_items = {}
        for portindex, cardindex, porttype, portstate in rows:
            if len(porttype) != 2 and len(porttype) != 1:
                pass
            if porttype in _TRUNKPORTS and portstate == "2":
                item = cardindex + "/" + portindex
                if item not in seen_items:
                    seen_items[item] = True
                    discovery.append({
                        "item": item,
                        "params": {},
                        "metrics": [],
                    })

        return {
            "changed": False,
            "msg": "discovered %d trunk ports" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")

    if not _detect_octopuse(ctx, params):
        return {
            "changed": False,
            "msg": "Siemens Octopus not detected",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    rows = _get_trunk_table(ctx, params)
    if rows == None:
        return {
            "changed": False,
            "msg": "no trunk port data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    for portindex, cardindex, porttype, portstate in rows:
        if item == cardindex + "/" + portindex:
            if portstate == "1":
                return {
                    "changed": False,
                    "msg": "Port [%s] is inactive" % porttype,
                    "data": {
                        "state": "CRIT",
                        "metrics": {},
                        "details": "",
                    },
                }
            return {
                "changed": False,
                "msg": "Port [%s] is active" % porttype,
                "data": {
                    "state": "OK",
                    "metrics": {},
                    "details": "",
                },
            }

    return {
        "changed": False,
        "msg": "UNKW - unknown data received from agent",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "",
        },
    }