# Translation of Checkmk check apc_inputs -> SNMP-based input monitor.
# Walks the APC UPS input table over SNMPv2c and reports each input's
# alarm state and port-state change against the discovered baseline.
#
# OID layout (base .1.3.6.1.4.1.318.1.1.25.2.2.1):
#   .3  inputName           (display name / item)
#   .4  inputLocation
#   .5  inputState          (1=closed 2=open 3=disabled 4=not applicable)
#   .6  inputAlarmStatus    (1=normal 2=warning 3=critical 4=not applicable)
#
# sysObjectID (.1.3.6.1.2.1.1.2.0) must start with the APC enterprise prefix
# .1.3.6.1.4.1.318 to confirm the device is an APC UPS.

OID_BASE = "1.3.6.1.4.1.318.1.1.25.2.2.1"
OID_SYS_OBJ_ID = "1.3.6.1.2.1.1.2.0"
APC_PREFIX = "1.3.6.1.4.1.318"

COL_NAME = "3"
COL_LOC = "4"
COL_STATE = "5"
COL_ALARM = "6"

STATE_MAP = {"1": "closed", "2": "open", "3": "disabled", "4": "not applicable"}
ALARM_MAP = {"1": "normal", "2": "warning", "3": "critical", "4": "not applicable"}

def _snmpget(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmpwalk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    out = []
    for line in res.stdout.splitlines():
        if not line:
            continue
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        out.append((sp[0], sp[1].strip()))
    return out

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- Presence probe: confirm this is an APC device via sysObjectID ---
    sysOid = _snmpget(ctx, host, community, OID_SYS_OBJ_ID)
    if sysOid == None or not sysOid.startswith(APC_PREFIX):
        if params.get("_discover"):
            return {"changed": False, "msg": "no APC device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "device at %s is not an APC UPS" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        # --- Discovery: enumerate every input whose state is not disabled/not-applicable ---
        rows = _snmpwalk(ctx, host, community, OID_BASE + "." + COL_NAME)
        byIndex = {}
        for lineOid, nameVal in rows:
            suffix = lineOid[len(OID_BASE) + 1:]
            if not suffix:
                continue
            parts = suffix.split(".")
            index = parts[0]
            byIndex[index] = {"name": nameVal, "location": "", "state": "", "alarm": ""}

        if not byIndex:
            return {"changed": False, "msg": "no APC inputs discovered",
                    "data": {"discovery": []}}

        # Pull state + alarm columns keyed by numeric index.
        stateRows = _snmpwalk(ctx, host, community, OID_BASE + "." + COL_STATE)
        for lineOid, stateVal in stateRows:
            suffix = lineOid[len(OID_BASE) + 1:]
            if not suffix:
                continue
            index = suffix.split(".")[0]
            if index in byIndex:
                byIndex[index]["state"] = stateVal

        alarmRows = _snmpwalk(ctx, host, community, OID_BASE + "." + COL_ALARM)
        for lineOid, alarmVal in alarmRows:
            suffix = lineOid[len(OID_BASE) + 1:]
            if not suffix:
                continue
            index = suffix.split(".")[0]
            if index in byIndex:
                byIndex[index]["alarm"] = alarmVal

        discovery = []
        for index in sorted(byIndex.keys()):
            rec = byIndex[index]
            # Skip disabled (3) and not applicable (4) inputs, mirroring the source filter.
            if rec["state"] in ("3", "4"):
                continue
            discovery.append({
                "item": rec["name"],
                "params": {"state": rec["state"],
                           "alarm_status": rec["alarm"]},
                "metrics": ["alarm_level"],
            })

        return {"changed": False,
                "msg": "discovered %d APC inputs" % len(discovery),
                "data": {"discovery": discovery}}

    # --- Check mode: grade one input ---
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no APC input item selected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Read all columns, then locate the row whose name matches the item.
    nameRows = _snmpwalk(ctx, host, community, OID_BASE + "." + COL_NAME)
    matchIndex = None
    for lineOid, nameVal in nameRows:
        if nameVal == item:
            suffix = lineOid[len(OID_BASE) + 1:]
            matchIndex = suffix.split(".")[0]
            break

    if matchIndex == None:
        return {"changed": False,
                "msg": "input not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def _col(index, col):
        res = _snmpget(ctx, host, community, OID_BASE + "." + col + "." + index)
        return res if res != None else ""

    state = _col(matchIndex, COL_STATE)
    alarm = _col(matchIndex, COL_ALARM)

    if alarm == "":
        return {"changed": False,
                "msg": "could not read alarm status for input %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Grade alarm: 2|4 -> WARN, 3 -> CRIT, 1 -> OK (source ordering).
    if alarm == "3":
        checkState = "CRIT"
    elif alarm == "2" or alarm == "4":
        checkState = "WARN"
    elif alarm == "1":
        checkState = "OK"
    else:
        checkState = "UNKNOWN"

    alarmLevel = int(alarm) if alarm.isdigit() else 0
    summary = "State is %s" % ALARM_MAP.get(alarm, "unknown")

    # Port-state change check against the baseline captured at discovery time.
    baselineState = params.get("state", "")
    if baselineState != "":
        if baselineState != state:
            summary = summary + " | Port state Change from %s to %s" % (
                STATE_MAP.get(baselineState, "unknown"),
                STATE_MAP.get(state, "unknown"),
            )
            if checkState == "OK":
                checkState = "WARN"

    return {"changed": False,
            "msg": "Input %s: %s" % (item, summary),
            "data": {"state": checkState,
                     "metrics": {"alarm_level": alarmLevel},
                     "details": "inputState=%s inputAlarmStatus=%s" % (state, alarm)}}