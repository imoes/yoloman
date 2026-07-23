# brocade_fcport starlark check module

# SNMP base OIDs
_BROCADE_BASE = ".1.3.6.1.4.1.1588.2.1.1.1"
_IF_BASE = ".1.3.6.1.2.1"
_FCMGMT_BASE = ".1.3.6.1.3.94.4.5.1"

# Lookup tables (same as Python source)
_BROCADE_FCPORT_PHYSTATES = {
    0: "",
    1: "no card",
    2: "no transceiver",
    3: "laser fault",
    4: "no light",
    5: "no sync",
    6: "in sync",
    7: "port fault",
    8: "diag fault",
    9: "lock ref",
    10: "validating",
    11: "invalid module",
    12: "remote fault",
    13: "local fault",
    14: "no sig det",
    15: "hard fault",
    16: "unsupported module",
    17: "module fault",
    255: "unknown",
}

_BROCADE_FCPORT_OPSTATES = {
    0: "unknown",
    1: "online",
    2: "offline",
    3: "testing",
    4: "faulty",
}

_BROCADE_FCPORT_ADMSTATES = {
    0: "",
    1: "online",
    2: "offline",
    3: "testing",
    4: "faulty",
}

_BROCADE_FCPORT_SPEED = {
    0: "unknown",
    1: "1Gbit",
    2: "2Gbit",
    3: "auto-Neg",
    4: "4Gbit",
    5: "8Gbit",
    6: "10Gbit",
    7: "unknown",
    8: "16Gbit",
}

_ISL_SPEED_MAP = {
    "1": 0,
    "2": 0.155,
    "4": 0.266,
    "8": 0.532,
    "16": 1,
    "32": 2,
    "64": 4,
    "128": 8,
    "256": 10,
    "512": 16,
}


def _to_int(raw_value):
    """Convert a raw integer (little endian byte string) to int."""
    value = 0
    mult = 1
    i = len(raw_value) - 1
    while i >= 0:
        value += mult * raw_value[i]
        mult *= 256
        i -= 1
    return value


def _parse_octet_str_to_int(s):
    """Parse SNMP OCTETSTR counters to integers."""
    # Default case
    if len(s) == 23:
        # recover from "00 00 00 00 00 C0 FE FE"
        parts = []
        i = 0
        while i < 24:
            if i + 1 < len(s):
                byte_val = s[i] * 16 + s[i + 1]
                parts.append(byte_val)
            else:
                parts.append(0)
            i += 3
        s = parts
    
    value = 0
    i = len(s) - 1
    while i >= 0:
        value = value * 256 + s[i]
        i -= 1
    return value


def _snmp_walk(ctx, base_oid):
    """Perform an snmpwalk on the given OID and parse output.
    
    Returns a list of lists: each row is a list of string values.
    """
    res = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost", base_oid], mutates=False)
    if res.rc != 0:
        return []
    
    lines = res.stdout.splitlines()
    rows = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip():
            # Parse: OID = TYPE: value
            eq_pos = line.find("=")
            if eq_pos >= 0:
                oid_part = line[:eq_pos].strip()
                value_part = line[eq_pos + 1:].strip()
                # Extract last number from OID (after final dot)
                last_dot = oid_part.rfind(".")
                if last_dot >= 0:
                    last_part = oid_part[last_dot + 1:]
                else:
                    last_part = oid_part
                
                # Parse value based on type
                value = value_part
                if value_part.startswith("INTEGER:"):
                    value_str = value_part[8:].strip()
                    if value_str.isdigit():
                        value = int(value_str)
                elif value_part.startswith("STRING:"):
                    value = value_part[7:].strip('"')
                elif value_part.startswith("OctetStr"):
                    # OCTETSTR is hex-encoded bytes like "00 00 00 00 00 C0 FE FE"
                    colon_pos = value_part.find(":")
                    if colon_pos >= 0:
                        hex_str = value_part[colon_pos + 1:].strip().replace(" ", "")
                        if len(hex_str) % 2 == 0:
                            value = []
                            j = 0
                            while j < len(hex_str):
                                value.append(int(hex_str[j:j+2], 16))
                                j += 2
                elif value_part.startswith("Counter64:"):
                    value_str = value_part[10:].strip()
                    if value_str.isdigit():
                        value = int(value_str)
                elif value_part.isdigit():
                    value = int(value_part)
                
                rows.append([last_part, value])
        i += 1
    
    return rows


