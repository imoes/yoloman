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

REFCLOCK_USAGES = {
    "0": "not available",
    "1": "secondary",
    "2": "compare",
    "3": "primary",
}

REFCLOCK_STATES = {
    "0": "not available",
    "1": "synchronized",
    "2": "not synchronized",
}

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
    "171": "MRS osc sync",
}

REFCLOCK_STATES_STATE = {
    "0": "CRIT",
    "1": "OK",
    "2": "WARN",
}


def _get_verbose_name(value, mapping):
    return mapping.get(value, None)


def _is_gps(clock_type, verbose_clock_type):
    if clock_type not in REFCLOCK_TYPES:
        return False
    return ("gps" in verbose_clock_type.lower()) if verbose_clock_type else False


def _int_safe(val):
    if val == None:
        return 0
    if type(val) == "string":
        return int(val) if val.isdigit() or (val.startswith("-") and val[1:].isdigit()) else 0
    return int(val) if type(val) == "int" else 0


def _round(val):
    return int(val + 0.5)


def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.5597.30.0.1.2.1"
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host,
            base_oid
        ], mutates=False)
        lines = res.stdout.splitlines()
        clocks = {}
        for line in lines:
            if not line or " = " not in line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0]
            value = parts[1]
            if ": " in value:
                value = value.split(": ", 1)[1].strip().strip('"')
            oid_parts = oid_full.split(".")
            if len(oid_parts) < 12:
                continue
            idx = oid_parts[11]
            oid_num = oid_parts[12]
            if idx not in clocks:
                clocks[idx] = {}
            clocks[idx][oid_num] = value

        refclocks = []
        for idx, data in clocks.items():
            item = data.get("1", "")
            clock_type = data.get("2", "0")
            usage = data.get("3", "0")
            state = data.get("4", "0")
            substate = data.get("5", "0")
            status_a = _int_safe(data.get("6", "0"))
            max_status_a = _int_safe(data.get("7", "0"))
            status_b = _int_safe(data.get("8", "0"))
            max_status_b = _int_safe(data.get("9", "0"))
            info = data.get("10", "")
            leapsecond_date = data.get("11", "")

            verbose_clock_type = _get_verbose_name(clock_type, REFCLOCK_TYPES)
            if verbose_clock_type == None:
                verbose_clock_type = "unknown (" + str(clock_type) + ")"
            is_gps = _is_gps(clock_type, verbose_clock_type)

            refclocks.append({
                "item": item,
                "clock_type": clock_type,
                "usage": usage,
                "state": state,
                "substate": substate,
                "status_a": status_a,
                "max_status_a": max_status_a,
                "status_b": status_b,
                "max_status_b": max_status_b,
                "info": info,
                "leapsecond_date": leapsecond_date,
                "is_gps": is_gps,
            })

        discovery = []
        for rc in refclocks:
            if rc["is_gps"]:
                discovery.append({
                    "item": rc["item"],
                    "params": {"levels_lower": ["fixed", [3, 3]]},
                    "metrics": ["satellites", "field_strength", "correlation"]
                })

        return {
            "changed": False,
            "msg": "discovered %d GPS refclocks" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.5597.30.0.1.2.1"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host,
        base_oid
    ], mutates=False)

    lines = res.stdout.splitlines()
    clocks = {}
    for line in lines:
        if not line or " = " not in line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0]
        value = parts[1]
        if ": " in value:
            value = value.split(": ", 1)[1].strip().strip('"')
        oid_parts = oid_full.split(".")
        if len(oid_parts) < 12:
            continue
        idx = oid_parts[11]
        oid_num = oid_parts[12]
        if idx not in clocks:
            clocks[idx] = {}
        clocks[idx][oid_num] = value

    rc_data = None
    for idx, data in clocks.items():
        if data.get("1", "") == item:
            clock_type = data.get("2", "0")
            usage = data.get("3", "0")
            state = data.get("4", "0")
            substate = data.get("5", "0")
            status_a = _int_safe(data.get("6", "0"))
            max_status_a = _int_safe(data.get("7", "0"))
            status_b = _int_safe(data.get("8", "0"))
            max_status_b = _int_safe(data.get("9", "0"))
            info = data.get("10", "")
            leapsecond_date = data.get("11", "")

            verbose_clock_type = _get_verbose_name(clock_type, REFCLOCK_TYPES)
            if verbose_clock_type == None:
                verbose_clock_type = "unknown (" + str(clock_type) + ")"
            verbose_usage = _get_verbose_name(usage, REFCLOCK_USAGES)
            if verbose_usage == None:
                verbose_usage = "not available"
            verbose_state = _get_verbose_name(state, REFCLOCK_STATES)
            if verbose_state == None:
                verbose_state = "not available"
            verbose_substate = _get_verbose_name(substate, REFCLOCK_SUBSTATES)

            is_gps = _is_gps(clock_type, verbose_clock_type)

            rc_data = {
                "clock_type": clock_type,
                "usage": usage,
                "state": state,
                "substate": substate,
                "status_a": status_a,
                "max_status_a": max_status_a,
                "status_b": status_b,
                "max_status_b": max_status_b,
                "info": info,
                "leapsecond_date": leapsecond_date,
                "verbose_clock_type": verbose_clock_type,
                "verbose_usage": verbose_usage,
                "verbose_state": verbose_state,
                "verbose_substate": verbose_substate,
                "is_gps": is_gps,
            }
            break

    if rc_data == None:
        return {
            "changed": False,
            "msg": "refclock item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_raw = rc_data.get("state", "0")
    type_state_raw = "OK" if rc_data.get("clock_type", "") in REFCLOCK_TYPES else "WARN"
    state_map = REFCLOCK_STATES_STATE.get(state_raw, "UNKNOWN")
    def worst_state(a, b):
        order = {"CRIT": 0, "WARN": 1, "OK": 2, "UNKNOWN": 3}
        return "CRIT" if order.get(a, 3) <= order.get(b, 3) else b
    state = worst_state(state_map, type_state_raw)

    detailed_state_txt = " (%s)" % rc_data.get("verbose_substate", "") if rc_data.get("substate", "0") != "0" else ""
    infotext = "Type: %s, Usage: %s, State: %s%s" % (
        rc_data.get("verbose_clock_type", "unknown"),
        rc_data.get("verbose_usage", "not available"),
        rc_data.get("verbose_state", "not available"),
        detailed_state_txt
    )

    metrics = {}
    details = ""

    if rc_data.get("is_gps"):
        levels_lower = params.get("levels_lower", ["fixed", [3, 3]])
        levels_mode = levels_lower[0]
        if levels_mode == "fixed":
            warn_low = levels_lower[1][0]
            crit_low = levels_lower[1][1]
        else:
            warn_low = 3
            crit_low = 3
        sat = rc_data.get("status_a", 0)
        max_sat = rc_data.get("max_status_a", 0)
        metrics["satellites"] = sat
        if rc_data.get("substate") in ("1", "2", "3", "4", "5", "6", "150"):
            if sat <= crit_low:
                state = "CRIT"
            elif sat <= warn_low:
                state = "WARN"
            infotext = infotext + ", Satellites (total: %d): %d" % (max_sat, sat)
            details = "Satellites (total: %d): %d" % (max_sat, sat)
        else:
            infotext = infotext + ", Satellites (total: %d): %d" % (max_sat, sat)
            details = "Satellites (total: %d): %d" % (max_sat, sat)

        if rc_data.get("substate") not in ("1", "2"):
            infotext = infotext + ", Next leap second: %s" % rc_data.get("leapsecond_date", "")
    else:
        if rc_data.get("max_status_b", 0) != 0:
            field_strength = float(rc_data.get("status_b", 0)) / float(rc_data.get("max_status_b", 1)) * 100.0
            field_strength = _round(field_strength)
            metrics["field_strength"] = field_strength
            infotext = infotext + ", Field strength: %d%%" % field_strength
        if rc_data.get("max_status_a", 0) != 0:
            correlation = float(rc_data.get("status_a", 0)) / float(rc_data.get("max_status_a", 1)) * 100.0
            correlation = _round(correlation)
            metrics["correlation"] = correlation
            infotext = infotext + ", Correlation: %d%%" % correlation

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }