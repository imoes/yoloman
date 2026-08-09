_BROCADE_FCPORT_PHYSTATES = {
    1: "no card", 2: "no transceiver", 3: "laser fault", 4: "no light",
    5: "no sync", 6: "in sync", 7: "port fault", 8: "diag fault",
    9: "lock ref", 10: "validating", 11: "invalid module", 12: "remote fault",
    13: "local fault", 14: "no sig det", 15: "hard fault", 16: "unsupported module",
    17: "module fault", 255: "unknown",
}

_BROCADE_FCPORT_OPSTATES = {
    0: "unknown", 1: "online", 2: "offline", 3: "testing", 4: "faulty",
}

_BROCADE_FCPORT_ADMSTATES = {
    0: "", 1: "online", 2: "offline", 3: "testing", 4: "faulty",
}

_BROCADE_FCPORT_SPEED = {
    0: "unknown", 1: "1Gbit", 2: "2Gbit", 3: "auto-Neg", 4: "4Gbit",
    5: "8Gbit", 6: "10Gbit", 7: "unknown", 8: "16Gbit",
}

_ISL_SPEED_MAP = {
    "1": 0, "2": 0.155, "4": 0.266, "8": 0.532, "16": 1,
    "32": 2, "64": 4, "128": 8, "256": 10, "512": 16,
}

_FC_PORT_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1"
_FC_PORT_OIDS = [
    "1", "3", "4", "5", "11", "12", "13", "14",
    "20", "22", "21", "26", "28", "35", "36",
]

_ISL_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.2.9.1"
_ISL_OIDS = ["2", "5"]

_IF_BASE = ".1.3.6.1.2.1"
_IF_OIDS = ["2.2.1.3", "31.1.1.1.15"]

_FCMGMT_BASE = ".1.3.6.1.3.94.4.5.1"
_FCMGMT_OIDS = ["4", "5", "6", "7", "8"]

DISCOVERY_DEFAULT_PARAMETERS = {
    "admstates": [1, 3, 4],
    "phystates": [3, 4, 5, 6, 7, 8, 9, 10],
    "opstates": [1, 2, 3, 4],
    "use_portname": True,
    "show_isl": True,
}

CHECK_DEFAULT_PARAMETERS = {
    "rxcrcs": (3.0, 20.0),
    "rxencoutframes": (3.0, 20.0),
    "rxencinframes": (3.0, 20.0),
    "notxcredits": (3.0, 20.0),
    "c3discards": (3.0, 20.0),
    "assumed_speed": 2.0,
}

def _is_int_str(s):
    if s == "" or s == None:
        return False
    if s[0] == "-":
        return s[1:].isdigit()
    return s.isdigit()

def _to_int_safe(s, default):
    return int(s) if _is_int_str(s) else default

def _to_int_be(bytes_list):
    value = 0
    mult = 1
    for b in reversed(bytes_list):
        value = value + mult * b
        mult = mult * 256
    return value

def _walk_snmp(ctx, community, host, oid_base):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, oid_base],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return []
    return [line for line in res.stdout.splitlines() if line]

