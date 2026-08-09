# Translated Checkmk check: oracle_diva_csm_actor
# READ-ONLY Starlark check module for the yolo-man agent.
# Monitors the DIVA CSM "Actor" status via SNMP (OID .1.3.6.1.4.1.110901.1.3.1.1.4).

# OID table base for the "actor" status column.
# Original Checkmk SNMPTree: base=".1.3.6.1.4.1.110901.1.3.1.1", oids=["2", "4"]
# OID .2 = status reading (used for grading), OID .4 = element id (used for item name).
ACTOR_COL_OID = "2"
ACTOR_COL_EID = "4"
ACTOR_BASE = ".1.3.6.1.4.1.110901.1.3.1.1"
ACTOR_INDEX_BASE = ".1.3.6.1.4.1.110901.1.3.1.1.4"

# Detection OID: enterprise = Microsoft System Center (per `equals` detect).
SYS_OID = ".1.3.6.1.2.1.1.2.0"
DIVA_ENTERPRISE = ".1.3.6.1.4.1.311.1.1.3.1.2"


def _reading_to_state(reading):
    # reading "1" -> OK/online, "2" -> CRIT/offline, "3" -> WARN/unknown, else UNKNOWN.
    if reading == "1":
        return 0, "online"
    if reading == "2":
        return 2, "offline"
    if reading == "3":
        return 1, "unknown"
    return 3, "unexpected state"


def _item_name(name, element_id):
    s = name + " " + element_id
    return s.strip()


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")

    # Detection: only proceed if the target system is present.
    det = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, "1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if det.rc != 0:
        # 127 -> not installed; other non-zero -> unreachable / absent.
        if params.get("_discover"):
            return {"changed": False, "msg": "oracle_diva_csm_actor not applicable", "data": {"discovery": []}}
        return {"changed": False, "msg": "no agent response / not present", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    sys_val = det.stdout.strip().strip('"')
    if sys_val != DIVA_ENTERPRISE:
        if params.get("_discover"):
            return {"changed": False, "msg": "not a DIVA system", "data": {"discovery": []}}
        return {"changed": False, "msg": "not a DIVA system", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery: walk the element-id column to enumerate actor instances.
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ACTOR_INDEX_BASE],
        mutates=False,
    )
    if params.get("_discover"):
        discovered = []
        for line in walk.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:].strip().strip('"')
            if not oid.startswith(ACTOR_INDEX_BASE + "."):
                continue
            index = oid[len(ACTOR_INDEX_BASE) + 1:]
            if not index:
                continue
            eid = value
            discovered.append({
                "item": _item_name("Actor", eid) if eid != "" else "Actor",
                "params": {},
                "metrics": ["status"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovered),
            "data": {"discovery": discovered},
        }

    # Check mode: locate this item by walking element ids, then read its status by index.
    found_index = None
    found_eid = None
    target = item if item != "" else ""
    for line in walk.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:].strip().strip('"')
        if not oid.startswith(ACTOR_INDEX_BASE + "."):
            continue
        index = oid[len(ACTOR_INDEX_BASE) + 1:]
        if not index:
            continue
        eid = value
        cand = _item_name("Actor", eid) if eid != "" else "Actor"
        if cand == target:
            found_index = index
            found_eid = eid
            break

    if found_index == None:
        if target == "":
            # Single-service fallback: take the first actor found.
            pass
        else:
            return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Resolve index for status read.
    read_index = found_index if found_index != None else ""
    # If no item specified and nothing matched yet, pick first index if walk had rows.
    if read_index == "":
        rows = []
        for line in walk.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            if not oid.startswith(ACTOR_INDEX_BASE + "."):
                continue
            rows.append(oid[len(ACTOR_INDEX_BASE) + 1:])
        if len(rows) > 0:
            read_index = rows[0]

    if read_index == "":
        return {"changed": False, "msg": "no actor instance found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read the status reading (OID .2) indexed by the same index.
    status_oid = ACTOR_BASE + "." + ACTOR_COL_OID + "." + read_index
    st = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, status_oid], mutates=False)
    if st.rc != 0:
        return {"changed": False, "msg": "failed to read actor status", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    reading = st.stdout.strip().strip('"')
    state_num, summary = _reading_to_state(reading)
    if state_num == 0:
        state = "OK"
    elif state_num == 1:
        state = "WARN"
    elif state_num == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    display = _item_name("Actor", found_eid) if (found_eid != None and found_eid != "") else "Actor"
    return {
        "changed": False,
        "msg": "%s: %s" % (display, summary),
        "data": {"state": state, "metrics": {"status": state_num}, "details": ""},
    }