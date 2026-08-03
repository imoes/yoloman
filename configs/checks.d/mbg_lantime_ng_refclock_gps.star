# Translated Checkmk check: mbg_lantime_ng_refclock_gps
# SNMP-based GPS refclock check for Meinberg LANTIME NG.
# Discovery: walk the refclock table, keep GPS clocks, one service per item.
# Check: report state + leap second + satellite levels_lower.

# OID base for the refclock table (mbgLtNgRefclockTable)
REFCLOCK_BASE = ".1.3.6.1.4.1.5597.30.0.1.2.1"

# Column sub-OIDs (append these to REFCLOCK_BASE)
COL_ITEM = "1"
COL_TYPE = "2"
COL_USAGE = "3"
COL_STATE = "4"
COL_SUBSTATE = "5"
COL_STATUS_A = "6"
COL_MAX_STATUS_A = "7"
COL_STATUS_B = "8"
COL_MAX_STATUS_B = "9"
COL_INFO = "10"
COL_LEAPSECOND = "11"

# Meinberg LANTIME NG enterprise OID prefix used for detection
LANTIME_ENTERPRISE_OID = ".1.3.6.1.2.1.1.2.0"
LANTIME_ENTERPRISE_VALUES = [".1.3.6.1.4.1.5597.3", ".1.3.6.1.4.1.5597.30"]

# See mbgLtNgRefclockType in MIB
REFCLOCK_TYPES = {
    "0": "unknown",
    "1": "gps166",
    "2": "gps167",
    "3": "gps167SV",
    "4": "gps167PC",
    "5": "gps167PCI",
    "6": "gps163",
    "7": "gps168PCI",
    "8": "gps161",
    "9": "gps169PCI",
    "10": "tcr167PCI",
    "11": "gps164",
    "12": "gps170PCI",
    "13": "pzf511",
    "14": "gps170",
    "15": "tcr511",
    "16": "am511",
    "17": "msf511",
    "18": "grc170",
    "19": "gps170PEX",
    "20": "gps162",
    "21": "ptp270PEX",
    "22": "frc511PEX",
    "23": "gen170",
    "24": "tcr170PEX",
    "25": "wwvb511",
    "26": "mgr170",
    "27": "jjy511",
    "28": "pzf600",
    "29": "tcr600",
    "30": "gps180",
    "31": "gln170",
    "32": "gps180PEX",
    "33": "tcr180PEX",
    "34": "pzf180PEX",
    "35": "mgr180",
    "36": "msf600",
    "37": "wwvb600",
    "38": "jjy600",
    "39": "gps180HS",
    "40": "gps180AMC",
    "41": "esi180",
    "42": "cpe180",
    "43": "lno180",
    "44": "grc180",
    "45": "liu",
    "46": "dcf600HS",
    "47": "dcf600RS",
    "48": "mri",
    "49": "bpe",
    "50": "gln180Pex",
    "51": "n2x",
    "52": "rsc180",
    "53": "lneGb",
    "54": "lnePpg180",
    "55": "scg",
    "56": "mdu300",
    "57": "sdi",
    "58": "fdm180",
    "59": "spt",
    "60": "pzf180",
    "61": "rel1000",
    "62": "hps100",
    "63": "vsg180",
    "64": "msf180",
    "65": "wwvb180",
    "66": "cpc180",
    "67": "ctc100",
    "68": "tcr180",
    "69": "lue180",
    "70": "cpc01",
    "71": "tsu01",
    "72": "cmc01",
    "73": "scu01",
    "74": "fcu01",
    "75": "mssb100",
    "76": "lne180sfp",
    "77": "gts180",
    "78": "gps180csm",
    "79": "grc181",
    "80": "n2x180",
    "81": "gns180pex",
    "82": "mdu180",
    "83": "mdu312",
    "84": "gps165",
    "85": "gns181uc",
    "86": "psx4GE",
    "87": "rsc180rdu",
    "88": "cpc200",
    "89": "fdm180m",
    "90": "lsg180",
    "91": "gps190",
    "92": "gns181",
    "93": "pio180",
    "94": "fcm180",
    "95": "tcr180usb",
    "96": "ssp100",
    "97": "gns165",
    "98": "rsc180rdmp",
    "99": "gps16x",
    "100": "mshps100",
    "101": "bpestm",
    "102": "vsi180",
    "103": "gnm181",
    "104": "rscrduttl",
    "105": "rsc2000",
    "106": "fcu200",
    "107": "rel1000rc",
    "108": "wsiug2864",
    "109": "vsg181",
    "110": "bps2xxx",
    "111": "bpe2352",
    "112": "bpe8XXX",
    "113": "bpe6042",
    "114": "gns190",
    "115": "gps180msbc",
    "116": "gns181msbc",
    "117": "gns181ucmsbc",
    "118": "prs181",
    "119": "ecm180",
    "120": "mro181",
    "121": "vsg181msbc",
    "122": "scg181",
    "123": "nimbra100",
    "124": "rsc180scu",
    "125": "pmu190",
    "126": "gns190uc",
    "127": "vmx180",
    "128": "rcg181",
    "129": "gns191",
    "130": "vsg181h",
    "131": "gps182",
    "132": "rsc1000",
    "133": "gns182",
    "134": "gns182uc",
    "135": "gsr190",
    "136": "gen182",
    "137": "cpe182",
    "138": "fdm182",
    "139": "fdm182m",
    "140": "pzf182",
    "141": "pzf183",
    "142": "bpe8nnn",
    "143": "n2x185",
    "144": "anz141",
    "145": "msf182",
    "146": "rel1002",
    "147": "gns183",
    "148": "gxl183",
    "149": "m3t",
}