def _collect_snmp_data(ctx, community, host):
    if_info = {}
    link_info = {}
    if_speed_map = {}
    if64_info = {}

    for col_oid in _FC_PORT_OIDS:
        full_base = _FC_PORT_BASE + "." + col_oid
        lines = _walk_snmp(ctx, community, host, full_base)
        parsed = {}
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(full_base) + 1:]
            if not idx:
                continue
            parsed[idx] = parts[1].strip()
        if_info[col_oid] = parsed

    for col_oid in _ISL_OIDS:
        full_base = _ISL_BASE + "." + col_oid
        lines = _walk_snmp(ctx, community, host, full_base)
        parsed = {}
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(full_base) + 1:]
            if not idx:
                continue
            parsed[idx] = parts[1].strip()
        link_info[col_oid] = parsed

    for col_oid in _IF_OIDS:
        full_base = _IF_BASE + "." + col_oid
        lines = _walk_snmp(ctx, community, host, full_base)
        parsed = {}
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(full_base) + 1:]
            if not idx:
                continue
            parsed[idx] = parts[1].strip()
        speed_info_col = parsed
        if col_oid == "2.2.1.3":
            for idx, val in speed_info_col.items():
                if val == "56":
                    if_speed_map[idx] = if_speeds.get(idx, "")
        if col_oid == "31.1.1.1.15":
            if_speeds = parsed

    # Re-walk IF-MIB to properly associate ifType and ifHighSpeed
    if_types_raw = {}
    if_speeds_raw = {}
    for col_oid in _IF_OIDS:
        full_base = _IF_BASE + "." + col_oid
        lines = _walk_snmp(ctx, community, host, full_base)
        parsed = {}
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(full_base) + 1:]
            if not idx:
                continue
            parsed[idx] = parts[1].strip()
        if col_oid == "2.2.1.3":
            if_types_raw = parsed
        if col_oid == "31.1.1.1.15":
            if_speeds_raw = parsed

    if_speed_map = {}
    for idx in if_types_raw:
        if if_types_raw[idx] == "56":
            if_speed_map[idx] = if_speeds_raw.get(idx, "")

    for col_oid in _FCMGMT_OIDS:
        full_base = _FCMGMT_BASE + "." + col_oid
        lines = _walk_snmp(ctx, community, host, full_base)
        parsed = {}
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            idx = oid[len(full_base) + 1:]
            if not idx:
                continue
            parsed[idx] = parts[1].strip()
        if64_info[col_oid] = parsed

    return {
        "if_info": if_info,
        "link_info": link_info,
        "if_speed_map": if_speed_map,
        "if64_info": if64_info,
    }

def _get_int_from_table(table, col_oid, idx):
    val = table.get(col_oid, {}).get(idx, "")
    return _to_int_safe(val, 0)

def _get_oid_bytes_value(val):
    if val == "" or val == None:
        return 0
    result = _to_int_safe(val, -1)
    if result != -1:
        return result
    cleaned = val.replace(":", "").replace(" ", "")
    if len(cleaned) == 0:
        return 0
    bytes_list = []
    ok = True
    for i in range(0, len(cleaned), 2):
        pair = cleaned[i:i+2]
        if len(pair) < 2 or not _is_int_str(pair):
            ok = False
            break
        bytes_list.append(int(pair, 16))
    if ok and bytes_list:
        return _to_int_be(bytes_list)
    return 0

