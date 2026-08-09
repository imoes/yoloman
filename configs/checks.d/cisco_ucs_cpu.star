# MAPS OF OPERABILITY STATUS CODE -> (CHECKMK_STATE, READABLE_NAME)
# CHECKMK_STATE: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
MAP_OPERABILITY = {
    "0": (2, "unknown"),
    "1": (0, "operable"),
    "2": (2, "inoperable"),
    "3": (2, "degraded"),
    "4": (1, "poweredOff"),
    "5": (2, "powerProblem"),
    "6": (0, "removed"),
    "7": (2, "voltageProblem"),
    "8": (2, "thermalProblem"),
    "9": (1, "performanceProblem"),
    "10": (1, "accessibilityProblem"),
    "11": (1, "identityUnestablishable"),
    "12": (2, "biosPostTimeout"),
    "13": (1, "disabled"),
    "14": (1, "malformedFru"),
    "51": (1, "fabricConnProblem"),
    "52": (1, "fabricUnsupportedConn"),
    "81": (1, "config"),
    "82": (2, "equipmentProblem"),
    "83": (2, "decomissioning"),
    "84": (1, "chassisLimitExceeded"),
    "100": (1, "notSupported"),
    "101": (1, "discovery"),
    "102": (2, "discoveryFailed"),
    "103": (1, "identify"),
    "104": (2, "postFailure"),
    "105": (1, "upgradeProblem"),
    "106": (1, "peerCommProblem"),
    "107": (0, "autoUpgrade"),
    "108": (1, "linkActivateBlocked"),
}

MAP_PRESENCE = {
    "0": (1, "unknown"),
    "1": (0, "empty"),
    "10": (0, "equipped"),
    "11": (0, "missing"),
    "12": (1, "mismatch"),
    "13": (0, "equippedNotPrimary"),
    "14": (0, "equippedSlave"),
    "15": (1, "mismatchSlave"),
    "16": (1, "missingSlave"),
    "20": (1, "equippedIdentityUnestablishable"),
    "21": (1, "mismatchIdentityUnestablishable"),
}

# SNMP COLUMN OID SUFFIXES (APPEND TO BASE .1.3.6.1.4.1.9.9.719.1.41.9.1)
OID_NAME = "3"
OID_SERIAL = "15"
OID_MODEL = "8"
OID_OPERABILITY = "10"
OID_PRESENCE = "13"

# CISCO UCS SYSOBJECTID ENTRIES FOR DETECTION
DETECT_SYSOBJS = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]

# CHECKMK STATE CODES
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3

STATE_NAME = {
    STATE_OK: "OK",
    STATE_WARN: "WARN",
    STATE_CRIT: "CRIT",
    STATE_UNKNOWN: "UNKNOWN",
}

def _state_name(code):
    return STATE_NAME.get(code, "UNKNOWN")

