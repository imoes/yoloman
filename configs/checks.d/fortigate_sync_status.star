def main(ctx, params):
    # ---- helpers ----
    def snmp_get_oid(oid):
        # Returns bare value via snmpget -Oqv. rc==127 -> not installed.
        res = ctx.run(
            ["snmpget", "-v2c", "-c",
             params.get("community", "public"),
             "-Oqv",
             params.get("host", "localhost"),
             oid],
            mutates=False,
        )
        if res.rc == 127:
            fail("snmpget not installed; cannot query device")
        if res.rc != 0:
            return ""
        return res.stdout.strip()

    def snmp_walk_rows(oid):
        # Walk column OID with -Oqn; returns list of (full_oid, value)
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c",
             params.get("community", "public"),
             "-Oqn",
             params.get("host", "localhost"),
             oid],
            mutates=False,
        )
        rows = []
        if res.rc == 127:
            fail("snmpwalk not installed; cannot query device")
        if res.rc == 0 and res.stdout:
            for line in res.stdout.splitlines():
                sp = line.find(" ")
                if sp < 0:
                    continue
                rows.append((line[:sp], line[sp + 1:].strip()))
        return rows

    def is_fortigate():
        # Detect Fortigate via sysObjectID prefix .1.3.6.1.4.1.12356.101.1.
        soid = snmp_get_oid(".1.3.6.1.2.1.1.2.0")
        if not soid:
            return False
        return soid.startswith(".1.3.6.1.4.1.12356.101.1.")

    STATUS_MAP = {
        "0": ("CRIT", "unsynchronized"),
        "1": ("OK", "synchronized"),
    }

    base = ".1.3.6.1.4.1.12356.101.13.2.1.1"

    # ---- discovery mode ----
    if params.get("_discover"):
        if not is_fortigate():
            # Not a Fortigate on this host; do not yield placeholder items.
            return {"changed": False, "msg": "host is not a Fortigate",
                    "data": {"discovery": []}}

        rows = snmp_walk_rows(base + ".12")  # name column
        # Build per-index list of (index -> name)
        names_by_index = {}
        for full_oid, value in rows:
            idx = full_oid[len(base + ".12") + 1:]
            if idx:
                names_by_index[idx] = value

        if len(names_by_index) <= 1:
            # Real Fortigate check only discovers a service when >1 cluster member
            return {"changed": False, "msg": "no sync status items discovered",
                    "data": {"discovery": []}}

        # Single-service check (no per-index items); item ""
        return {"changed": False,
                "msg": "discovered Sync Status",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]}}

    # ---- check mode (single service, item "") ----
    # Verify the device is a Fortigate before reporting.
    if not is_fortigate():
        return {"changed": False,
                "msg": "host is not a Fortigate",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "sysObjectID does not match Fortigate"}}

    # Pull name + status columns via the numeric index (correlate by index).
    name_rows = snmp_walk_rows(base + ".11")  # name column (oids[0]="11")
    status_rows = snmp_walk_rows(base + ".12")  # status column (oids[1]="12")

    status_by_index = {}
    for full_oid, value in status_rows:
        idx = full_oid[len(base + ".12") + 1:]
        if idx:
            status_by_index[idx] = value

    name_by_index = {}
    for full_oid, value in name_rows:
        idx = full_oid[len(base + ".11") + 1:]
        if idx:
            name_by_index[idx] = value

    if not status_by_index:
        return {"changed": False,
                "msg": "no sync status data available",
                "data": {"state": "UNKNOWN", "metrics": {},
                         "details": "no rows in sync status table"}}

    summaries = []
    worst_state = "OK"
    worse = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

    for idx, status in status_by_index.items():
        name = name_by_index.get(idx, idx)
        if not status:
            summaries.append("%s: Status not available" % name)
            if order["UNKNOWN"] > order[worst_state]:
                worst_state = "UNKNOWN"
            continue
        mapped = STATUS_MAP.get(status, ("UNKNOWN", "Unknown status %s" % status))
        st, st_summary = mapped
        summaries.append("%s: %s" % (name, st_summary))
        if order[st] > order[worst_state]:
            worst_state = st

    summary = "; ".join(summaries)
    if worst_state == "CRIT":
        level = "CRITICAL"
    else:
        level = worst_state

    return {"changed": False,
            "msg": summary,
            "data": {"state": level, "metrics": {}, "details": summary}}