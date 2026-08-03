# Translated Checkmk check: oracle_diva_csm_archive
# A read-only Starlark check module for the yolo-man agent.
# Monitors Oracle DIVA CSM archive (manager) status via SNMP.

# OID bases used by the original SNMP section (oracle_diva_csm).
# Section 3 (index into the agent's StringTable list) holds actor/manager status.
LIB_STATUS_OID = ".1.3.6.1.4.1.110901.1.2.1.1.1"   # library status (idx 0)
DRIVE_STATUS_OID = ".1.3.6.1.4.1.110901.1.2.2.1.1"   # drive status (idx 1)
ACTOR_STATUS_OID = ".1.3.6.1.4.1.110901.1.3.1.1"     # actor status (idx 2)
ARCHIVE_STATUS_OID = ".1.3.6.1.4.1.110901.1.4"       # archive OIDs (idx 3/4/5)


def _snmp_get(ctx, host, community, oid):
    """Fetch a single scalar OID with net-snmp, returning bare value or None."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _snmp_walk(ctx, host, community, oid):
    """Walk a table OID with net-snmp, returning list of (oid, value) pairs."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        # -Oqn => "<oid> <value>"
        parts = line.split(" ", 1)
        if len(parts) == 2:
            rows.append((parts[0], parts[1].strip()))
    return rows


def _status_result(reading):
    """Map DIVA status reading to (state_level, summary text)."""
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
    item = params.get("item", "")

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # Probe for the real thing first: the DIVA agent must be reachable.
        sys_oid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if sys_oid == None:
            return {
                "changed": False,
                "msg": "device unreachable",
                "data": {"discovery": []},
            }

        # Walk the manager/archive subcheck OIDs. The original check uses the
        # section at index 3, which corresponds to archive status entries
        # (.1.3.6.1.4.1.110901.1.4.1 - .4.5). Each archive entry yields an item.
        rows = _snmp_walk(ctx, host, community, ".1.3.6.1.4.1.110901.1.2.2.1.1")
        items = []
        for oid, _val in rows:
            # The index is the OID suffix after the column base.
            idx = oid[len(".1.3.6.1.4.1.110901.1.2.2.1.1") + 1:]
            label = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.110901.1.2.2.1.1." + idx)
            name = "Manager " + idx
            if label != None and len(label) > 0:
                name = "Manager " + label
            items.append({
                "item": name,
                "params": {"warn": 1, "crit": 2},
                "metrics": ["diva_status"],
            })
        msg = "discovered %d archive items" % len(items)
        return {
            "changed": False,
            "msg": msg,
            "data": {"discovery": items},
        }

    # --- CHECK MODE (single-service: archive/manager status) ---
    # Probe for the real thing first.
    sys_oid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None:
        return {
            "changed": False,
            "msg": "device unreachable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # The archive subcheck (section idx 3) reads archive status entries.
    # Read the archive status OID directly.
    status_val = _snmp_get(ctx, host, community, ".1.3.6.1.4.1.110901.1.4.1")
    if status_val == None:
        return {
            "changed": False,
            "msg": "no archive status found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_level, summary = _status_result(status_val)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    verdict = state_map.get(state_level, "UNKNOWN")

    # Map status level to a numeric metric for perfdata.
    metric_val = state_level
    return {
        "changed": False,
        "msg": "DIVA Status " + summary,
        "data": {
            "state": verdict,
            "metrics": {"diva_status": metric_val},
            "details": "archive status reading: %s" % status_val,
        },
    }