ACME_BASE = ".1.3.6.1.4.1.9148.3.3.1.2.1.1"
ACME_DESCR = "3"
ACME_VALUE = "4"
ACME_STATE = "5"

ACME_ENVIRONMENT_STATES = {
    "1": (0, "initial"),
    "2": (0, "normal"),
    "3": (1, "minor"),
    "4": (1, "major"),
    "5": (2, "critical"),
    "6": (2, "shutdown"),
    "7": (2, "not present"),
    "8": (2, "not functioning"),
    "9": (2, "unknown"),
}

# Map numeric state -> (level, text) for grading
def _level_for_state(rstate):
    entry = ACME_ENVIRONMENT_STATES.get(rstate, (2, "unknown"))
    return entry[0]

def _snmpget(ctx, community, host, oid):
    return ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)

def _snmpwalk(ctx, community, host, oid):
    return ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    if params.get("_discover"):
        # Detect ACME device via sysObjectID
        sysid = _snmpget(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
        if sysid.rc != 0 or not sysid.stdout.startswith(".1.3.6.1.4.1.9148"):
            return {"changed": False, "msg": "no ACME device found", "data": {"discovery": []}}

        # Walk description column to enumerate voltage sensors
        descr_walk = _snmpwalk(ctx, community, host, ACME_BASE + "." + ACME_DESCR)
        out = []
        descr_lines = descr_walk.stdout.splitlines()
        for line in descr_lines:
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            oid = sp[0]
            index = oid[len(ACME_BASE + "." + ACME_DESCR) + 1:]
            # Read value and state by numeric index
            val_res = _snmpget(ctx, community, host, ACME_BASE + "." + ACME_VALUE + "." + index)
            st_res = _snmpget(ctx, community, host, ACME_BASE + "." + ACME_STATE + "." + index)
            if val_res.rc != 0 or st_res.rc != 0:
                continue
            rstate = st_res.stdout.strip()
            if rstate == "7":
                continue  # "not present" -> skip
            value_str = val_res.stdout.strip()
            # The display name is in the descr column value (sp[1])
            descr_val = sp[1]
            out.append({
                "item": descr_val,
                "params": {"warn": (2200, 2800), "crit": (2000, 3000)},
                "metrics": ["voltage"],
            })
        return {"changed": False, "msg": "discovered %d voltage sensors" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")

    # Detect ACME
    sysid = _snmpget(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if sysid.rc != 0 or not sysid.stdout.startswith(".1.3.6.1.4.1.9148"):
        return {"changed": False, "msg": "no ACME device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the index for this item via descr column walk
    descr_walk = _snmpwalk(ctx, community, host, ACME_BASE + "." + ACME_DESCR)
    index = None
    for line in descr_walk.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        if sp[1] == item:
            oid = sp[0]
            index = oid[len(ACME_BASE + "." + ACME_DESCR) + 1:]
            break
    if index == None:
        return {"changed": False, "msg": "voltage sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    val_res = _snmpget(ctx, community, host, ACME_BASE + "." + ACME_VALUE + "." + index)
    st_res = _snmpget(ctx, community, host, ACME_BASE + "." + ACME_STATE + "." + index)
    if val_res.rc != 0 or st_res.rc != 0:
        return {"changed": False, "msg": "failed to read voltage sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value_str = val_res.stdout.strip()
    rstate = st_res.stdout.strip()
    if not value_str or not value_str.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid voltage value for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    voltage = float(value_str) / 1000.0
    slevel, stext = ACME_ENVIRONMENT_STATES.get(rstate, (2, "unknown"))

    # Grading: use elphase-like levels from params, default (2200,2800)/(2000,3000) mV -> V: 2.2/2.8 / 2.0/3.0
    # params["levels"] = {"voltage": {"warn_lower":..., "warn_upper":..., "crit_lower":..., "crit_upper":...}}
    # Simpler: treat warn/crit as (lower, upper) in volts
    levels = params.get("levels", (2.2, 3.0))
    warn_l = levels[0] if len(levels) > 0 else 2.2
    crit_l = levels[1] if len(levels) > 1 else 3.0
    # Upper defaults
    warn_u = params.get("warn_upper", 2.8)
    crit_u = params.get("crit_upper", 3.0)

    # State priority: critical sensor state overrides level grading
    if slevel == 2:
        state = "CRIT"
    elif slevel == 1:
        if voltage <= warn_l or voltage >= warn_u:
            state = "WARN"
        else:
            state = "OK"
    else:
        if voltage <= crit_l or voltage >= crit_u:
            state = "CRIT"
        elif voltage <= warn_l or voltage >= warn_u:
            state = "WARN"
        else:
            state = "OK"
        if slevel == 1 and state == "OK":
            state = "WARN"

    msg = "Voltage %s: %f V, state %s" % (item, voltage, stext)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"voltage": voltage}, "details": ""}}