def main(ctx, params):
    # ===== Constants (SNMP OIDs) =====
    SNMP_BASE_PHY = ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1"
    SNMP_BASE_ISL = ".1.3.6.1.4.1.1588.2.1.1.1.2.9.1"
    SNMP_BASE_SFP = ".1.3.6.1.4.1.1588.2.1.1.1.28.1.1"

    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Fetch port info: index, phystate, opstate, admstate, port_name
        res_info = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            SNMP_BASE_PHY
        ], mutates=False)
        if res_info.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP info walk failed: " + res_info.stderr,
                "data": {"discovery": []}
            }

        # Fetch ISL list: swNbMyPort
        res_isl = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            SNMP_BASE_ISL
        ], mutates=False)
        if res_isl.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP isl walk failed: " + res_isl.stderr,
                "data": {"discovery": []}
            }

        # Fetch SFP metrics: temp, voltage, current, rx_power, tx_power, portIndex
        res_sfp = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            SNMP_BASE_SFP
        ], mutates=False)
        if res_sfp.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP sfp walk failed: " + res_sfp.stderr,
                "data": {"discovery": []}
            }

        # Parse port info
        isl_ports = {}
        for line in res_isl.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split()
            if len(parts) < 3:
                continue
            # Format: .1.3.6.1.4.1.1588.2.1.1.1.2.9.1.2.1 = INTEGER: 1
            oid_parts = parts[0].split(".")
            if len(oid_parts) < 13:
                continue
            port_idx_str = oid_parts[-1]
            if port_idx_str.isdigit():
                port_idx = int(port_idx_str)
                value = parts[2]
                if value.isdigit():
                    isl_ports[port_idx] = True

        # Parse port info table: index, phystate, opstate, admstate, port_name
        port_infos = {}
        for line in res_info.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split()
            if len(parts) < 3:
                continue
            # Format: .1.3.6.1.4.1.1588.2.1.1.1.6.2.1.X.Y = TYPE: value
            oid_parts = stripped.split()[0].split(".")
            if len(oid_parts) < 14:
                continue
            port_index_str = oid_parts[-1]
            if not port_index_str.isdigit():
                continue
            port_index = int(port_index_str)
            if port_index not in port_infos:
                port_infos[port_index] = {
                    "index": port_index,
                    "phystate": None,
                    "opstate": None,
                    "admstate": None,
                    "port_name": "",
                }
            oid_num_str = oid_parts[-2]
            if not oid_num_str.isdigit():
                continue
            oid_num = int(oid_num_str)
            value = parts[2]
            if oid_num == 1:
                port_infos[port_index]["phystate"] = int(value)
            elif oid_num == 2:
                port_infos[port_index]["opstate"] = int(value)
            elif oid_num == 3:
                port_infos[port_index]["admstate"] = int(value)
            elif oid_num == 35:  # 36th OID = index 35 (0-based)
                port_infos[port_index]["port_name"] = value.strip('"')

        # Parse SFP metrics table: temp, voltage, current, rx_power, tx_power, portIndex
        sfp_metrics = {}
        for line in res_sfp.stdout.splitlines():
            stripped = line.strip()
            if stripped == "":
                continue
            parts = stripped.split()
            if len(parts) < 3:
                continue
            oid_parts = stripped.split()[0].split(".")
            if len(oid_parts) < 14:
                continue
            port_index_str = oid_parts[-1]
            if not port_index_str.isdigit():
                continue
            port_index = int(port_index_str)
            if port_index not in sfp_metrics:
                sfp_metrics[port_index] = {
                    "index": port_index,
                    "temp": None,
                    "voltage": None,
                    "current": None,
                    "rx_power": None,
                    "tx_power": None,
                }
            oid_num_str = oid_parts[-2]
            if not oid_num_str.isdigit():
                continue
            oid_num = int(oid_num_str)
            value = parts[2]
            if oid_num == 0 and value != "NA":
                sfp_metrics[port_index]["temp"] = int(value)
            elif oid_num == 1 and value != "NA":
                sfp_metrics[port_index]["voltage"] = float(value) / 1000.0
            elif oid_num == 2 and value != "NA":
                sfp_metrics[port_index]["current"] = float(value) / 1000.0
            elif oid_num == 3 and value != "NA":
                sfp_metrics[port_index]["rx_power"] = float(value)
            elif oid_num == 4 and value != "NA":
                sfp_metrics[port_index]["tx_power"] = float(value)

        # Filter and build discovery list
        settings = {
            "admstates": [1, 3, 4],
            "phystates": [3, 4, 5, 6, 7, 8, 9, 10],
            "opstates": [1, 2, 3, 4],
            "use_portname": True,
            "show_isl": True,
        }

        discovered = []
        for port_index, info in port_infos.items():
            # Skip if no SFP data available for this port
            if sfp_metrics.get(port_index) == None or sfp_metrics[port_index].get("temp") == None:
                continue

            # Check port inventory conditions
            adm = info.get("admstate")
            phy = info.get("phystate")
            op = info.get("opstate")
            if adm == None or adm not in settings["admstates"]:
                continue
            if phy == None or phy not in settings["phystates"]:
                continue
            if op == None or op not in settings["opstates"]:
                continue

            # Build item name (same logic as brocade_fcport_getitem)
            number_of_ports = len(port_infos)
            if number_of_ports == 0:
                number_of_ports = 1
            itemname = ("%0" + str(len(str(number_of_ports))) + "d") % (port_index - 1)

            is_isl = (port_index in isl_ports)
            if is_isl and settings["show_isl"]:
                itemname += " ISL"

            portname = info.get("port_name", "").strip()
            if portname and settings["use_portname"]:
                itemname += " " + portname

            # Default parameters per Checkmk plugin
            default_params = {
                "levels": (30.0, 35.0, 35.0, 40.0),
                "rx_power": (-10.0, -5.0, -25.0, -20.0),
                "tx_power": (-10.0, -5.0, -25.0, -20.0),
                "current": (0.0, 0.0, 0.2, 0.25),
                "voltage": (3.0, 3.2, 3.3, 3.6),
            }

            discovered.append({
                "item": itemname,
                "params": default_params,
                "metrics": ["temp", "rx_power", "tx_power", "current", "voltage"]
            })

        return {
            "changed": False,
            "msg": "discovered %d SFP ports" % len(discovered),
            "data": {"discovery": discovered}
        }

    # Check mode (normal path)
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "missing item parameter",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract port index from item name (e.g., "00", "01 ISL", "02 port_name")
    parts = item.split()
    if len(parts) < 1 or not parts[0].isdigit():
        return {
            "changed": False,
            "msg": "invalid item format: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    port_index = int(parts[0]) + 1

    # Gather data via SNMP
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch SFP data for specific port index
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        SNMP_BASE_SFP + "." + str(1) + "." + str(port_index),  # temp
        SNMP_BASE_SFP + "." + str(2) + "." + str(port_index),  # voltage
        SNMP_BASE_SFP + "." + str(3) + "." + str(port_index),  # current
        SNMP_BASE_SFP + "." + str(4) + "." + str(port_index),  # rx_power
        SNMP_BASE_SFP + "." + str(5) + "." + str(port_index),  # tx_power
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output
    values = {
        "temp": None,
        "voltage": None,
        "current": None,
        "rx_power": None,
        "tx_power": None,
    }
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped == "":
            continue
        parts = stripped.split()
        if len(parts) < 3:
            continue
        # Format: OID = TYPE: value
        oid_parts = stripped.split()[0].split(".")
        if len(oid_parts) < 15:
            continue
        oid_num_str = oid_parts[-2]
        if not oid_num_str.isdigit():
            continue
        oid_num = int(oid_num_str)
        value = parts[2]
        if value == "NA":
            continue
        if oid_num == 0:
            values["temp"] = int(value)
        elif oid_num == 1:
            values["voltage"] = float(value) / 1000.0
        elif oid_num == 2:
            values["current"] = float(value) / 1000.0
        elif oid_num == 3:
            values["rx_power"] = float(value)
        elif oid_num == 4:
            values["tx_power"] = float(value)

    # If no valid data found
    if values["temp"] == None:
        return {
            "changed": False,
            "msg": "no data for port " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds (Checkmk style: levels = (warn_lower, crit_lower, warn_upper, crit_upper))
    levels = params.get("levels", (30.0, 35.0, 35.0, 40.0))
    warn_lower_temp = levels[0]
    crit_lower_temp = levels[1]
    warn_upper_temp = levels[2]
    crit_upper_temp = levels[3]
    temp = values["temp"]

    # Temperature verdict
    state = "OK"
    if temp <= crit_lower_temp:
        state = "CRIT"
    elif temp <= warn_lower_temp:
        state = "WARN"
    elif temp >= crit_upper_temp:
        state = "CRIT"
    elif temp >= warn_upper_temp:
        state = "WARN"

    # Metrics
    metrics = {
        "temp": temp,
    }

    # Power levels (rx_power, tx_power)
    rx_levels = params.get("rx_power", (-10.0, -5.0, -25.0, -20.0))
    tx_levels = params.get("tx_power", (-10.0, -5.0, -25.0, -20.0))
    current_levels = params.get("current", (0.0, 0.0, 0.2, 0.25))
    voltage_levels = params.get("voltage", (3.0, 3.2, 3.3, 3.6))

    def check_levels(value, levels):
        if value == None:
            return "UNKNOWN", {}
        warn_lower, crit_lower, warn_upper, crit_upper = levels
        st = "OK"
        m = {}
        if value <= crit_lower:
            st = "CRIT"
        elif value <= warn_lower:
            st = "WARN"
        elif value >= crit_upper:
            st = "CRIT"
        elif value >= warn_upper:
            st = "WARN"
        return st, m

    # Check each metric and update overall state if needed
    rx_st, _ = check_levels(values["rx_power"], rx_levels)
    tx_st, _ = check_levels(values["tx_power"], tx_levels)
    curr_st, _ = check_levels(values["current"], current_levels)
    volt_st, _ = check_levels(values["voltage"], voltage_levels)

    # Aggregate worst state
    for st in [rx_st, tx_st, curr_st, volt_st]:
        if st == "CRIT":
            state = "CRIT"
            break
        elif st == "WARN" and state != "CRIT":
            state = "WARN"

    # Build metrics dict
    if values["rx_power"] != None:
        metrics["input_signal_power_dbm"] = values["rx_power"]
    if values["tx_power"] != None:
        metrics["output_signal_power_dbm"] = values["tx_power"]
    if values["current"] != None:
        metrics["current"] = values["current"]
    if values["voltage"] != None:
        metrics["voltage"] = values["voltage"]

    # Details message
    details_parts = []
    if values["temp"] != None:
        details_parts.append("Temperature: %f C" % values["temp"])
    if values["rx_power"] != None:
        details_parts.append("Rx: %f dBm" % values["rx_power"])
    if values["tx_power"] != None:
        details_parts.append("Tx: %f dBm" % values["tx_power"])
    if values["current"] != None:
        details_parts.append("Current: %f A" % values["current"])
    if values["voltage"] != None:
        details_parts.append("Voltage: %f V" % values["voltage"])

    details_str = ", ".join(details_parts)
    msg = item + ": " + details_str

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
