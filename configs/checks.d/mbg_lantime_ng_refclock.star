REFCLOCK_TYPES = {
    "0": "unknown", "1": "gps166", "2": "gps167", "3": "gps167SV", "4": "gps167PC",
    "5": "gps167PCI", "6": "gps163", "7": "gps168PCI", "8": "gps161", "9": "gps169PCI",
    "10": "tcr167PCI", "11": "gps164", "12": "gps170PCI", "13": "pzf511", "14": "gps170",
    "15": "tcr511", "16": "am511", "17": "msf511", "18": "grc170", "19": "gps170PEX",
    "20": "gps162", "21": "ptp270PEX", "22": "frc511PEX", "23": "gen170", "24": "tcr170PEX",
    "25": "wwvb511", "26": "mgr170", "27": "jjy511", "28": "pzf600", "29": "tcr600",
    "30": "gps180", "31": "gln170", "32": "gps180PEX", "33": "tcr180PEX", "34": "pzf180PEX",
    "35": "mgr180", "36": "msf600", "37": "wwvb600", "38": "jjy600", "39": "gps180HS",
    "40": "gps180AMC", "41": "esi180", "42": "cpe180", "43": "lno180", "44": "grc180",
    "45": "liu", "46": "dcf600HS", "47": "dcf600RS", "48": "mri", "49": "bpe",
    "50": "gln180Pex", "51": "n2x", "52": "rsc180", "53": "lneGb", "54": "lnePpg180",
    "55": "scg", "56": "mdu300", "57": "sdi", "58": "fdm180", "59": "spt",
    "60": "pzf180", "61": "rel1000", "62": "hps100", "63": "vsg180", "64": "msf180",
    "65": "wwvb180", "66": "cpc180", "67": "ctc100", "68": "tcr180", "69": "lue180",
    "70": "cpc01", "71": "tsu01", "72": "cmc01", "73": "scu01", "74": "fcu01",
    "75": "mssb100", "76": "lne180sfp", "77": "gts180", "78": "gps180csm", "79": "grc181",
    "80": "n2x180", "81": "gns180pex", "82": "mdu180", "83": "mdu312", "84": "gps165",
    "85": "gns181uc", "86": "psx4GE", "87": "rsc180rdu", "88": "cpc200", "89": "fdm180m",
    "90": "lsg180", "91": "gps190", "92": "gns181", "93": "pio180", "94": "fcm180",
    "95": "tcr180usb", "96": "ssp100", "97": "gns165", "98": "rsc180rdmp", "99": "gps16x",
    "100": "mshps100", "101": "bpestm", "102": "vsi180", "103": "gnm181", "104": "rscrduttl",
    "105": "rsc2000", "106": "fcu200", "107": "rel1000rc", "108": "wsiug2864", "109": "vsg181",
    "110": "bps2xxx", "111": "bpe2352", "112": "bpe8XXX", "113": "bpe6042", "114": "gns190",
    "115": "gps180msbc", "116": "gns181msbc", "117": "gns181ucmsbc", "118": "prs181", "119": "ecm180",
    "120": "mro181", "121": "vsg181msbc", "122": "scg181", "123": "nimbra100", "124": "rsc180scu",
    "125": "pmu190", "126": "gns190uc", "127": "vmx180", "128": "rcg181", "129": "gns191",
    "130": "vsg181h", "131": "gps182", "132": "rsc1000", "133": "gns182", "134": "gns182uc",
    "135": "gsr190", "136": "gen182", "137": "cpe182", "138": "fdm182", "139": "fdm182m",
    "140": "pzf182", "141": "pzf183", "142": "bpe8nnn", "143": "n2x185", "144": "anz141",
    "145": "msf182", "146": "rel1002", "147": "gns183", "148": "gxl183", "149": "m3t",
}
REFCLOCK_USAGES = {
    "0": "not available", "1": "secondary", "2": "compare", "3": "primary",
}
REFCLOCK_STATES = {
    "0": "not available", "1": "synchronized", "2": "not synchronized",
}
REFCLOCK_STATES_STATE = {
    "0": "CRIT", "1": "OK", "2": "WARN",
}
REFCLOCK_SUBSTATES = {
    "-1": "MRS Ref None", "0": "not available", "1": "GPS sync", "2": "GPS tracking",
    "3": "GPS antenna disconnected", "4": "GPS warm boot", "5": "GPS cold boot",
    "6": "GPS antenna short circuit", "50": "LW never sync", "51": "LW not sync",
    "52": "LW sync", "100": "TCR not sync", "101": "TCT sync", "149": "MRS internal oscillator sync",
    "150": "MRS GPS sync", "151": "MRS 10Mhz sync", "152": "MRS PPS in sync", "153": "MRS 10Mhz PPS in sync",
    "154": "MRS IRIG sync", "155": "MRS NTP sync", "156": "MRS PTP IEEE 1588 sync",
    "157": "MRS PTP over E1 sync", "158": "MRS fixed frequency in sync", "159": "MRS PPS string sync",
    "160": "MRS variable frequency GPIO sync", "161": "MRS reserved", "162": "MRS DCF77 PZF sync",
    "163": "MRS longwave sync", "164": "MRS GLONASS GPS sync", "165": "MRS HAVE QUICK sync",
    "166": "MRS external oscillator sync", "167": "MRS SyncE", "168": "MRS video in sync",
    "169": "MRS ltc sync", "170": "MRS osc sync",
}

