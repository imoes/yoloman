# Brocade SFP check - translated from checkmk.brocade_sfp
# This check gathers SFP metrics (temperature, voltage, current, rx/tx power)
# from Brocade Fibre Channel switches via SNMP.

# SNMP OID bases from the original plugin
SFP_PORT_INFO_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1"
SFP_ISL_BASE    = ".1.3.6.1.4.1.1588.2.1.1.1.2.9.1"
SFP_VALUES_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.28.1.1"

# swFCPort table columns (from first SNMPTree)
COL_PORT_INDEX     = "1"
COL_PHY_STATE      = "3"
COL_OP_STATUS      = "4"
COL_ADM_STATUS     = "5"
COL_PORT_NAME      = "36"

# swNbMyPort column (from second SNMPTree - for ISL detection)
COL_ISL_PORT       = "2"

# swSfpStatEntry columns (from third SNMPTree)
COL_TEMP           = "1"
COL_VOLTAGE        = "2"
COL_CURRENT        = "3"
COL_RX_POWER       = "4"
COL_TX_POWER       = "5"

# Defaults from DISCOVERY_DEFAULT_PARAMETERS
DEFAULT_ADMSTATES = [1, 3, 4]
DEFAULT_PHYSTATES = [3, 4, 5, 6, 7, 8, 9, 10]
DEFAULT_OPSTATES  = [1, 2, 3, 4]


def _safe_int(s):
    """Convert string to int, returning 0 if not a valid integer."""
    if s == None:
        return 0
    stripped = s.lstrip("-")
    if not stripped.isdigit():
        return 0
    return int(s)


def _safe_float(s):
    """Convert string to float, returning 0.0 if not parseable."""
    if s == None:
        return 0.0
    parts = s.lstrip("-").split(".")
    if len(parts) > 2:
        return 0.0
    for p in parts:
        if p == "":
            continue
        if not p.isdigit():
            return 0.0
    return float(s)


def _fetch_sfp_data(ctx, host, community, version):
    """Fetch all SFP data from the three SNMP tables needed.
    Returns (port_infos, isl_list, raw_values) or (None, None, None) on failure.
    """
    # Table 1: swFCPortInfo (port index, phy state, op status, adm status, port name)
    res1 = ctx.run([
        "snmpwalk", "-" + version, "-c", community,
        "-Oqn", host, SFP_PORT_INFO_BASE,
    ], mutates=False)
    if res1.rc != 0 or not res1.stdout:
        return None, None, None

    port_infos = {}
    for line in res1.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        oid_full = parts[0]
        val = parts[1]
        remainder = oid_full[len(SFP_PORT_INFO_BASE) + 1:]
        dot_idx = remainder.find(".")
        if dot_idx < 0:
            continue
        col = remainder[:dot_idx]
        idx_str = remainder[dot_idx + 1:]
        idx = _safe_int(idx_str)
        if idx_str == "" or not (idx_str.isdigit() or (len(idx_str) > 0 and idx_str[0] == "-" and idx_str[1:].isdigit())):
            continue

        if idx not in port_infos:
            port_infos[idx] = {}
        if col == COL_PHY_STATE:
            port_infos[idx]["phystate"] = _safe_int(val)
        elif col == COL_OP_STATUS:
            port_infos[idx]["opstate"] = _safe_int(val)
        elif col == COL_ADM_STATUS:
            port_infos[idx]["admstate"] = _safe_int(val)
        elif col == COL_PORT_NAME:
            port_infos[idx]["portname"] = val

    for idx in list(port_infos.keys()):
        info = port_infos[idx]
        info.setdefault("phystate", 0)
        info.setdefault("opstate", 0)
        info.setdefault("admstate", 0)
        info.setdefault("portname", "")

    # Table 2: swNbMyPort (ISL ports)
    res2 = ctx.run([
        "snmpwalk", "-" + version, "-c", community,
        "-Oqn", host, SFP_ISL_BASE,
    ], mutates=False)
    isl_list = []
    if res2.rc == 0 and res2.stdout:
        for line in res2.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            isl_list.append(_safe_int(parts[1]))

    # Table 3: swSfpStatEntry (temp, voltage, current, rx_power, tx_power)
    res3 = ctx.run([
        "snmpwalk", "-" + version, "-c", community,
        "-Oqn", host, SFP_VALUES_BASE,
    ], mutates=False)
    raw_values = {}
    if res3.rc == 0 and res3.stdout:
        for line in res3.stdout.splitlines():
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            oid_full = parts[0]
            val = parts[1]
            remainder = oid_full[len(SFP_VALUES_BASE) + 1:]
            dot_idx = remainder.find(".")
            if dot_idx < 0:
                continue
            col = remainder[:dot_idx]
            idx_str = remainder[dot_idx + 1:]
            idx = _safe_int(idx_str)
            if idx_str == "" or not (idx_str.isdigit() or (len(idx_str) > 0 and idx_str[0] == "-" and idx_str[1:].isdigit())):
                continue
            if idx not in raw_values:
                raw_values[idx] = {}
            if col == COL_TEMP:
                raw_values[idx]["temp"] = _safe_int(val) if val != "NA" else None
            elif col == COL_VOLTAGE:
                raw_values[idx]["voltage"] = _safe_float(val) / 1000.0 if val != "NA" else None
            elif col == COL_CURRENT:
                raw_values[idx]["current"] = _safe_float(val) / 1000.0 if val != "NA" else None
            elif col == COL_RX_POWER:
                raw_values[idx]["rx_power"] = _safe_float(val) if val != "NA" else None
            elif col == COL_TX_POWER:
                raw_values[idx]["tx_power"] = _safe_float(val) if val != "NA" else None

    return port_infos, isl_list, raw_values


