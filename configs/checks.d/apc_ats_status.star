# apc_ats_status — read-only Starlark check module for yolo-man
# Translates Checkmk check: checkmk.apc_ats_status

# SNMP OIDs (base .1.3.6.1.4.1.318.1.1.8.5.1)
_APC_OID_BASE = ".1.3.6.1.4.1.318.1.1.8.5.1"
_APC_SYS_OID = ".1.3.6.1.2.1.1.2.0"

# APC product sysOIDs that indicate an ATS-capable device (from DETECT_ATS)
_APC_ATS_SYSOIDS = [
    ".1.3.6.1.4.1.318.1.3.11",
    ".1.3.6.1.4.1.318.1.3.32",
    ".1.3.6.1.4.1.318.1.3.38",
]

# Status enums mirrored from apc_ats library
_COMM_OK = 2          # Established
_COMM_NEVER = 1       # NeverDiscovered
_COMM_LOST = 3        # Lost

_RED_LOST = 1         # Lost
_RED_OK = 2           # Redundant

_SRC_A = 1
_SRC_B = 2

_OC_EXCEEDED = 1
_OC_OK = 2

_PS_NOTAVAIL = 0
_PS_FAILURE = 1
_PS_OK = 2

_VOLTAGES = ["5V", "24V", "3.3V", "1.0V"]

# Maps for human-readable names (source item)
_SOURCE_NAME = {1: "A", 2: "B"}

_STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}


def _int_or_none(v):
    if v == None:
        return None
    vs = str(v)
    if vs == "":
        return None
    if vs.lstrip("-").isdigit():
        return int(vs)
    return None


def _worst_state(states):
    worst = "OK"
    for s in states:
        if _STATE_RANK.get(s, 3) > _STATE_RANK.get(worst, 0):
            worst = s
    return worst


def _probe_apc_ats(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    ver = params.get("version", "2c")

    # 1. Confirm this is an APC ATS device via sysOID (DETECT_ATS)
    sys_res = ctx.run(
        ["snmpget", "-Oqv", "-v", ver, "-c", community, host, _APC_SYS_OID],
        mutates=False,
    )
    if sys_res.rc != 0:
        return None
    sys_oid = sys_res.stdout.strip()
    if sys_oid not in _APC_ATS_SYSOIDS:
        return None

    # 2. Fetch the status table (oids 1.0..18.0 under the base)
    oids = ["1.0", "2.0", "3.0", "4.0", "5.0", "6.0", "17.0", "18.0"]
    values = []
    ok = True
    for sub in oids:
        r = ctx.run(
            ["snmpget", "-Oqv", "-v", ver, "-c", community, host,
             _APC_OID_BASE + "." + sub],
            mutates=False,
        )
        if r.rc != 0 or r.stdout.strip() == "":
            ok = False
            break
        values.append(r.stdout.strip())
    if not ok or len(values) != 8:
        return None

    com_state = _int_or_none(values[0])
    source = _int_or_none(values[1])
    redundancy = _int_or_none(values[2])
    overcurrent = _int_or_none(values[3])
    ps5 = _int_or_none(values[4])
    ps24 = _int_or_none(values[5])
    ps33 = _int_or_none(values[6])
    ps10 = _int_or_none(values[7])

    raw_ps = [ps5, ps24, ps33, ps10]
    powersources = []
    for i in range(len(raw_ps)):
        val = raw_ps[i]
        if val == None:
            continue
        powersources.append((_VOLTAGES[i], val))

    return {
        "com_status": com_state,
        "selected_source": source,
        "redundancy": redundancy,
        "overcurrent": overcurrent,
        "powersources": powersources,
    }


def main(ctx, params):
    if params.get("_discover"):
        st = _probe_apc_ats(ctx, params)
        if st == None:
            return {"changed": False, "msg": "no APC ATS detected", "data": {"discovery": []}}
        src = st.get("selected_source")
        if src == None:
            return {"changed": False, "msg": "no selected source", "data": {"discovery": []}}
        item_name = _SOURCE_NAME.get(src, str(src))
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": item_name,
                        "params": {"power_source": item_name},
                        "metrics": [],
                    }
                ]
            },
        }

    # CHECK MODE
    st = _probe_apc_ats(ctx, params)
    if st == None:
        return {
            "changed": False,
            "msg": "no APC ATS detected on host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    source_param = params.get("power_source", "")
    src_num = None
    if source_param == "A":
        src_num = _SRC_A
    elif source_param == "B":
        src_num = _SRC_B
    else:
        src_num = st.get("selected_source")

    result_states = []
    result_msgs = []

    # Power source
    selected = st.get("selected_source")
    if selected == None:
        result_states.append("UNKNOWN")
        result_msgs.append("Power source unknown")
    elif src_num != None and selected != src_num:
        sel_name = _SOURCE_NAME.get(selected, str(selected))
        exp_name = _SOURCE_NAME.get(src_num, str(src_num))
        result_states.append("CRIT")
        result_msgs.append("Power source Changed from %s to %s" % (exp_name, sel_name))
    else:
        sel_name = _SOURCE_NAME.get(selected, str(selected))
        result_states.append("OK")
        result_msgs.append("Power source %s selected" % sel_name)

    # Communication status
    com = st.get("com_status")
    if com == _COMM_NEVER:
        result_states.append("WARN")
        result_msgs.append("Communication Status: never Discovered")
    elif com == _COMM_LOST:
        result_states.append("CRIT")
        result_msgs.append("Communication Status: lost")

    # Redundancy
    red = st.get("redundancy")
    if red == _RED_LOST:
        result_states.append("CRIT")
        result_msgs.append("redundancy lost")
    else:
        result_states.append("OK")
        result_msgs.append("Device fully redundant")

    # Overcurrent
    oc = st.get("overcurrent")
    if oc == _OC_EXCEEDED:
        result_states.append("CRIT")
        result_msgs.append("exceeded output current threshold")

    # Power supplies
    for entry in st.get("powersources", []):
        vname = entry[0]
        val = entry[1]
        if val == _PS_FAILURE:
            result_states.append("CRIT")
            result_msgs.append("%s power supply failed" % vname)
        elif val == _PS_NOTAVAIL:
            result_states.append("OK")
            result_msgs.append("%s power supply not available" % vname)

    worst = _worst_state(result_states)
    details = "; ".join(result_msgs)
    summary = details if details != "" else "ATS Status OK"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": worst,
            "metrics": {},
            "details": details,
        },
    }