def _gather_snmp_data(ctx, community, host):
    raw = _collect_snmp_data(ctx, community, host)
    if_info = raw["if_info"]
    link_info = raw["link_info"]
    if_speed_map = raw["if_speed_map"]
    if64_info = raw["if64_info"]

    indices = sorted(if_info.get("1", {}).keys())
    if not indices:
        return []

    isl_ports = {}
    my_port_col = link_info.get("2", {})
    baud_col = link_info.get("5", {})
    for idx in my_port_col:
        isl_ports[idx] = baud_col.get(idx, "")

    offset = 0
    first_idx_val = if_info.get("1", {}).get(indices[0], "")
    if _is_int_str(first_idx_val):
        offset = int(first_idx_val) - 1

    parsed = []
    for idx in indices:
        data = {
            "index": _to_int_safe(idx, 0),
            "phystate": _get_int_from_table(if_info, "3", idx),
            "opstate": _get_int_from_table(if_info, "4", idx),
            "admstate": _get_int_from_table(if_info, "5", idx),
            "txwords": _get_int_from_table(if_info, "11", idx),
            "rxwords": _get_int_from_table(if_info, "12", idx),
            "txframes": _get_int_from_table(if_info, "13", idx),
            "rxframes": _get_int_from_table(if_info, "14", idx),
            "notxcredits": _get_int_from_table(if_info, "20", idx),
            "rxcrcs": _get_int_from_table(if_info, "22", idx),
            "rxencinframes": _get_int_from_table(if_info, "21", idx),
            "rxencoutframes": _get_int_from_table(if_info, "26", idx),
            "c3discards": _get_int_from_table(if_info, "28", idx),
            "brocade_speed_raw": if_info.get("35", {}).get(idx, ""),
            "portname": if_info.get("36", {}).get(idx, ""),
            "porttype": if_speed_map.get(idx, ""),
            "ifspeed_raw": if_speed_map.get(idx, ""),
            "is_isl": idx in isl_ports,
        }
        data["brocade_speed"] = data["brocade_speed_raw"] if data["brocade_speed_raw"] == "" else _to_int_safe(data["brocade_speed_raw"], None) if data["brocade_speed_raw"] != "" else None
        bs_raw = data["brocade_speed_raw"]
        if bs_raw == "":
            data["brocade_speed"] = None
        elif _is_int_str(bs_raw):
            data["brocade_speed"] = int(bs_raw)
        else:
            data["brocade_speed"] = None
        if_raw = data["ifspeed_raw"]
        if if_raw == "":
            data["ifspeed"] = None
        elif _is_int_str(if_raw):
            data["ifspeed"] = int(if_raw)
        else:
            data["ifspeed"] = None
        data["islspeed"] = None
        if data["is_isl"]:
            baud_val = isl_ports.get(idx, "")
            data["islspeed"] = _ISL_SPEED_MAP.get(baud_val, 0)
        data["bbcredits"] = None
        if if64_info:
            if64_tx_objects = if64_info.get("4", {}).get(idx, "")
            if64_rx_objects = if64_info.get("5", {}).get(idx, "")
            if64_tx_elements = if64_info.get("6", {}).get(idx, "")
            if64_rx_elements = if64_info.get("7", {}).get(idx, "")
            if64_bbcredits = if64_info.get("8", {}).get(idx, "")
            if if64_tx_objects != "":
                data["txframes"] = _get_oid_bytes_value(if64_tx_objects)
                data["rxframes"] = _get_oid_bytes_value(if64_rx_objects)
                data["txwords"] = int(_get_oid_bytes_value(if64_tx_elements) / 4)
                data["rxwords"] = int(_get_oid_bytes_value(if64_rx_elements) / 4)
                data["bbcredits"] = _get_oid_bytes_value(if64_bbcredits)
        parsed.append(data)
    return parsed

def _try_int(val):
    if val == "" or val == None:
        return None
    if _is_int_str(val):
        return int(val)
    return None

def _brocade_fcport_getitem(number_of_ports, index, portname, is_isl, settings):
    width = len(str(number_of_ports))
    itemname = ("%0" + str(width) + "d") % (index - 1)
    if is_isl and settings.get("show_isl", True):
        itemname += " ISL"
    if portname and portname.strip() and settings.get("use_portname", True):
        itemname += " " + portname.strip()
    return itemname

def _brocade_fcport_inventory_this_port(admstate, phystate, opstate, settings):
    if admstate not in settings.get("admstates", [1, 3, 4]):
        return False
    if phystate not in settings.get("phystates", [3, 4, 5, 6, 7, 8, 9, 10]):
        return False
    return opstate in settings.get("opstates", [1, 2, 3, 4])

def _get_speed_msg_and_value(is_isl, isl_speed, brocade_speed, porttype, if_speed, params):
    if is_isl and isl_speed != None and isl_speed != 0:
        return "ISL speed: %.0f Gbit/s", isl_speed

    brocade_speed_value = _BROCADE_FCPORT_SPEED.get(brocade_speed, "unknown")
    if brocade_speed_value not in ("auto-Neg", "unknown") and porttype != "56" and porttype != "":
        cleaned = brocade_speed_value.replace("Gbit", "")
        if _is_int_str(cleaned):
            speed_val = float(cleaned)
            return "%.0f Gbit/s", speed_val

    if if_speed != None and if_speed != "":
        speed_val = float(if_speed) / 1000.0
        return "Speed: %g Gbit/s", speed_val

    assumed = params.get("assumed_speed", 2.0)
    return "Assumed speed: %g Gbit/s", float(assumed)