def _build_section(port_infos, isl_list, raw_values):
    """Build the parsed section: dict of port_index -> {info, values}."""
    section = {}
    for idx in port_infos:
        info = port_infos[idx]
        vals = raw_values.get(idx)
        if vals == None:
            continue
        # Skip if temp is NA (values[0] != "NA" filter in original)
        if vals.get("temp") == None:
            continue
        section[idx] = {
            "info": {
                "index": idx,
                "port_name": info.get("portname", ""),
                "phystate": info.get("phystate", 0),
                "opstate": info.get("opstate", 0),
                "admstate": info.get("admstate", 0),
                "is_isl": idx in isl_list,
            },
            "values": {
                "temp": vals.get("temp", 0),
                "voltage": vals.get("voltage", 0.0),
                "current": vals.get("current", 0.0),
                "rx_power": vals.get("rx_power", 0.0),
                "tx_power": vals.get("tx_power", 0.0),
            },
        }
    return section


def _port_should_be_inventoried(info, settings):
    """Reproduce brocade_fcport_inventory_this_port."""
    if info["admstate"] not in settings.get("admstates", DEFAULT_ADMSTATES):
        return False
    if info["phystate"] not in settings.get("phystates", DEFAULT_PHYSTATES):
        return False
    return info["opstate"] in settings.get("opstates", DEFAULT_OPSTATES)


def _get_item_name(number_of_ports, index, portname, is_isl, settings):
    """Reproduce brocade_fcport_getitem."""
    n_digits = len(str(number_of_ports))
    itemname = ("%0" + str(n_digits) + "d") % (index - 1)
    if is_isl and settings.get("show_isl", True):
        itemname += " ISL"
    if portname.strip() and settings.get("use_portname", True):
        itemname += " " + portname.strip()
    return itemname


def _grade_with_levels(value, levels_lower, levels_upper):
    """Grade a value against lower and upper warning/critical thresholds.
    levels_lower = (warn_lower, crit_lower) -- for lower-is-worse
    levels_upper = (warn_upper, crit_upper) -- for upper-is-worse
    Returns (state, msg).
    """
    state = "OK"
    msg_parts = []
    if levels_lower != None:
        warn_lower, crit_lower = levels_lower
        if value <= crit_lower:
            state = "CRIT"
            msg_parts.append("(crit below %f)" % crit_lower)
        elif value <= warn_lower:
            if state == "OK":
                state = "WARN"
            msg_parts.append("(warn below %f)" % warn_lower)
    if levels_upper != None:
        warn_upper, crit_upper = levels_upper
        if value >= crit_upper:
            state = "CRIT"
            msg_parts.append("(crit above %f)" % crit_upper)
        elif value >= warn_upper:
            if state == "OK":
                state = "WARN"
            msg_parts.append("(warn above %f)" % warn_upper)
    return state, " ".join(msg_parts)


def _parse_level_pair(levels_param):
    """Parse levels from params.
    For rx/tx/current/voltage: params get (crit_lower, warn_lower, warn_upper, crit_upper)
    We return levels_lower=(warn_lower, crit_lower) and levels_upper=(warn_upper, crit_upper)
    """
    if levels_param == None:
        return None, None
    if type(levels_param) == "list" and len(levels_param) == 4:
        crit_lower = levels_param[0]
        warn_lower = levels_param[1]
        warn_upper = levels_param[2]
        crit_upper = levels_param[3]
        return (warn_lower, crit_lower), (warn_upper, crit_upper)
    return None, None


def _grade_temperature(temp_val, warn, crit):
    """Simple upper-level temperature grading (standard Checkmk behavior)."""
    state = "OK"
    if crit != None and temp_val >= crit:
        state = "CRIT"
    elif warn != None and temp_val >= warn:
        state = "WARN"
    return state


