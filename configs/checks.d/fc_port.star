def fc_parse_counter(value):
    # Parse OCTETSTR counter to integer - simplified version
    # Assuming values are already converted to string integers
    if not value:
        return 0
    return int(value) if value.isdigit() else 0

def main(ctx, params):
    if params.get("_discover"):
        # Discover FC ports via SNMP
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # OID base .1.3.6.1.3.94 for Brocade FC port information
        base_oid = ".1.3.6.1.3.94"
        
        # Fetch the required OIDs: index(1.10.1.2), porttype(1.10.1.3), admstate(1.10.1.6),
        # opstate(1.10.1.7), phystate(1.10.1.23), portname(1.10.1.17), and counters
        # Counters: rxelements(4.5.1.4), txelements(4.5.1.5), rxobjects(4.5.1.6), txobjects(4.5.1.7),
        # notxcredits(4.5.1.8), c3discards(4.5.1.28), rxcrcs(4.5.1.40), rxencoutframes(4.5.1.50)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            base_oid + ".1.10.1.2",  # index
            base_oid + ".1.10.1.3",  # porttype
            base_oid + ".1.10.1.6",  # admstate
            base_oid + ".1.10.1.7",  # opstate
            base_oid + ".1.10.1.15", # speed
            base_oid + ".1.10.1.17", # portname
            base_oid + ".1.10.1.23", # phystate
            base_oid + ".4.5.1.4",   # rxelements
            base_oid + ".4.5.1.5",   # txelements
            base_oid + ".4.5.1.6",   # rxobjects
            base_oid + ".4.5.1.7",   # txobjects
            base_oid + ".4.5.1.8",   # notxcredits
            base_oid + ".4.5.1.28",  # c3discards
            base_oid + ".4.5.1.40",  # rxcrcs
            base_oid + ".4.5.1.50",  # rxencoutframes
        ], mutates=False)
        
        # Parse SNMP output - each line format: OID = STRING: value
        lines = res.stdout.splitlines()
        if not lines or res.rc != 0:
            return {"changed": False, "msg": "discovered 0 ports", "data": {"discovery": []}}
        
        # Map OID to value
        data = {}
        for line in lines:
            if "=" in line:
                parts = line.split("=", 1)
                oid = parts[0].strip()
                val = parts[1].strip()
                # Extract base OID component (last number)
                if oid.startswith(base_oid):
                    key = oid[len(base_oid)+1:]
                    if key not in data:
                        data[key] = []
                    # Handle string values (like portname) and numeric values
                    if val.startswith("STRING:") or val.startswith("OCTETSTR:"):
                        data[key].append(val.split(":",1)[1].strip().strip('"'))
                    else:
                        data[key].append(val.split(":",1)[1].strip())
        
        # Organize data by port index
        ports = []
        num_ports = 0
        if data:
            indices = data.get("1.10.1.2", [])
            num_ports = len(indices)
            for i in range(min(num_ports, len(indices))):
                val = indices[i] if i < len(indices) else ""
                if not val or not val.isdigit():
                    continue
                    
                port_index = int(val)
                
                porttype_val = data.get("1.10.1.3", ["0"])[i] if i < len(data.get("1.10.1.3", ["0"])) else "0"
                porttype = int(porttype_val) if porttype_val.isdigit() else 0
                
                admstate_val = data.get("1.10.1.6", ["0"])[i] if i < len(data.get("1.10.1.6", ["0"])) else "0"
                admstate = int(admstate_val) if admstate_val.isdigit() else 0
                
                opstate_val = data.get("1.10.1.7", ["0"])[i] if i < len(data.get("1.10.1.7", ["0"])) else "0"
                opstate = int(opstate_val) if opstate_val.isdigit() else 0
                
                phystate_val = data.get("1.10.1.23", ["0"])[i] if i < len(data.get("1.10.1.23", ["0"])) else "0"
                phystate = int(phystate_val) if phystate_val.isdigit() else 0
                
                portname = ""
                if "1.10.1.17" in data and len(data["1.10.1.17"]) > i:
                    portname = data["1.10.1.17"][i].strip('"')
                
                # Skip non-inventory ports
                if porttype in [3]:
                    continue
                if admstate in [1, 3]:
                    continue
                if phystate in []:
                    continue
                    
                # Build item name with zero-padding
                fmt = "%0" + str(len(str(num_ports))) + "d"
                item_name = fmt % (port_index - 1)
                if portname.strip():
                    item_name = item_name + " " + portname.strip()
                
                ports.append({
                    "item": item_name,
                    "params": {
                        "rxcrcs": (3.0, 20.0),
                        "rxencoutframes": (3.0, 20.0),
                        "notxcredits": (3.0, 20.0),
                        "c3discards": (3.0, 20.0)
                    },
                    "metrics": ["rxelements", "txelements", "rxobjects", "txobjects", 
                               "rxcrcs", "rxencoutframes", "notxcredits", "c3discards"]
                })
        
        return {"changed": False, "msg": "discovered %d ports" % len(ports), 
                "data": {"discovery": ports}}
    
    # Check mode: process single item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract index from item name (first number part)
    parts = item.split()
    idx_part = parts[0] if parts else ""
    if not idx_part or not idx_part.isdigit():
        return {"changed": False, "msg": "invalid item format", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    index = int(idx_part)
    
    # SNMP query for this specific port's data
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Build OID for specific port index: index=1, porttype=2, etc.
    base_oid = ".1.3.6.1.3.94"
    
    # For simplicity, query all needed OIDs and parse as needed
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        base_oid + ".1.10.1.2",  # index
        base_oid + ".1.10.1.3",  # porttype
        base_oid + ".1.10.1.6",  # admstate
        base_oid + ".1.10.1.7",  # opstate
        base_oid + ".1.10.1.15", # speed
        base_oid + ".1.10.1.17", # portname
        base_oid + ".1.10.1.23", # phystate
        base_oid + ".4.5.1.4",   # rxelements
        base_oid + ".4.5.1.5",   # txelements
        base_oid + ".4.5.1.6",   # rxobjects
        base_oid + ".4.5.1.7",   # txobjects
        base_oid + ".4.5.1.8",   # notxcredits
        base_oid + ".4.5.1.28",  # c3discards
        base_oid + ".4.5.1.40",  # rxcrcs
        base_oid + ".4.5.1.50",  # rxencoutframes
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP query failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse data - extract values for this specific port index
    lines = res.stdout.splitlines()
    
    # Create a simple parser
    def parse_snmp_value(line):
        if "=" in line:
            parts = line.split("=", 1)
            oid = parts[0].strip()
            val = parts[1].strip()
            if val.startswith("STRING:") or val.startswith("OCTETSTR:"):
                return oid, val.split(":",1)[1].strip().strip('"')
            else:
                return oid, val.strip()
        return None, None
    
    # Parse all values into structured format
    oid_values = {}
    for line in lines:
        oid, val = parse_snmp_value(line)
        if oid and val != None:
            # Extract index from OID like .1.3.6.1.3.94.1.10.1.2.1 -> value at index 1
            oid_suffix = oid[len(base_oid)+1:] if oid.startswith(base_oid) else oid
            # Simple approach: split by '.' and get last element as index
            oid_parts = oid_suffix.split('.')
            if len(oid_parts) >= 2 and oid_parts[-1].isdigit():
                port_idx = int(oid_parts[-1])
                if port_idx == index + 1:
                    oid_values[oid_parts[0]] = val
    
    # Extract port data
    porttype_str = oid_values.get("3", "0")
    porttype = int(porttype_str) if porttype_str.isdigit() else 0
    
    admstate_str = oid_values.get("6", "0")
    admstate = int(admstate_str) if admstate_str.isdigit() else 0
    
    opstate_str = oid_values.get("7", "0")
    opstate = int(opstate_str) if opstate_str.isdigit() else 0
    
    phystate_str = oid_values.get("23", "0")
    phystate = int(phystate_str) if phystate_str.isdigit() else 0
    
    speed_str = oid_values.get("15", "")
    portname = oid_values.get("17", "")
    
    # Parse speed if available
    wirespeed = 0.0
    gbit = 16.0  # default
    if speed_str and speed_str.isdigit():
        wirespeed = float(speed_str) * 1000.0
        gbit = wirespeed * 8.0 / (1000.0 * 1000.0 * 1000.0)
    else:
        wirespeed = gbit * 1000.0 * 1000.0 * 1000.0 / 8.0
    
    # Get counter values
    rxelements = fc_parse_counter(oid_values.get("4", ""))
    txelements = fc_parse_counter(oid_values.get("5", ""))
    rxobjects = fc_parse_counter(oid_values.get("6", ""))
    txobjects = fc_parse_counter(oid_values.get("7", ""))
    notxcredits = fc_parse_counter(oid_values.get("8", ""))
    c3discards = fc_parse_counter(oid_values.get("28", ""))
    rxcrcs = fc_parse_counter(oid_values.get("40", ""))
    rxencoutframes = fc_parse_counter(oid_values.get("50", ""))
    
    # Simplified check logic
    summarystate = 0
    output_parts = []
    
    # Bandwidth (simplified - not tracking rates across time)
    output_parts.append("%f Gbit/s" % gbit)
    
    # Error percentage thresholds
    rxcrcs_warn = params.get("rxcrcs", (3.0, 20.0))[0]
    rxcrcs_crit = params.get("rxcrcs", (3.0, 20.0))[1]
    
    rxenc_warn = params.get("rxencoutframes", (3.0, 20.0))[0]
    rxenc_crit = params.get("rxencoutframes", (3.0, 20.0))[1]
    
    notx_warn = params.get("notxcredits", (3.0, 20.0))[0]
    notx_crit = params.get("notxcredits", (3.0, 20.0))[1]
    
    c3_warn = params.get("c3discards", (3.0, 20.0))[0]
    c3_crit = params.get("c3discards", (3.0, 20.0))[1]
    
    # Map state codes
    fc_port_admstates = {
        1: ("unknown", 1),
        2: ("online", 0),
        3: ("offline", 0),
        4: ("bypassed", 1),
        5: ("diagnostics", 1),
    }
    
    fc_port_opstates = {
        1: ("unknown", 1),
        2: ("unused", 1),
        3: ("ready", 0),
        4: ("warning", 1),
        5: ("failure", 2),
        6: ("not participating", 1),
        7: ("initializing", 1),
        8: ("bypass", 1),
        9: ("ols", 0),
    }
    
    fc_port_phystates = {
        1: ("unknown", 1),
        2: ("failed", 2),
        3: ("bypassed", 1),
        4: ("active", 0),
        5: ("loopback", 1),
        6: ("txfault", 1),
        7: ("no media", 1),
        8: ("link down", 2),
    }
    
    porttype_list = [
        "unknown", "unknown", "other", "not-present", "hub-port",
        "n-port", "l-port", "fl-port", "f-port", "e-port",
        "g-port", "domain-ctl", "hub-controller", "scsi", "escon",
        "lan", "wan", "ac", "dc", "ssa",
    ]
    
    # Add state summaries
    adm_state_name, adm_state_val = fc_port_admstates.get(admstate, ("unknown", 1))
    op_state_name, op_state_val = fc_port_opstates.get(opstate, ("unknown", 1))
    phy_state_name, phy_state_val = fc_port_phystates.get(phystate, ("unknown", 1))
    
    # Determine overall state
    if adm_state_val > summarystate:
        summarystate = adm_state_val
    if op_state_val > summarystate:
        summarystate = op_state_val
    if phy_state_val > summarystate:
        summarystate = phy_state_val
    
    # Build output message
    msg_parts = ["%s Gbit/s" % ("%f" % gbit), adm_state_name, op_state_name, phy_state_name, 
                porttype_list[min(len(porttype_list)-1, porttype)]]
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": "OK" if summarystate == 0 else ("WARN" if summarystate == 1 else "CRIT"),
            "metrics": {
                "rxelements": rxelements,
                "txelements": txelements,
                "rxobjects": rxobjects,
                "txobjects": txobjects,
                "rxcrcs": rxcrcs,
                "rxencoutframes": rxencoutframes,
                "notxcredits": notxcredits,
                "c3discards": c3discards
            },
            "details": ""
        }
    }