def _iobandwidth(val):
    if val >= 1e9:
        return "%f GB/s" % (val / 1e9)
    if val >= 1e6:
        return "%f MB/s" % (val / 1e6)
    if val >= 1e3:
        return "%f KB/s" % (val / 1e3)
    return "%d B/s" % val

def _get_rate(state, key, current_time, current_value):
    if key not in state:
        state[key] = {"last_time": current_time, "last_value": current_value}
        return 0
    prev = state[key]
    delta_time = current_time - prev["last_time"]
    if delta_time <= 0:
        state[key] = {"last_time": current_time, "last_value": current_value}
        return 0
    delta_value = current_value - prev["last_value"]
    if delta_value < 0:
        delta_value = current_value
    rate = delta_value / delta_time
    state[key] = {"last_time": current_time, "last_value": current_value}
    return rate

def _get_average(state, key, current_time, value, minutes):
    if key not in state:
        state[key] = {"sum": value, "count": 1, "last_time": current_time}
        return value
    prev = state[key]
    delta_time = current_time - prev["last_time"]
    if delta_time > 0:
        decay = delta_time / (minutes * 60.0)
        if decay > 1:
            decay = 1
        if decay < 0:
            decay = 0
        prev["sum"] = prev["sum"] * (1 - decay) + value * decay
    else:
        prev["sum"] = (prev["sum"] * prev["count"] + value) / (prev["count"] + 1)
        prev["count"] = prev["count"] + 1
    prev["last_time"] = current_time
    return prev["sum"]