def main(ctx, params):
    is_discover = params.get("_discover", False)

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "v2c")
    item = params.get("item", "")

    # Probe for SNMP availability first
    probe = ctx.run([
        "snmpwalk", "-" + version, "-c", community,
        "-Oqn", host, SFP_PORT_INFO_BASE,
    ], mutates=False)
    if probe.rc == 127:
        # snmpwalk not installed
        if is_discover:
            return {"changed": False, "msg": "snmpwalk not installed",
                    "data": {"discovery": [], "host_labels": {}}}
        return {"changed": False, "msg": "snmpwalk not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "snmpwalk not installed"}}
    if probe.rc != 0:
        if is_discover:
            return {"changed": False, "msg": "no Brocade SFP data (SNMP unavailable)",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Brocade SFP data (SNMP unavailable)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed: " + (probe.stderr or "")}}

    # Fetch all data
    port_infos, isl_list, raw_values = _fetch_sfp_data(ctx, host, community, version)
    if port_infos == None:
        if is_discover:
            return {"changed": False, "msg": "no Brocade SFP data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "no Brocade SFP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP tables empty"}}

    section = _build_section(port_infos, isl_list, raw_values)

    if is_discover:
        number_of_ports = len(section)
        settings = {
            "admstates": DEFAULT_ADMSTATES,
            "phystates": DEFAULT_PHYSTATES,
            "opstates": DEFAULT_OPSTATES,
            "use_portname": True,
            "show_isl": True,
        }
        entries = []
        for port_index in sorted(section.keys()):
            port = section[port_index]
            info = port["info"]
            if not _port_should_be_inventoried(info, settings):
                continue
            item_name = _get_item_name(
                number_of_ports, port_index,
                info["port_name"], info["is_isl"], settings,
            )
            entries.append({"item": item_name, "params": {}, "metrics": []})
        return {"changed": False,
                "msg": "discovered %d SFP ports" % len(entries),
                "data": {"discovery": entries}}

    # Check mode
    # Parse the port index from the item
    first_part = item.split(maxsplit=1)[0] if item else ""
    display_idx = _safe_int(first_part) if first_part != "" else 0
    if first_part == "":
        return {"changed": False, "msg": "cannot parse item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "invalid item"}}

    port_index = display_idx + 1  # Convert display index back to SNMP index

    port = section.get(port_index)
    if port == None:
        return {"changed": False, "msg": "no SFP data for port " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "port not found in section"}}

    values = port["values"]

    # Gather threshold params
    temp_levels = params.get("temperature_levels")
    temp_warn = temp_levels.get("warn") if temp_levels != None else None
    temp_crit = temp_levels.get("crit") if temp_levels != None else None

    rx_levels = params.get("rx_power_levels")
    tx_levels = params.get("tx_power_levels")
    current_levels = params.get("current_levels")
    voltage_levels = params.get("voltage_levels")

    rx_lower, rx_upper = _parse_level_pair(rx_levels)
    tx_lower, tx_upper = _parse_level_pair(tx_levels)
    cur_lower, cur_upper = _parse_level_pair(current_levels)
    volt_lower, volt_upper = _parse_level_pair(voltage_levels)

    # Grade temperature (upper levels)
    temp_val = values["temp"]
    temp_state = _grade_temperature(temp_val, temp_warn, temp_crit)

    # Grade rx power
    rx_state, rx_msg = _grade_with_levels(values["rx_power"], rx_lower, rx_upper)
    # Grade tx power
    tx_state, tx_msg = _grade_with_levels(values["tx_power"], tx_lower, tx_upper)
    # Grade current
    cur_state, cur_msg = _grade_with_levels(values["current"], cur_lower, cur_upper)
    # Grade voltage
    volt_state, volt_msg = _grade_with_levels(values["voltage"], volt_lower, volt_upper)

    # Overall state: worst of all
    state_priority = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    states = [temp_state, rx_state, tx_state, cur_state, volt_state]
    overall_state = "OK"
    for s in states:
        if state_priority.get(s, 0) > state_priority.get(overall_state, 0):
            overall_state = s

    # Build metrics
    metrics = {
        "temperature": temp_val,
        "input_signal_power_dbm": values["rx_power"],
        "output_signal_power_dbm": values["tx_power"],
        "current": values["current"],
        "voltage": values["voltage"],
    }

    # Build details
    parts = []
    parts.append("Temp: %d C" % temp_val)
    parts.append("Rx: %f dBm%s" % (values["rx_power"], (" " + rx_msg) if rx_msg else ""))
    parts.append("Tx: %f dBm%s" % (values["tx_power"], (" " + tx_msg) if tx_msg else ""))
    parts.append("Current: %f A%s" % (values["current"], (" " + cur_msg) if cur_msg else ""))
    parts.append("Voltage: %f V%s" % (values["voltage"], (" " + volt_msg) if volt_msg else ""))
    details = ", ".join(parts)

    msg = "%s: %s" % (item, details)

    return {"changed": False, "msg": msg,
            "data": {"state": overall_state, "metrics": metrics, "details": details}}