# Checkmk check: oracle_diva_csm_drive (translated to read-only Starlark)
# Source: cmk/plugins/oracle/agent_based/oracle_diva_csm.py
# This is an SNMP-based check. The DIVA CSM library drive status OID tree:
#   Drive status table: .1.3.6.1.4.1.110901.1.2.2.1.1 (columns 3=name, 8=status)
# Status reading -> state:
#   1 = online (OK), 2 = offline (CRIT), 3 = unknown (WARN), else UNKNOWN(3)

def _item_name(name, element_id):
    s = name + " " + element_id
    return s.strip()

def _status_result(reading):
    if reading == "1":
        return 0, "online"
    if reading == "2":
        return 2, "offline"
    if reading == "3":
        return 1, "unknown"
    return 3, "unexpected state"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    drive_base = ".1.3.6.1.4.1.110901.1.2.2.1.1"

    # Probe for the real thing: confirm the device responds for the drive OID.
    # rc == 127 means snmpwalk is not installed -> not applicable.
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, drive_base],
        mutates=False,
    )
    if walk.rc == 127:
        # Tool missing; this product is not reachable on the host.
        if params.get("_discover"):
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if walk.rc != 0 and not walk.stdout:
        # No devices present -> empty discovery / UNKNOWN, never OK.
        if params.get("_discover"):
            return {"changed": False, "msg": "no DIVA CSM drives found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no DIVA CSM drives found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the table walk: lines "<OID>.<index> <value>"
    rows = {}  # index -> {col: value}
    for line in walk.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid_full = sp[0]
        value = sp[1].strip()
        # column suffix is the last numeric component of the OID
        oid_parts = oid_full.split(".")
        if len(oid_parts) < 2:
            continue
        col = oid_parts[-2]
        index = oid_full[len(drive_base) + 1:]
        idx_key = oid_parts[len(drive_base.split(".")) - 1:-1]
        # Build a stable index string per row
        idx_str = ".".join(oid_parts[len(drive_base.split(".")) - 1:-1])
        if col not in rows:
            rows[idx_str] = {}
        rows[idx_str][col] = value

    if params.get("_discover"):
        discovery = []
        for idx_str in sorted(rows.keys()):
            entry = rows[idx_str]
            name_val = entry.get("3", "")
            item = _item_name("Drive", name_val)
            if item == "":
                continue
            discovery.append({
                "item": item,
                "params": {},
                "metrics": [],
            })
        return {"changed": False,
                "msg": "discovered %d drives" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode: examine one item named by params.item ("" -> single-service).
    item = params.get("item", "")
    # Find the row whose display name matches the requested item.
    found = None
    for idx_str in rows.keys():
        entry = rows[idx_str]
        name_val = entry.get("3", "")
        candidate = _item_name("Drive", name_val)
        if candidate == item:
            found = entry
            break

    if found == None:
        return {"changed": False,
                "msg": "no such drive: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = found.get("8", "")
    state, summary = _status_result(reading)
    # Map numeric state to Checkmk state names
    state_names = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    sname = state_names.get(state, "UNKNOWN")
    return {"changed": False,
            "msg": "%s %s" % (item, summary),
            "data": {"state": sname, "metrics": {}, "details": ""}}