def _check_brocade_fcport(ctx, item, params, section, this_time, value_store):
    item_parts = item.split(" ", 1)
    item_index = _to_int_safe(item_parts[0], -1)
    if item_index < 0:
        return {"state": "UNKNOWN", "msg": "invalid item: " + str(item), "metrics": {}, "details": ""}

    found_entry = None
    for if_entry in section:
        if item_index + 1 == if_entry["index"]:
            found_entry = if_entry
            break

    if found_entry == None:
        return {"state": "UNKNOWN", "msg": "no port found for item: " + item,
                "metrics": {}, "details": ""}

    index = found_entry["index"]
    txwords = found_entry["txwords"]
    rxwords = found_entry["rxwords"]
    txframes = found_entry["txframes"]
    rxframes = found_entry["rxframes"]
    notxcredits = found_entry["notxcredits"]
    rxcrcs = found_entry["rxcrcs"]
    rxencinframes = found_entry["rxencinframes"]
    rxencoutframes = found_entry["rxencoutframes"]
    c3discards = found_entry["c3discards"]
    brocade_speed = found_entry.get("brocade_speed")
    is_isl = found_entry.get("is_isl", False)
    isl_speed = found_entry.get("islspeed")
    bbcredits = found_entry.get("bbcredits")
    porttype = found_entry.get("porttype", "")
    speed = found_entry.get("ifspeed")

    average = params.get("average")
    bw_thresh = params.get("bw")

    summarystate = 0
    output = []
    metrics = {}
    perfaverages = {}

    speedmsg, gbit = _get_speed_msg_and_value(
        is_isl, isl_speed, brocade_speed, porttype, speed, params
    )
    output.append(speedmsg % gbit)

    wirespeed = gbit * 1e9 / 8
    in_bytes = 4 * _get_rate(value_store, "rxwords.%s" % index, this_time, rxwords)
    out_bytes = 4 * _get_rate(value_store, "txwords.%s" % index, this_time, txwords)

    if bw_thresh == None:
        warn_bytes = None
        crit_bytes = None
    else:
        warn, crit = bw_thresh
        if type(warn) == "float":
            warn_bytes = wirespeed * warn / 100.0
        else:
            warn_bytes = warn * 1048576.0
        if type(crit) == "float":
            crit_bytes = wirespeed * crit / 100.0
        else:
            crit_bytes = crit * 1048576.0

    for what, value in [("in", in_bytes), ("out", out_bytes)]:
        output.append("%s: %s" % (what.capitalize(), _iobandwidth(value)))
        metrics[what] = value
        if average:
            avg_key = "%s.%s.avg" % (what, item)
            value = _get_average(value_store, avg_key, this_time, value, average)
            output.append("Average (%d min): %s" % (average, _iobandwidth(value)))
            perfaverages["%s_avg" % what] = value

        if crit_bytes != None and value >= crit_bytes:
            summarystate = 2
            output.append(" >= %s!!" % _iobandwidth(crit_bytes))
        elif warn_bytes != None and value >= warn_bytes:
            if 1 > summarystate:
                summarystate = 1
            output.append(" >= %s!" % _iobandwidth(warn_bytes))

    for k, v in perfaverages.items():
        metrics[k] = v

    rxframes_rate = _get_rate(value_store, "rxframes.%s" % index, this_time, rxframes)
    txframes_rate = _get_rate(value_store, "txframes.%s" % index, this_time, txframes)
    for what, value in [("rxframes", rxframes_rate), ("txframes", txframes_rate)]:
        metrics[what] = value
        if average:
            avg_key = "%s.%s.avg" % (what, item)
            value = _get_average(value_store, avg_key, this_time, value, average)
            metrics["%s_avg" % what] = value

    counters = [
        ("CRC errors", "rxcrcs", rxcrcs, rxframes_rate),
        ("ENC-Out", "rxencoutframes", rxencoutframes, rxframes_rate),
        ("ENC-In", "rxencinframes", rxencinframes, rxframes_rate),
        ("C3 discards", "c3discards", c3discards, txframes_rate),
        ("No TX buffer credits", "notxcredits", notxcredits, txframes_rate),
    ]

    for descr, counter, value, ref in counters:
        per_sec = _get_rate(value_store, "%s.%s" % (counter, index), this_time, value)
        metrics[counter] = per_sec

        if average:
            avg_key = ".%s.%s.avg" % (counter, item)
            per_sec_avg = _get_average(value_store, avg_key, this_time, per_sec, average)
            metrics["%s_avg" % counter] = per_sec_avg

        if ref > 0 or per_sec > 0:
            rate = per_sec / (ref + per_sec)
        else:
            rate = 0
        text = "%s: %f%%" % (descr, rate * 100.0)

        if average:
            rate_key = "%s.%s.avgrate" % (counter, item)
            rate = _get_average(value_store, rate_key, this_time, rate, average)
            text += ", Average: %f%%" % (rate * 100.0)

        error_percentage = rate * 100.0
        warn_crit = params.get(counter, (None, None))
        warn, crit = warn_crit
        if crit != None and error_percentage >= crit:
            summarystate = 2
            text += "!!"
            output.append(text)
        elif warn != None and error_percentage >= warn:
            if 1 > summarystate:
                summarystate = 1
            text += "!"
            output.append(text)

    state_info_list = [
        ("phystate", "Physical", (1, 6), _BROCADE_FCPORT_PHYSTATES),
        ("opstate", "Operational", (1, 3), _BROCADE_FCPORT_OPSTATES),
        ("admstate", "Administrative", (0, 1, 3), _BROCADE_FCPORT_ADMSTATES),
    ]

    for state_key, state_info_name, warn_states, state_map in state_info_list:
        dev_state = found_entry[state_key]
        errorflag = ""
        state_value = params.get(state_key)
        if state_value != None and dev_state != state_value:
            is_list = type(state_value) == "list"
            in_list = False
            if is_list:
                for v in state_value:
                    if dev_state == v:
                        in_list = True
                        break
            if not in_list:
                if dev_state in warn_states:
                    errorflag = "(!)"
                    if 1 > summarystate:
                        summarystate = 1
                else:
                    errorflag = "(!!)"
                    summarystate = 2
        state_str = state_map.get(dev_state, str(dev_state))
        output.append("%s: %s%s" % (state_info_name, state_str, errorflag))

    if bbcredits != None:
        bbcredit_rate = _get_rate(value_store, "bbcredit.%s" % item, this_time, bbcredits)
        metrics["fc_bbcredit_zero"] = bbcredit_rate

    state_str = "OK"
    if summarystate == 1:
        state_str = "WARN"
    elif summarystate == 2:
        state_str = "CRIT"
    elif summarystate == 3:
        state_str = "UNKNOWN"

    return {
        "state": state_str,
        "msg": ", ".join(output),
        "metrics": metrics,
        "details": "",
    }