def _to_int(v):
    if v == None:
        return 0
    s = str(v)
    i = s.find(" ")
    if i >= 0:
        s = s[:i]
    return int(s) if s.lstrip("-").isdigit() else 0

def _round_int(x):
    if x >= 0:
        return int(x + 0.5)
    return int(x - 0.5)

def _snmp_get(ctx, oid, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    return res.stdout.strip() if res.rc == 0 else ""

def _is_lantime(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    return val.endswith(".1.3.6.1.4.1.5597.3") or val.endswith(".1.3.6.1.4.1.5597.30")

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    if params.get("_discover"):
        if not _is_lantime(ctx, community, host):
            return {"changed": False, "msg": "no LANTIME device found",
                    "data": {"discovery": []}}
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.5597.30.0.1.2.1.1"],
            mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "no refclock entries found",
                    "data": {"discovery": []}}
        base = ".1.3.6.1.4.1.5597.30.0.1.2.1.1"
        discovery = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            idx = parts[0]
            if not idx.startswith(base + "."):
                continue
            idx = idx[len(base) + 1:]
            ct = _snmp_get(ctx, base + ".2." + idx, community, host)
            v_clock_type = REFCLOCK_TYPES.get(ct, "unknown (" + ct + ")") if ct in REFCLOCK_TYPES else "unknown (" + ct + ")"
            if "gps" in v_clock_type:
                discovery.append({"item": idx, "params": {"levels_lower": [3, 3]},
                                  "metrics": ["status_a"]})
            else:
                discovery.append({"item": idx, "params": {},
                                  "metrics": ["field_strength", "correlation"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    base = ".1.3.6.1.4.1.5597.30.0.1.2.1.1"
    suffix = ".1." + item
    oids = {
        "clock_type": base + ".2" + suffix,
        "usage": base + ".3" + suffix,
        "state": base + ".4" + suffix,
        "substate": base + ".5" + suffix,
        "status_a": base + ".6" + suffix,
        "max_status_a": base + ".7" + suffix,
        "status_b": base + ".8" + suffix,
        "max_status_b": base + ".9" + suffix,
        "info": base + ".10" + suffix,
        "leapsecond_date": base + ".11" + suffix,
    }
    vals = {}
    for k, oid in oids.items():
        vals[k] = _snmp_get(ctx, oid, community, host)
    if vals["clock_type"] == "" and vals["state"] == "":
        return {"changed": False, "msg": "refclock item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ct = vals["clock_type"]
    usage = vals["usage"]
    st = vals["state"]
    sub = vals["substate"]
    sa = _to_int(vals["status_a"])
    msa = _to_int(vals["max_status_a"])
    sb = _to_int(vals["status_b"])
    msb = _to_int(vals["max_status_b"])

    v_clock_type = REFCLOCK_TYPES.get(ct, "unknown (" + ct + ")") if ct in REFCLOCK_TYPES else "unknown (" + ct + ")"
    v_usage = REFCLOCK_USAGES.get(usage)
    v_state = REFCLOCK_STATES.get(st)
    v_substate = REFCLOCK_SUBSTATES.get(sub)

    state_lookup = {"0": "CRIT", "1": "OK", "2": "WARN"}
    result_state = state_lookup.get(st, "UNKNOWN")
    if ct not in REFCLOCK_TYPES:
        if result_state == "OK":
            result_state = "WARN"

    details = []
    for k in ["clock_type", "usage", "state", "substate", "status_a", "max_status_a",
              "status_b", "max_status_b", "info", "leapsecond_date"]:
        details.append(k + ": " + vals[k])
    details_str = "\n".join(details)

    detailed = " (" + v_substate + ")" if v_substate != None and sub != "0" else ""
    summary = "Type: %s, Usage: %s, State: %s%s" % (v_clock_type, v_usage, v_state, detailed)

    metrics = {}
    is_gps = "gps" in v_clock_type

    if is_gps:
        if sub in ("1", "2", "3", "4", "5", "6", "150"):
            levels = params.get("levels_lower", [3, 3])
            warn_lvl = levels[0] if len(levels) >= 1 else 3
            crit_lvl = levels[1] if len(levels) >= 2 else 3
            sat_state = "CRIT" if sa <= crit_lvl else ("WARN" if sa <= warn_lvl else "OK")
            if sat_state == "CRIT":
                result_state = "CRIT"
            elif sat_state == "WARN" and result_state != "CRIT":
                result_state = "WARN"
        metrics["status_a"] = sa
    else:
        if msb != 0:
            fs = _round_int(float(sb) / float(msb) * 100.0)
            metrics["field_strength"] = fs
            summary = summary + "\nField strength: %d%%" % fs
        if msa != 0:
            corr = _round_int(float(sa) / float(msa) * 100.0)
            metrics["correlation"] = corr
            summary = summary + "\nCorrelation: %d%%" % corr

    if sub not in ("1", "2") and is_gps:
        summary = summary + "\nNext leap second: " + vals["leapsecond_date"]

    return {"changed": False, "msg": summary,
            "data": {"state": result_state, "metrics": metrics, "details": details_str}}