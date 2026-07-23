def main(ctx, params):
    # SNMP base and OIDs from the source
    base_oid = ".1.3.6.1.4.1.5597.30.0.1.2.1"
    oids = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        items = []
        # Parse snmpwalk output: "<oid> = <type>: <value>"
        lines = res.stdout.splitlines()
        # Build per-row dictionaries; each row has 11 values
        row = []
        for line in lines:
            if len(line) == 0:
                continue
            # Split into OID part and value part
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            value_part = parts[1].strip()
            # Extract value after type prefix (e.g., "INTEGER: 1" or "STRING: foo")
            if value_part.startswith("INTEGER:"):
                val = value_part[10:].strip()
            elif value_part.startswith("STRING:"):
                val = value_part[7:].strip().strip('"')
            elif value_part.startswith("OctetString:"):
                val = value_part[12:].strip().strip('"')
            else:
                val = value_part
            row.append(val)
            if len(row) == 11:
                # One row complete
                clock_type = row[1]
                verbose = REFCLOCK_TYPES.get(clock_type, None)
                is_gps = (verbose != None) and ("gps" in verbose.lower())
                if is_gps:
                    item = row[0]
                    items.append({
                        "item": item,
                        "params": {"levels_lower": ["fixed", [3, 3]]},
                        "metrics": ["satellites"]
                    })
                row = []
        return {"changed": False, "msg": "discovered %d GPS refclocks" % len(items),
                "data": {"discovery": items}}

    # Check mode
    item = params.get("item", "")
    if item == "":
        fail("item must be provided for check mode")
    # Query specific item OID (first OID in each row) with snmpwalk
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    lines = res.stdout.splitlines()
    row = []
    for line in lines:
        if len(line) == 0:
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER:"):
            val = value_part[10:].strip()
        elif value_part.startswith("STRING:"):
            val = value_part[7:].strip().strip('"')
        elif value_part.startswith("OctetString:"):
            val = value_part[12:].strip().strip('"')
        else:
            val = value_part
        row.append(val)
        if len(row) == 11:
            if row[0] == item:
                break
            row = []
    if len(row) != 11 or row[0] != item:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    clock_item, clock_type, usage, state, substate, status_a, max_status_a, status_b, max_status_b, info, leapsecond_date = row
    # Map types
    verbose_type = REFCLOCK_TYPES.get(clock_type, "unknown (" + clock_type + ")")
    verbose_usage = REFCLOCK_USAGES.get(usage, None)
    verbose_state = REFCLOCK_STATES.get(state, None)
    verbose_substate = REFCLOCK_SUBSTATES.get(substate, None)
    # Determine state
    state_value = REFCLOCK_STATES_STATE.get(state, "UNKNOWN")
    type_ok = clock_type in REFCLOCK_TYPES
    if type_ok:
        final_state = state_value
    else:
        final_state = "WARN"
    # State to string
    if final_state == "UNKNOWN":
        state_str = "UNKNOWN"
    elif final_state == "CRIT":
        state_str = "CRIT"
    elif final_state == "WARN":
        state_str = "WARN"
    else:
        state_str = "OK"

    # Build infotext
    detailed_state_txt = " (" + verbose_substate + ")" if (substate != "0" and verbose_substate != None) else ""
    infotext = "Type: " + verbose_type + ", Usage: " + (verbose_usage or "unknown") + ", State: " + (verbose_state or "unknown") + detailed_state_txt

    # Metrics
    metrics = {}
    # Satellites check for GPS
    substates_to_check = ["1", "2", "3", "4", "5", "6", "150"]
    levels = params.get("levels_lower", ["fixed", [3, 3]])
    if isinstance(levels, list) and len(levels) == 2 and levels[0] == "fixed":
        warn_level = levels[1][0]
        crit_level = levels[1][1]
    else:
        warn_level = 3
        crit_level = 3

    if substate in substates_to_check:
        sat_val = int(status_a)
        sat_max = int(max_status_a)
        metrics["satellites"] = sat_val
        # Determine levels
        if sat_val <= crit_level:
            state_str = "CRIT"
        elif sat_val <= warn_level:
            state_str = "WARN" if state_str != "CRIT" else state_str
        # Add summary line
        infotext = infotext + ", Satellites: " + str(sat_val) + " (total: " + str(sat_max) + ")"

    # Field strength for non-GPS or optional metrics
    if int(max_status_b) != 0:
        field_val = int(status_b)
        field_max = int(max_status_b)
        field_pct = int((field_val * 100.0) / field_max + 0.5)
        metrics["field_strength"] = field_pct
        infotext = infotext + ", Field strength: " + str(field_pct) + "%"

    # Correlation for longwave/pzf refclocks
    if int(max_status_a) != 0 and substate not in substates_to_check:
        corr_val = int(status_a)
        corr_max = int(max_status_a)
        corr_pct = int((corr_val * 100.0) / corr_max + 0.5)
        metrics["correlation"] = corr_pct
        infotext = infotext + ", Correlation: " + str(corr_pct) + "%"

    return {"changed": False, "msg": infotext,
            "data": {"state": state_str, "metrics": metrics, "details": ""}}