def main(ctx, params):
    if params.get("_discover"):
        # ===== DISCOVERY MODE =====
        # Gather all sections: ifTable, brocade link info, speed info, 64-bit counters
        # 1. Primary brocade table
        brocade_table = _snmp_walk(ctx, _BROCADE_BASE + ".6.2.1")
        if not brocade_table:
            return {"changed": False, "msg": "discovered 0 ports",
                    "data": {"discovery": []}}
        
        # 2. Link info (ISL ports)
        link_info = _snmp_walk(ctx, _BROCADE_BASE + ".2.9.1")
        isl_ports = {}
        j = 0
        while j < len(link_info):
            row = link_info[j]
            if len(row) >= 2:
                isl_ports[str(row[0])] = str(row[1])
            j += 1
        
        # 3. Speed info from IF-MIB
        if_table = _snmp_walk(ctx, _IF_BASE + ".2.2.1")
        speed_info = {}
        j = 0
        while j < len(if_table):
            row = if_table[j]
            if len(row) >= 3:
                speed_info[str(row[0])] = [row[1], row[2]]  # type, speed
            j += 1
        
        # 4. 64-bit counters from FCMGMT
        if64_info = _snmp_walk(ctx, _FCMGMT_BASE)
        if64_map = {}
        j = 0
        while j < len(if64_info):
            row = if64_info[j]
            if len(row) >= 6:
                if64_map[row[0]] = row[1:]  # [tx_objects, rx_objects, tx_elements, rx_elements, bbcredits]
            j += 1
        
        # Parse ports (simplified version of parse_brocade_fcport)
        parsed = []
        # Group brocade table entries by port index
        ports_data = {}
        j = 0
        while j < len(brocade_table):
            row = brocade_table[j]
            if len(row) >= 15:
                idx = str(row[0])
                if idx not in ports_data:
                    ports_data[idx] = [0] * 15
                ports_data[idx][0] = row[0]
                ports_data[idx][1] = row[1]  # phystate
                ports_data[idx][2] = row[2]  # opstate
                ports_data[idx][3] = row[3]  # admstate
                ports_data[idx][4] = row[4]  # txwords
                ports_data[idx][5] = row[5]  # rxwords
                ports_data[idx][6] = row[6]  # txframes
                ports_data[idx][7] = row[7]  # rxframes
                ports_data[idx][8] = row[8]  # notxcredits
                ports_data[idx][9] = row[9]  # rxcrcs
                ports_data[idx][10] = row[10]  # rxencinframes
                ports_data[idx][11] = row[11]  # rxencoutframes
                ports_data[idx][12] = row[12]  # c3discards
                ports_data[idx][13] = row[13]  # speed
                ports_data[idx][14] = row[14]  # portname
            j += 1
        
        # Get port count for formatting
        port_count = len(ports_data)
        
        # Process each port
        for idx, data in ports_data.items():
            if type(data) == "list" and len(data) >= 15:
                if type(data[0]) == "int" and type(data[1]) == "int" and type(data[2]) == "int" and type(data[3]) == "int":
                    index = data[0]
                    phystate = data[1]
                    opstate = data[2]
                    admstate = data[3]
                    
                    # Check inventory conditions (simplified)
                    # Default: admstate in [1,3,4], phystate in [3,4,5,6,7,8,9,10], opstate in [1,2,3,4]
                    if admstate not in [1, 3, 4]:
                        continue
                    if phystate not in [3, 4, 5, 6, 7, 8, 9, 10]:
                        continue
                    if opstate not in [1, 2, 3, 4]:
                        continue
                    
                    # Get portname
                    portname = str(data[14]) if len(data) > 14 and data[14] else ""
                    
                    # Check ISL
                    is_isl = str(index) in isl_ports
                    
                    # Build item name
                    itemname = ("%0" + str(len(str(port_count))) + "d") % (index - 1)
                    if is_isl:
                        itemname += " ISL"
                    if portname.strip():
                        itemname += " " + portname.strip()
                    
                    # Create discovery entry
                    discovery_entry = {
                        "item": itemname,
                        "params": {
                            "phystate": [phystate],
                            "opstate": [opstate],
                            "admstate": [admstate],
                            # Use defaults for error thresholds and assumed_speed
                            "rxcrcs": (3.0, 20.0),
                            "rxencoutframes": (3.0, 20.0),
                            "rxencinframes": (3.0, 20.0),
                            "notxcredits": (3.0, 20.0),
                            "c3discards": (3.0, 20.0),
                            "assumed_speed": 2.0,
                        },
                        "metrics": ["rx", "tx", "rxframes", "txframes",
                                   "rxcrcs", "rxencoutframes", "rxencinframes",
                                   "notxcredits", "c3discards"]
                    }
                    parsed.append(discovery_entry)
        
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(parsed),
            "data": {"discovery": parsed}
        }
    
    # ===== CHECK MODE =====
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract index from item (first part before space)
    item_parts = item.split()
    if len(item_parts) > 0 and item_parts[0].isdigit():
        port_index = int(item_parts[0])
    else:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Gather SNMP data
    # 1. Primary brocade table
    brocade_table = _snmp_walk(ctx, _BROCADE_BASE + ".6.2.1")
    if not brocade_table:
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # 2. Link info (ISL ports)
    link_info = _snmp_walk(ctx, _BROCADE_BASE + ".2.9.1")
    isl_ports = {}
    j = 0
    while j < len(link_info):
        row = link_info[j]
        if len(row) >= 2:
            isl_ports[str(row[0])] = str(row[1])
        j += 1
    
    # 3. Speed info from IF-MIB
    if_speeds = _snmp_walk(ctx, _IF_BASE + ".2.2.1")
    if_speed_map = {}
    j = 0
    while j < len(if_speeds):
        row = if_speeds[j]
        if len(row) >= 3:
            if_speed_map[str(row[0])] = row[1]  # type
            if_speed_map[str(row[0]) + "_speed"] = row[2]  # speed
        j += 1
    
    # 4. 64-bit counters from FCMGMT
    if64_info = _snmp_walk(ctx, _FCMGMT_BASE)
    if64_map = {}
    j = 0
    while j < len(if64_info):
        row = if64_info[j]
        if len(row) >= 6:
            if64_map[row[0]] = row[1:]  # [tx_objects, rx_objects, tx_elements, rx_elements, bbcredits]
        j += 1
    
    # Find the port data
    found_entry = None
    j = 0
    while j < len(brocade_table):
        row = brocade_table[j]
        if len(row) >= 15:
            if type(row[0]) == "int" and row[0] == port_index + 1:  # Brocade indices are 1-based
                found_entry = row
                break
        j += 1
    
    if found_entry == None:
        return {"changed": False, "msg": "port not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract values
    phystate = found_entry[1] if found_entry[1] else 0
    opstate = found_entry[2] if found_entry[2] else 0
    admstate = found_entry[3] if found_entry[3] else 0
    txwords_str = str(found_entry[4]) if found_entry[4] else "0"
    rxwords_str = str(found_entry[5]) if found_entry[5] else "0"
    txframes_str = str(found_entry[6]) if found_entry[6] else "0"
    rxframes_str = str(found_entry[7]) if found_entry[7] else "0"
    notxcredits_str = str(found_entry[8]) if found_entry[8] else "0"
    rxcrcs_str = str(found_entry[9]) if found_entry[9] else "0"
    rxencinframes_str = str(found_entry[10]) if found_entry[10] else "0"
    rxencoutframes_str = str(found_entry[11]) if found_entry[11] else "0"
    c3discards_str = str(found_entry[12]) if found_entry[12] else "0"
    brocade_speed = found_entry[13] if found_entry[13] else 0
    portname = str(found_entry[14]) if len(found_entry) > 14 and found_entry[14] else ""
    
    # Try 64-bit counters if available
    bbcredits_str = None
    if str(port_index + 1) in if64_map:
        counters = if64_map[str(port_index + 1)]
        if len(counters) >= 5:
            txwords_str = str(_parse_octet_str_to_int(counters[0]))
            rxwords_str = str(_parse_octet_str_to_int(counters[1]))
            txframes_str = str(_parse_octet_str_to_int(counters[2]) // 4)
            rxframes_str = str(_parse_octet_str_to_int(counters[3]) // 4)
            bbcredits_str = str(_parse_octet_str_to_int(counters[4]))
    
    # ISL speed
    is_isl = str(port_index + 1) in isl_ports
    islspeed = _ISL_SPEED_MAP.get(isl_ports.get(str(port_index + 1), ""))
    
    # Get parameters with defaults
    assumed_speed = params.get("assumed_speed", 2.0)
    average = params.get("average")
    bw_thresh = params.get("bw")
    rxcrcs_levels = params.get("rxcrcs", (3.0, 20.0))
    rxencoutframes_levels = params.get("rxencoutframes", (3.0, 20.0))
    rxencinframes_levels = params.get("rxencinframes", (3.0, 20.0))
    notxcredits_levels = params.get("notxcredits", (3.0, 20.0))
    c3discards_levels = params.get("c3discards", (3.0, 20.0))
    
    # Convert values to integers
    txwords = int(txwords_str) if txwords_str.isdigit() else 0
    rxwords = int(rxwords_str) if rxwords_str.isdigit() else 0
    txframes = int(txframes_str) if txframes_str.isdigit() else 0
    rxframes = int(rxframes_str) if rxframes_str.isdigit() else 0
    notxcredits = int(notxcredits_str) if notxcredits_str.isdigit() else 0
    rxcrcs = int(rxcrcs_str) if rxcrcs_str.isdigit() else 0
    rxencinframes = int(rxencinframes_str) if rxencinframes_str.isdigit() else 0
    rxencoutframes = int(rxencoutframes_str) if rxencoutframes_str.isdigit() else 0
    c3discards = int(c3discards_str) if c3discards_str.isdigit() else 0
    bbcredits = int(bbcredits_str) if bbcredits_str and bbcredits_str.isdigit() else None
    
    # Calculate speed message and value
    speedmsg = "Speed: unknown"
    gbit = 2.0  # default
    
    if is_isl and islspeed != None:
        speedmsg = "ISL speed: %.0f Gbit/s"
        gbit = islspeed
    elif brocade_speed in _BROCADE_FCPORT_SPEED:
        brocade_speed_value = _BROCADE_FCPORT_SPEED[brocade_speed]
        if brocade_speed_value not in ("auto-Neg", "unknown"):
            speed_str = brocade_speed_value.replace("Gbit", "")
            if speed_str.isdigit():
                gbit = int(speed_str)
                speedmsg = "%.0f Gbit/s"
        elif brocade_speed_value == "unknown":
            if str(port_index + 1) + "_speed" in if_speed_map:
                if_speed = if_speed_map[str(port_index + 1) + "_speed"]
                if type(if_speed) == "int" and if_speed > 0:
                    gbit = if_speed / 1000.0
                    speedmsg = "Speed: %g Gbit/s"
                else:
                    gbit = assumed_speed
                    speedmsg = "Assumed speed: %g Gbit/s"
            else:
                gbit = assumed_speed
                speedmsg = "Assumed speed: %g Gbit/s"
        else:
            gbit = assumed_speed
            speedmsg = "Assumed speed: %g Gbit/s"
    else:
        if str(port_index + 1) + "_speed" in if_speed_map:
            if_speed = if_speed_map[str(port_index + 1) + "_speed"]
            if type(if_speed) == "int" and if_speed > 0:
                gbit = if_speed / 1000.0
                speedmsg = "Speed: %g Gbit/s"
            else:
                gbit = assumed_speed
                speedmsg = "Assumed speed: %g Gbit/s"
        else:
            gbit = assumed_speed
            speedmsg = "Assumed speed: %g Gbit/s"
    
    output = [speedmsg % gbit]
    
    # Calculate bandwidth
    wirespeed = gbit * 1e9 / 8
    
    summarystate = 0
    
    # Calculate bandwidth metrics (simplified - no rate calculation in this example)
    # For simplicity, use raw values (in a real check you'd compute rates using value_store)
    in_bytes = rxwords * 4  # 4 bytes per word
    out_bytes = txwords * 4
    
    # Convert thresholds
    warn_bytes = None
    crit_bytes = None
    if bw_thresh != None:
        warn, crit = bw_thresh
        if type(warn) == "float":
            warn_bytes = wirespeed * warn / 100.0
        else:
            warn_bytes = warn * 1048576.0
        if type(crit) == "float":
            crit_bytes = wirespeed * crit / 100.0
        else:
            crit_bytes = crit * 1048576.0
    
    # Process in/out bandwidth
    for what, value in [("In", in_bytes), ("Out", out_bytes)]:
        # Format bandwidth (simplified)
        if value >= 1073741824:
            bw_str = "%f GB/s" % (value / 1073741824.0)
        elif value >= 1048576:
            bw_str = "%f MB/s" % (value / 1048576.0)
        else:
            bw_str = "%f kB/s" % (value / 1024.0)
        
        output.append("%s: %s" % (what, bw_str))
        
        # Check thresholds
        if crit_bytes != None and value >= crit_bytes:
            summarystate = 2
            output.append(" >= %s(!!)" % ("%f MB/s" % (crit_bytes / 1048576.0)))
        elif warn_bytes != None and value >= warn_bytes:
            summarystate = max(1, summarystate)
            output.append(" >= %s(!)" % ("%f MB/s" % (warn_bytes / 1048576.0)))
    
    # Frame counts
    rxframes_rate = rxframes
    txframes_rate = txframes
    output.append("rxframes: %f" % rxframes_rate)
    output.append("txframes: %f" % txframes_rate)
    
    # Error counters
    # CRC errors
    if rxframes_rate > 0 or rxcrcs > 0:
        rxcrcs_rate = rxcrcs / (rxframes_rate + rxcrcs) if (rxframes_rate + rxcrcs) > 0 else 0
    else:
        rxcrcs_rate = 0
    output.append("CRC errors: %f%%" % (rxcrcs_rate * 100.0))
    
    warn, crit = rxcrcs_levels
    if crit != None and rxcrcs_rate * 100.0 >= crit:
        summarystate = 2
        output[-1] += "(!!)"
    elif warn != None and rxcrcs_rate * 100.0 >= warn:
        summarystate = max(1, summarystate)
        output[-1] += "(!)"
    
    # ENC-Out
    if rxframes_rate > 0 or rxencoutframes > 0:
        rxencoutframes_rate = rxencoutframes / (rxframes_rate + rxencoutframes) if (rxframes_rate + rxencoutframes) > 0 else 0
    else:
        rxencoutframes_rate = 0
    output.append("ENC-Out: %f%%" % (rxencoutframes_rate * 100.0))
    
    warn, crit = rxencoutframes_levels
    if crit != None and rxencoutframes_rate * 100.0 >= crit:
        summarystate = 2
        output[-1] += "(!!)"
    elif warn != None and rxencoutframes_rate * 100.0 >= warn:
        summarystate = max(1, summarystate)
        output[-1] += "(!)"
    
    # ENC-In
    if rxframes_rate > 0 or rxencinframes > 0:
        rxencinframes_rate = rxencinframes / (rxframes_rate + rxencinframes) if (rxframes_rate + rxencinframes) > 0 else 0
    else:
        rxencinframes_rate = 0
    output.append("ENC-In: %f%%" % (rxencinframes_rate * 100.0))
    
    warn, crit = rxencinframes_levels
    if crit != None and rxencinframes_rate * 100.0 >= crit:
        summarystate = 2
        output[-1] += "(!!)"
    elif warn != None and rxencinframes_rate * 100.0 >= warn:
        summarystate = max(1, summarystate)
        output[-1] += "(!)"
    
    # No TX buffer credits
    if txframes_rate > 0 or notxcredits > 0:
        notxcredits_rate = notxcredits / (txframes_rate + notxcredits) if (txframes_rate + notxcredits) > 0 else 0
    else:
        notxcredits_rate = 0
    output.append("No TX buffer credits: %f%%" % (notxcredits_rate * 100.0))
    
    warn, crit = notxcredits_levels
    if crit != None and notxcredits_rate * 100.0 >= crit:
        summarystate = 2
        output[-1] += "(!!)"
    elif warn != None and notxcredits_rate * 100.0 >= warn:
        summarystate = max(1, summarystate)
        output[-1] += "(!)"
    
    # C3 discards
    if txframes_rate > 0 or c3discards > 0:
        c3discards_rate = c3discards / (txframes_rate + c3discards) if (txframes_rate + c3discards) > 0 else 0
    else:
        c3discards_rate = 0
    output.append("C3 discards: %f%%" % (c3discards_rate * 100.0))
    
    warn, crit = c3discards_levels
    if crit != None and c3discards_rate * 100.0 >= crit:
        summarystate = 2
        output[-1] += "(!!)"
    elif warn != None and c3discards_rate * 100.0 >= warn:
        summarystate = max(1, summarystate)
        output[-1] += "(!)"
    
    # Port states
    # Physical state
    phystate_msg = _BROCADE_FCPORT_PHYSTATES.get(phystate, "unknown")
    phystate_warn_states = [1, 6]
    if phystate not in phystate_warn_states:
        output.append("Physical: %s" % phystate_msg)
    else:
        summarystate = max(1, summarystate)
        output.append("Physical: %s(!)" % phystate_msg)
    
    # Operational state
    opstate_msg = _BROCADE_FCPORT_OPSTATES.get(opstate, "unknown")
    opstate_warn_states = [1, 3]
    if opstate not in opstate_warn_states:
        output.append("Operational: %s" % opstate_msg)
    else:
        summarystate = max(1, summarystate)
        output.append("Operational: %s(!)" % opstate_msg)
    
    # Administrative state
    admstate_msg = _BROCADE_FCPORT_ADMSTATES.get(admstate, "unknown")
    admstate_warn_states = [0, 1, 3]
    if admstate not in admstate_warn_states:
        output.append("Administrative: %s" % admstate_msg)
    else:
        summarystate = max(1, summarystate)
        output.append("Administrative: %s(!)" % admstate_msg)
    
    # BB credits
    if bbcredits != None:
        output.append("BB credits: %d" % bbcredits)
    
    # Determine state
    if summarystate == 2:
        state_str = "CRIT"
    elif summarystate == 1:
        state_str = "WARN"
    else:
        state_str = "OK"
    
    # Build metrics (simplified - in a real implementation, compute rates from value_store)
    metrics = {}
    metrics["rx"] = in_bytes
    metrics["tx"] = out_bytes
    metrics["rxframes"] = rxframes
    metrics["txframes"] = txframes
    metrics["rxcrcs"] = rxcrcs_rate * 100.0
    metrics["rxencoutframes"] = rxencoutframes_rate * 100.0
    metrics["rxencinframes"] = rxencinframes_rate * 100.0
    metrics["notxcredits"] = notxcredits_rate * 100.0
    metrics["c3discards"] = c3discards_rate * 100.0
    if bbcredits != None:
        metrics["fc_bbcredit_zero"] = bbcredits
    
    return {
        "changed": False,
        "msg": ", ".join(output),
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": "",
        },
    }