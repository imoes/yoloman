# cisco_asa_failover — Checkmk → read-only Starlark check module (translated)

_STATE_NAMES = {
    "1": "other",
    "2": "up",
    "3": "down",
    "4": "error",
    "5": "overTemp",
    "6": "busy",
    "7": "noMedia",
    "8": "backup",
    "9": "active",
    "10": "standby",
}

# SNMP base: .1.3.6.1.4.1.9.9.147.1.2.1.1.1  (cfwHardwareStatusEntry)
# Columns: 2=Information(role), 3=Status, 4=Detail
_SNMP_BASE = ".1.3.6.1.4.1.9.9.147.1.2.1.1.1"
_SNMP_COL_ROLE = _SNMP_BASE + ".2"
_SNMP_COL_STATUS = _SNMP_BASE + ".3"
_SNMP_COL_DETAIL = _SNMP_BASE + ".4"


def _state_name(st):
    return _STATE_NAMES.get(st, "unknown " + str(st))


def _not_cisco_asa(descr):
    d = descr.lower()
    return not (d.startswith("cisco adaptive security") or
                d.find("cisco pix security") != -1 or
                d.startswith("cisco firepower threat defense"))


def _snmp_get(ctx, params, oid):
    full = "." + oid
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-Oqv", params.get("host", "localhost"), full], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return None
    v = res.stdout.strip()
    if v == "" or v.find("No such") != -1 or v.find("Timeout") != -1:
        return None
    return v


def _snmp_walk_col(ctx, params, col_oid):
    full = "." + col_oid
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-Oqn", params.get("host", "localhost"), full], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return []
    rows = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp].strip()
        val = line[sp + 1:].strip()
        rows.append({"oid": oid, "val": val})
    return rows


def _snmp_walk_table(ctx, params):
    c2 = _snmp_walk_col(ctx, params, _SNMP_COL_ROLE)
    if len(c2) == 0:
        return []
    c3 = _snmp_walk_col(ctx, params, _SNMP_COL_STATUS)
    c4 = _snmp_walk_col(ctx, params, _SNMP_COL_DETAIL)
    rows = []
    prefix2 = "." + _SNMP_COL_ROLE + "."
    prefix3 = "." + _SNMP_COL_ROLE + "."  # placeholder, re-derived below
    p3 = "." + _SNMP_COL_STATUS + "."
    p4 = "." + _SNMP_COL_DETAIL + "."
    for e2 in c2:
        idx = e2["oid"][len(prefix2):]
        status = ""
        detail = ""
        for e3 in c3:
            if e3["oid"][len(p3):] == idx:
                status = e3["val"]
        for e4 in c4:
            if e4["oid"][len(p4):] == idx:
                detail = e4["val"]
        rows.append({"role": e2["val"], "status": status, "detail": detail})
    return rows


def _build_section(ctx, params):
    descr = _snmp_get(ctx, params, "1.3.6.1.2.1.1.1.0")
    if descr == None or _not_cisco_asa(descr):
        return None

    rows = _snmp_walk_table(ctx, params)
    if len(rows) == 0:
        return None

    failover = {}
    for r in rows:
        role = r["role"]
        status = r["status"]
        detail = r["detail"]
        if role.find("this device") != -1 and detail.lower() != "failover off":
            failover["local_role"] = role.split(" ")[0].lower()
            failover["local_status"] = status
            failover["local_status_detail"] = detail
        elif role.lower().find("failover") != -1:
            failover["failover_link_status"] = status
            failover["failover_link_name"] = detail
        else:
            failover["remote_status"] = status

    keys = ["local_role", "local_status", "local_status_detail",
            "failover_link_status", "failover_link_name", "remote_status"]
    for k in keys:
        if failover.get(k, None) == None:
            return None
    return failover


def main(ctx, params):
    # ----- DISCOVERY -----
    if params.get("_discover"):
        descr = _snmp_get(ctx, params, "1.3.6.1.2.1.1.1.0")
        if descr == None or _not_cisco_asa(descr):
            return {"changed": False, "msg": "no Cisco ASA/Firepower device", "data": {"discovery": []}}

        rows = _snmp_walk_table(ctx, params)
        if len(rows) == 0:
            return {"changed": False, "msg": "no failover entry", "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {"item": "", "params": {
                    "primary": "active",
                    "secondary": "standby",
                    "failover_state": 1,
                    "failover_link_state": 2,
                    "not_active_standby_state": 1,
                }, "metrics": []}],
            },
        }

    # ----- CHECK (per item, single-service → item "") -----
    section = _build_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "cisco_asa_failover data not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state = "OK"
    summaries = []
    summaries.append("Device (" + section["local_role"] + ") is the " + section["local_status_detail"])

    role_key = section["local_role"]
    expected = params.get(role_key, None)
    got_name = _state_name(section["local_status"])
    if expected != None and expected != got_name:
        st_num = params.get("failover_state", 1)
        if st_num >= 2:
            if state == "OK":
                state = "CRIT"
            summaries.append("(" + role_key + " device should be " + expected + ")")

    if section["local_status"] not in ["9", "10"]:
        st_num = params.get("not_active_standby_state", 1)
        if st_num >= 2:
            if state == "OK":
                state = "CRIT"
            summaries.append("Unhandled state " + got_name + " reported")

    remote_name = _state_name(section["remote_status"])
    if section["remote_status"] not in ["9", "10"]:
        st_num = params.get("not_active_standby_state", 1)
        if st_num >= 2:
            if state == "OK":
                state = "CRIT"
            summaries.append("Unhandled state " + remote_name + " for remote device reported")

    if section["failover_link_status"] != "2":
        st_num = params.get("failover_link_state", 2)
        if st_num >= 2:
            if state == "OK":
                state = "CRIT"
            summaries.append("Failover link " + section["failover_link_name"] + " state is " + _state_name(section["failover_link_status"]))

    return {"changed": False,
            "msg": " | ".join(summaries),
            "data": {"state": state, "metrics": {}, "details": ""}}