# Mappings defined at top level (Starlark requires definitions before use)
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
    "55": "scg", "56": "mdu300", "57": "sdi", "58": "fdm180", "59": "spt", "60": "pzf180",
    "61": "rel1000", "62": "hps100", "63": "vsg180", "64": "msf180", "65": "wwvb180",
    "66": "cpc180", "67": "ctc100", "68": "tcr180", "69": "lue180", "70": "cpc01",
    "71": "tsu01", "72": "cmc01", "73": "scu01", "74": "fcu01", "75": "mssb100",
    "76": "lne180sfp", "77": "gts180", "78": "gps180csm", "79": "grc181", "80": "n2x180",
    "81": "gns180pex", "82": "mdu180", "83": "mdu312", "84": "gps165", "85": "gns181uc",
    "86": "psx4GE", "87": "rsc180rdu", "88": "cpc200", "89": "fdm180m", "90": "lsg180",
    "91": "gps190", "92": "gns181", "93": "pio180", "94": "fcm180", "95": "tcr180usb",
    "96": "ssp100", "97": "gns165", "98": "rsc180rdmp", "99": "gps16x", "100": "mshps100",
    "101": "bpestm", "102": "vsi180", "103": "gnm181", "104": "rscrduttl", "105": "rsc2000",
    "106": "fcu200", "107": "rel1000rc", "108": "wsiug2864", "109": "vsg181", "110": "bps2xxx",
    "111": "bpe2352", "112": "bpe8XXX", "113": "bpe6042", "114": "gns190", "115": "gps180msbc",
    "116": "gns181msbc", "117": "gns181ucmsbc", "118": "prs181", "119": "ecm180",
    "120": "mro181", "121": "vsg181msbc", "122": "scg181", "123": "nimbra100", "124": "rsc180scu",
    "125": "pmu190", "126": "gns190uc", "127": "vmx180", "128": "rcg181", "129": "gns191",
    "130": "vsg181h", "131": "gps182", "132": "rsc1000", "133": "gns182", "134": "gns182uc",
    "135": "gsr190", "136": "gen182", "137": "cpe182", "138": "fdm182", "139": "fdm182m",
    "140": "pzf182", "141": "pzf183", "142": "bpe8nnn", "143": "n2x185", "144": "anz141",
    "145": "msf182", "146": "rel1002", "147": "gns183", "148": "gxl183", "149": "m3t"
}

REFCLOCK_USAGES = {
    "0": "not available", "1": "secondary", "2": "compare", "3": "primary"
}

REFCLOCK_STATES = {
    "0": "not available", "1": "synchronized", "2": "not synchronized"
}

REFCLOCK_STATES_STATE = {
    "0": "CRIT", "1": "OK", "2": "WARN"
}

REFCLOCK_SUBSTATES = {
    "-1": "MRS Ref None", "0": "not available", "1": "GPS sync", "2": "GPS tracking",
    "3": "GPS antenna disconnected", "4": "GPS warm boot", "5": "GPS cold boot",
    "6": "GPS antenna short circuit", "50": "LW never sync", "51": "LW not sync",
    "52": "LW sync", "100": "TCR not sync", "101": "TCT sync", "149": "MRS internal oscillator sync",
    "150": "MRS GPS sync", "151": "MRS 10Mhz sync", "152": "MRS PPS in sync",
    "153": "MRS 10Mhz PPS in sync", "154": "MRS IRIG sync", "155": "MRS NTP sync",
    "156": "MRS PTP IEEE 1588 sync", "157": "MRS PTP over E1 sync", "158": "MRS fixed frequency in sync",
    "159": "MRS PPS string sync", "160": "MRS variable frequency GPIO sync", "161": "MRS reserved",
    "162": "MRS DCF77 PZF sync", "163": "MRS longwave sync", "164": "MRS GLONASS GPS sync",
    "165": "MRS HAVE QUICK sync", "166": "MRS external oscillator sync", "167": "MRS SyncE",
    "168": "MRS video in sync", "169": "MRS ltc sync", "170": "MRS osc sync"
}