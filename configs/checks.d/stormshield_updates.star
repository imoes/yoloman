# Checkmk -> Starlark translation of cmk stormshield_updates
# Source: cmk/plugins/stormshield/agent_based/stormshield_updates.py
# SNMP section stormshield_updates (base .1.3.6.1.4.1.11256.1.9.1.1, oids 2,3,4)
# OID .1 = subsystem name, OID .2 = state, OID .3 = lastrun timestamp

STATE_MAP = {
    "Not Available": "WARN",
    "Broken": "CRIT",
    "Uptodate": "OK",
    "Disabled": "WARN",
    "Never started": "OK",
    "Running": "OK",
    "Failed": "CRIT",
}

# OID layout for the stormshield_updates table (column .1=subsystem, .2=state, .3=lastrun)
COL_SUBSYSTEM = "2"
COL_STATE = "3"
COL_LASTRUN = "4"
TABLE_BASE = ".1.3.6.1.4.1.11256.1.9.1.1"

# Detection OID (sysoid / basic info). We use the documented Stormshield sysOID prefix
# plus the Basic Info OID existence check mirroring DETECT_STORMSHIELD.
SYSOID_BASIC_INFO = ".1.3.6.1.4.1.11256.1.0.1.0"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Probe for the real thing: a Stormshield device exposes the Basic Info OID.
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_BASIC_INFO],
            mutates=False,
        )
        if probe.rc != 0:
            # rc 127 == binary missing; non-zero == not a Stormshield or unreachable.
            return {"changed": False, "msg": "no Stormshield device detected",
                    "data": {"discovery": []}}

        # Fetch the autoupdate table (subsystem/state/lastrun columns).
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, TABLE_BASE + "." + COL_SUBSYSTEM],
            mutates=False,
        )
        rows = {}
        order = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            idx = oid[len(TABLE_BASE + "." + COL_SUBSYSTEM + "."):]
            if idx not in rows:
                rows[idx] = {"subsystem": "", "state": "", "lastrun": ""}
                order.append(idx)
            rows[idx]["subsystem"] = value

        if not order:
            return {"changed": False, "msg": "no Stormshield autoupdate subsystems",
                    "data": {"discovery": []}}

        # Fetch state and lastrun columns keyed by the discovered indices.
        state_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, TABLE_BASE + "." + COL_STATE],
            mutates=False,
        )
        for line in state_walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            idx = oid[len(TABLE_BASE + "." + COL_STATE + "."):]
            if idx in rows:
                rows[idx]["state"] = value

        lastrun_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, TABLE_BASE + "." + COL_LASTRUN],
            mutates=False,
        )
        for line in lastrun_walk.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            oid = line[:sp]
            value = line[sp + 1:]
            idx = oid[len(TABLE_BASE + "." + COL_LASTRUN + "."):]
            if idx in rows:
                rows[idx]["lastrun"] = value

        discovery = []
        for idx in order:
            r = rows[idx]
            subsystem = r["subsystem"]
            state = r["state"]
            lastrun = r["lastrun"]
            # Mirror discover_stormshield_updates: skip failed-but-never-run and
            # Not Available / Never started (those are not yielded as services).
            if state == "Failed" and lastrun == "":
                continue
            if state in ["Not Available", "Never started"]:
                continue
            discovery.append({
                "item": subsystem,
                "params": {},
                "metrics": ["update_state"],
                "service_labels": {"state": state},
            })

        return {"changed": False,
                "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE for one item.
    item = params.get("item", "")
    if item == "":
        return {"changed": False,
                "msg": "no subsystem specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    probe = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_BASIC_INFO],
        mutates=False,
    )
    if probe.rc != 0:
        return {"changed": False,
                "msg": "no Stormshield device detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Locate the index for the requested subsystem.
    walk = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, TABLE_BASE + "." + COL_SUBSYSTEM],
        mutates=False,
    )
    target_idx = None
    for line in walk.stdout.splitlines():
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        value = line[sp + 1:]
        idx = oid[len(TABLE_BASE + "." + COL_SUBSYSTEM + "."):]
        if value == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False,
                "msg": "no such subsystem: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         TABLE_BASE + "." + COL_STATE + "." + target_idx],
        mutates=False,
    )
    if state_res.rc != 0:
        return {"changed": False,
                "msg": "failed to read state for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = state_res.stdout.strip()

    lastrun_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host,
         TABLE_BASE + "." + COL_LASTRUN + "." + target_idx],
        mutates=False,
    )
    if lastrun_res.rc != 0:
        return {"changed": False,
                "msg": "failed to read lastrun for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lastrun = lastrun_res.stdout.strip()
    if lastrun == "":
        lastrun = "Never"

    monitoringstate = STATE_MAP.get(state, "CRIT")
    infotext = "Subsystem %s is %s, last update: %s" % (item, state, lastrun)

    # Encode state for metrics: OK=0, WARN=1, CRIT=2, UNKNOWN=3.
    state_num = {"OK": 0, "WARN": 1, "CRIT": 2}.get(monitoringstate, 3)

    return {"changed": False,
            "msg": infotext,
            "data": {
                "state": monitoringstate,
                "metrics": {"update_state": state_num, "lastrun": 0},
                "details": infotext,
            }}