# See mbgLtNgRefclockSubstate in MIB (GPS-relevant subset)
REFCLOCK_SUBSTATES = {
    "-1": "MRS Ref None",
    "0": "not available",
    "1": "GPS sync",
    "2": "GPS tracking",
    "3": "GPS antenna disconnected",
    "4": "GPS warm boot",
    "5": "GPS cold boot",
    "6": "GPS antenna short circuit",
    "50": "LW never sync",
    "51": "LW not sync",
    "52": "LW sync",
    "100": "TCR not sync",
    "101": "TCT sync",
    "149": "MRS internal oscillator sync",
    "150": "MRS GPS sync",
    "151": "MRS 10Mhz sync",
    "152": "MRS PPS in sync",
    "153": "MRS 10Mhz PPS in sync",
    "154": "MRS IRIG sync",
    "155": "MRS NTP sync",
    "156": "MRS PTP IEEE 1588 sync",
    "157": "MRS PTP over E1 sync",
    "158": "MRS fixed frequency in sync",
    "159": "MRS PPS string sync",
    "160": "MRS variable frequency GPIO sync",
    "161": "MRS reserved",
    "162": "MRS DCF77 PZF sync",
    "163": "MRS longwave sync",
    "164": "MRS GLONASS GPS sync",
    "165": "MRS HAVE QUICK sync",
    "166": "MRS external oscillator sync",
    "167": "MRS SyncE",
    "168": "MRS video in sync",
    "169": "MRS ltc sync",
    "170": "MRS osc sync",
}

# See mbgLtNgRefclockState in MIB -> State mapping
# 0 -> CRIT, 1 -> OK, 2 -> WARN
REFCLOCK_STATE_TO_LEVEL = {
    "0": "CRIT",
    "1": "OK",
    "2": "WARN",
}

# Substates that indicate a GPS connection is needed for satellite checks
GPS_SATELLITE_SUBSTATES = ["1", "2", "3", "4", "5", "6", "150"]


def _int_or_zero(val):
    if val == None:
        return 0
    s = str(val).strip()
    return int(s) if s.lstrip("-").isdigit() else 0


def _worst_state(current, new_state):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    ci = order.get(current, 3)
    ni = order.get(new_state, 3)
    return new_state if ni > ci else current


def _is_lantime(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, LANTIME_ENTERPRISE_OID], mutates=False)
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    for ov in LANTIME_ENTERPRISE_VALUES:
        if val == ov:
            return True
    return False