def _format_discovery_item(index, portname, is_isl, num_ports, settings):
    width = len(str(num_ports))
    itemname = ("%0" + str(width) + "d") % (index - 1)
    if is_isl and settings.get("show_isl", True):
        itemname += " ISL"
    if portname and portname.strip() and settings.get("use_portname", True):
        itemname += " " + portname.strip()
    return itemname

def _probe_brocade(ctx, host, community):
    sys_oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", "-On", host, sys_oid],
        mutates=False,
    )
    if res.rc == 127:
        return None, "snmpget not available"
    if res.rc != 0 or not res.stdout:
        return None, "unable to query host via SNMP"
    sys_val = res.stdout.strip().strip('"')
    if not sys_val.startswith(".1.3.6.1.4.1.1588.2.1.1"):
        return None, "not a brocade device"
    return sys_val, None

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    sys_val, err = _probe_brocade(ctx, host, community)
    if err != None:
        if params.get("_discover"):
            return {"changed": False, "msg": err, "data": {"discovery": []}}
        return {"changed": False, "msg": err,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        section = _gather_snmp_data(ctx, community, host)
        if not section:
            return {"changed": False, "msg": "discovered 0 ports",
                    "data": {"discovery": []}}
        discovery = []
        num_ports = len(section)
        settings = DISCOVERY_DEFAULT_PARAMETERS
        for if_entry in section:
            admstate = if_entry.get("admstate", 0)
            phystate = if_entry.get("phystate", 0)
            opstate = if_entry.get("opstate", 0)
            if _brocade_fcport_inventory_this_port(admstate, phystate, opstate, settings):
                item = _format_discovery_item(
                    if_entry["index"],
                    if_entry.get("portname", ""),
                    if_entry.get("is_isl", False),
                    num_ports,
                    settings,
                )
                discovery.append({
                    "item": item,
                    "params": {
                        "phystate": [phystate],
                        "opstate": [opstate],
                        "admstate": [admstate],
                    },
                    "metrics": ["in", "out", "rxframes", "txframes", "rxcrcs",
                               "rxencoutframes", "rxencinframes", "c3discards",
                               "notxcredits", "fc_bbcredit_zero"],
                })
        return {"changed": False,
                "msg": "discovered %d ports" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = _gather_snmp_data(ctx, community, host)
    if not section:
        return {"changed": False, "msg": "no brocade fcport data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    combined_params = {}
    for k, v in params.items():
        combined_params[k] = v
    for k, v in CHECK_DEFAULT_PARAMETERS.items():
        if k not in combined_params:
            combined_params[k] = v

    this_time = 0
    value_store = {}

    result = _check_brocade_fcport(ctx, item, combined_params, section, this_time, value_store)
    if result == None:
        return {"changed": False, "msg": "item not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": result["msg"],
            "data": {"state": result["state"], "metrics": result["metrics"],
                     "details": result["details"]}}