def _snmp_get(ctx, host, community, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        s = line.strip()
        if s == "":
            continue
        lines.append(s)
    return lines

def _detect_ucs(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # PROBE FOR THE REAL THING: a CISCO UCS DEVICE VIA SYSOBJECTID
    sysid = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sysid == None:
        return False
    for target in DETECT_SYSOBJS:
        if sysid == target:
            return True
    return False

def _fetch_cpu_table(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.9.9.719.1.41.9.1"
    # WALK THE NAME COLUMN TO GET ALL INSTANCES + THEIR INDEXES
    name_lines = _snmp_walk(ctx, host, community, base + "." + OID_NAME)
    rows = []  # list of {index, name, presence, serial, model, operability}
    by_index = {}
    for line in name_lines:
        # line format: "<full-oid> <value>"  (from -Oqn)
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        full_oid = sp[0]
        name_val = sp[1].strip().strip('"')
        # INDEX IS THE OID SUFFIX AFTER THE COLUMN BASE
        col_oid = base + "." + OID_NAME
        idx = full_oid[len(col_oid) + 1:]
        if idx == "":
            continue
        entry = {"index": idx, "name": name_val,
                 "presence": None, "serial": None,
                 "model": None, "operability": None}
        by_index[idx] = entry

    # FETCH THE OTHER COLUMNS BY NUMERIC INDEX
    col_map = [
        (OID_PRESENCE, "presence"),
        (OID_SERIAL, "serial"),
        (OID_MODEL, "model"),
        (OID_OPERABILITY, "operability"),
    ]
    for suffix, field in col_map:
        col_oid = base + "." + suffix
        walk_lines = _snmp_walk(ctx, host, community, col_oid)
        for line in walk_lines:
            sp = line.split(" ", 1)
            if len(sp) < 2:
                continue
            full_oid = sp[0]
            val = sp[1].strip().strip('"')
            idx = full_oid[len(col_oid) + 1:]
            if idx in by_index:
                by_index[idx][field] = val

    # NORMALISE: ANY FIELD STILL NONE BECOMES EMPTY STRING
    for e in by_index.values():
        for k in e:
            if e[k] == None:
                e[k] = ""
    return list(by_index.values())

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # DISCOVERY: MUST PROBE FOR THE REAL THING FIRST
        if not _detect_ucs(ctx, params):
            # NOT A CISCO UCS DEVICE -> NO SERVICES
            return {
                "changed": False,
                "msg": "not a Cisco UCS device, no discovery",
                "data": {"discovery": []},
            }
        rows = _fetch_cpu_table(ctx, params)
        if len(rows) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 cpu units",
                "data": {"discovery": []},
            }
        discovery = []
        for r in rows:
            # DO NOT DISCOVER MISSING UNITS (presence == "11")
            if r["presence"] == "11":
                continue
            discovery.append({
                "item": r["name"],
                "params": {},
                "metrics": [],
                "service_labels": {
                    "serial": r["serial"],
                    "model": r["model"],
                },
            })
        return {
            "changed": False,
            "msg": "discovered %d cpu units" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE: ONE ITEM
    item = params.get("item", "")

    if not _detect_ucs(ctx, params):
        return {
            "changed": False,
            "msg": "not a Cisco UCS device, no cpu data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    rows = _fetch_cpu_table(ctx, params)
    if len(rows) == 0:
        return {
            "changed": False,
            "msg": "no cpu units found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # FIND THE REQUESTED ITEM (name)
    target = None
    for r in rows:
        if r["name"] == item:
            target = r
            break

    if target == None:
        return {
            "changed": False,
            "msg": "cpu unit not found: " + str(item),
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # APPLY MAP_OPERABILITY AND MAP_PRESENCE (CHECKMK DEFAULTS, NO PER-ITEM THRESHOLDS)
    pres_code = target["presence"]
    op_code = target["operability"]

    pres_default = (STATE_UNKNOWN, "Unknown, status code %s" % pres_code)
    op_default = (STATE_UNKNOWN, "Unknown, status code %s" % op_code)
    pres_state, pres_readable = MAP_PRESENCE.get(pres_code, pres_default)
    state, state_readable = MAP_OPERABILITY.get(op_code, op_default)

    details_parts = [
        "Presence: %s" % pres_readable,
        "Status: %s" % state_readable,
        "Model: %s, SN: %s" % (target["model"], target["serial"]),
    ]
    details = " | ".join(details_parts)

    # WORST STATE WINS: UNKNOWN=3 > CRIT=2 > WARN=1 > OK=0
    worst = max(pres_state, state, STATE_OK)
    # PRESENCE MISSING (CODE 11) IS OK PER THE LIB MAPPING (0, "missing")
    # BUT THE UNIT WAS NOT DISCOVERED IN THAT CASE, SO A DIRECT CHECK IS UNUSUAL.

    summary = "Status: %s, Presence: %s, Model: %s, SN: %s" % (
        state_readable, pres_readable, target["model"], target["serial"])

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": _state_name(worst),
            "metrics": {},
            "details": details,
        },
    }