def _walk_table(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res.stdout


def _parse_table(rows):
    """rows: list of 'OID.suffix value' lines. Returns dict: suffix -> value."""
    out = {}
    for row in rows:
        s = row.strip()
        if s == "":
            continue
        idx = s.find(" ")
        if idx < 0:
            continue
        left = s[:idx]
        right = s[idx + 1:]
        out[left] = right
    return out


def _fetch_column(ctx, params, col_oid):
    """Walk a single column OID; returns dict index->value (string)."""
    out = _walk_table(ctx, params, col_oid)
    if out == None:
        return None
    rows = out.splitlines()
    parsed = {}
    base_len = len(col_oid)
    for row in rows:
        s = row.strip()
        if s == "":
            continue
        idx = s.find(" ")
        if idx < 0:
            continue
        full_oid = s[:idx]
        value = s[idx + 1:]
        if len(full_oid) <= base_len + 1:
            continue
        index = full_oid[base_len + 1:]
        parsed[index] = value
    return parsed


def _get_scalar(ctx, params, oid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 127:
        return None
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _build_clocks(ctx, params):
    """Fetch all columns and assemble a dict: item -> RefClock dict.

    Returns None if the table is absent/unreachable, {} if no rows.
    """
    col_item = REFCLOCK_BASE + "." + COL_ITEM
    col_type = REFCLOCK_BASE + "." + COL_TYPE
    col_usage = REFCLOCK_BASE + "." + COL_USAGE
    col_state = REFCLOCK_BASE + "." + COL_STATE
    col_substate = REFCLOCK_BASE + "." + COL_SUBSTATE
    col_status_a = REFCLOCK_BASE + "." + COL_STATUS_A
    col_max_status_a = REFCLOCK_BASE + "." + COL_MAX_STATUS_A
    col_status_b = REFCLOCK_BASE + "." + COL_STATUS_B
    col_max_status_b = REFCLOCK_BASE + "." + COL_MAX_STATUS_B
    col_info = REFCLOCK_BASE + "." + COL_INFO
    col_leapsecond = REFCLOCK_BASE + "." + COL_LEAPSECOND

    item_col = _fetch_column(ctx, params, col_item)
    if item_col == None:
        return None

    type_col = _fetch_column(ctx, params, col_type)
    usage_col = _fetch_column(ctx, params, col_usage)
    state_col = _fetch_column(ctx, params, col_state)
    substate_col = _fetch_column(ctx, params, col_substate)
    status_a_col = _fetch_column(ctx, params, col_status_a)
    max_status_a_col = _fetch_column(ctx, params, col_max_status_a)
    status_b_col = _fetch_column(ctx, params, col_status_b)
    max_status_b_col = _fetch_column(ctx, params, col_max_status_b)
    info_col = _fetch_column(ctx, params, col_info)
    leapsecond_col = _fetch_column(ctx, params, col_leapsecond)

    clocks = {}
    for index, itemname in item_col.items():
        clocks[index] = {
            "item": itemname,
            "clock_type": type_col.get(index, "") if type_col else "",
            "usage": usage_col.get(index, "") if usage_col else "",
            "state": state_col.get(index, "") if state_col else "",
            "substate": substate_col.get(index, "") if substate_col else "",
            "status_a": _int_or_zero(status_a_col.get(index)) if status_a_col else 0,
            "max_status_a": _int_or_zero(max_status_a_col.get(index)) if max_status_a_col else 0,
            "status_b": _int_or_zero(status_b_col.get(index)) if status_b_col else 0,
            "max_status_b": _int_or_zero(max_status_b_col.get(index)) if max_status_b_col else 0,
            "info": info_col.get(index, "") if info_col else "",
            "leapsecond_date": leapsecond_col.get(index, "") if leapsecond_col else "",
        }
    return clocks


def _verbose_clock_type(clock_type):
    return REFCLOCK_TYPES.get(clock_type, None) or ("unknown (" + clock_type + ")")


def _verbose_substate(substate):
    if substate == "0":
        return None
    return REFCLOCK_SUBSTATES.get(substate, None)


def _is_gps(clock):
    if clock["clock_type"] not in REFCLOCK_TYPES:
        return None
    return "gps" in _verbose_clock_type(clock["clock_type"])


def _result_state(clock_state, clock_type):
    state = REFCLOCK_STATE_TO_LEVEL.get(clock_state, "UNKNOWN")
    type_state = "OK" if clock_type in REFCLOCK_TYPES else "WARN"
    return _worst_state(state, type_state)


def _satellite_level(status_a, levels_lower):
    """Return (state, label, metric_value, warn, crit).

    lower levels: WARN if value <= warn, CRIT if value <= crit.
    levels_lower is expected as a tuple (warn, crit) or list.
    """
    warn = None
    crit = None
    if levels_lower != None:
        pairs = levels_lower
        if type(pairs) == "list":
            pairs = tuple(pairs) if False else pairs
        if type(pairs) == "tuple":
            if len(pairs) >= 2:
                crit = pairs[1]
                warn = pairs[0]
            elif len(pairs) == 2:
                crit = pairs[1]
                warn = pairs[0]
    state = "OK"
    if crit != None and status_a <= crit:
        state = "CRIT"
    elif warn != None and status_a <= warn:
        state = "WARN"
    return (state, warn, crit)


def main(ctx, params):
    if params.get("_discover"):
        if not _is_lantime(ctx, params):
            return {"changed": False, "msg": "Meinberg LANTIME NG not detected", "data": {"discovery": []}}
        clocks = _build_clocks(ctx, params)
        if clocks == None:
            return {"changed": False, "msg": "refclock table not reachable", "data": {"discovery": []}}
        out = []
        for index, clock in clocks.items():
            is_gps = _is_gps(clock)
            if is_gps:
                out.append({"item": clock["item"], "params": {"levels_lower": [3, 3]},
                            "metrics": ["satellites"]})
        return {"changed": False, "msg": "discovered %d GPS refclock items" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if not _is_lantime(ctx, params):
        return {"changed": False, "msg": "Meinberg LANTIME NG not detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    clocks = _build_clocks(ctx, params)
    if clocks == None:
        return {"changed": False, "msg": "refclock SNMP table not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    clock = None
    for index, c in clocks.items():
        if c["item"] == item:
            clock = c
            break
    if clock == None:
        return {"changed": False, "msg": "no such GPS refclock item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    verbose_type = _verbose_clock_type(clock["clock_type"])
    detailed_state = ""
    sub = _verbose_substate(clock["substate"])
    if sub != None:
        detailed_state = " (" + sub + ")"
    infotext = "Type: %s, Usage: %s, State: %s%s" % (
        verbose_type,
        REFCLOCK_SUBSTATES.get(clock["usage"], clock["usage"]),
        REFCLOCK_STATE_TO_LEVEL.get(clock["state"], "UNKNOWN"),
        detailed_state,
    )

    main_state = _result_state(clock["state"], clock["clock_type"])

    lines = [infotext]
    metrics = {}

    leapsecond_date = clock["leapsecond_date"]
    if leapsecond_date != "" and leapsecond_date != None:
        if str(clock["substate"]) not in ("1", "2"):
            lines.append("Next leap second: " + str(leapsecond_date))

    substate_val = str(clock["substate"])
    if substate_val in GPS_SATELLITE_SUBSTATES:
        levels_lower = params.get("levels_lower", [3, 3])
        sat_state, warn_l, crit_l = _satellite_level(clock["status_a"], levels_lower)
        max_sat = clock["max_status_a"]
        label = "Satellites (total: %d)" % max_sat
        lines.append("%s: %d" % (label, clock["status_a"]))
        metrics["satellites"] = clock["status_a"]
        main_state = _worst_state(main_state, sat_state)

    msg = "; ".join(lines)
    return {"changed": False, "msg": msg,
            "data": {"state": main_state, "metrics": metrics, "details": "\n".join(lines)}}