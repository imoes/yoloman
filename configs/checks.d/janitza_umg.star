# Starlark module for Checkmk janitza_umg check (read-only)
# Translated from cmk/plugins/janitza/agent_based/janitza_umg.py

# Device type mapping (OID to model string)
_janitza_device_map = {
    ".1.3.6.1.4.1.34278.8.6": "96",
    ".1.3.6.1.4.1.34278.10.1": "604",
    ".1.3.6.1.4.1.34278.10.4": "508",
}

# SNMP base OID
_BASE_OID = ".1.3.6.1.4.1.34278"

def _parse_janitza_umg(ctx, host, community):
    """Parse janitza UMG data via SNMP and return a dict of phases, total, frequency, temperature"""
    # Get system OID for device detection
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return None
    
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return None
    
    sysoid = lines[0].strip()
    eq_pos = sysoid.find(" = ")
    if eq_pos != -1:
        sysoid = sysoid[eq_pos + 3:].strip()
    
    device_type = _janitza_device_map.get(sysoid)
    if device_type == None:
        return None
    
    # Determine info offsets based on device type
    info_offsets = {
        "508": {"energy": 4, "sumenergy": 5, "misc": 8},
        "604": {"energy": 4, "sumenergy": 5, "misc": 8},
        "96":  {"energy": 3, "sumenergy": 4, "misc": 6},
    }[device_type]
    
    # Set up counts for field positions
    if device_type in ["508", "604"]:
        num_phases = 4
        num_currents = 4
    else:
        num_phases = 3
        num_currents = 6
    
    counts = [
        num_phases,  # voltages
        3,           # L1-L2, L2-L3, L3-L1
        num_currents,  # currents
        num_phases,  # real power
        num_phases,  # reactive power
        num_phases,  # apparent power
        num_phases,  # power factor
    ]
    
    def _offset(block_id, phase):
        total = 0
        for i in range(block_id):
            total += counts[i]
        return total + phase
    
    # Helper to fetch SNMP data
    def _fetch_tree(base, oids):
        out = []
        for o in oids:
            oid = base + "." + str(o)
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
            if res.rc != 0:
                return None
            out.append(res.stdout)
        return out
    
    # Fetch all required trees
    tree1 = _fetch_tree(_BASE_OID, ["1"])  # RMS phase data
    tree2 = _fetch_tree(_BASE_OID, ["2"])  # Sum phase data
    tree3 = _fetch_tree(_BASE_OID, [str(3 + info_offsets["energy"])])  # Energy
    tree4 = _fetch_tree(_BASE_OID, [str(3 + info_offsets["sumenergy"])])  # Sum energy
    tree5 = _fetch_tree(_BASE_OID, [str(3 + info_offsets["misc"])])  # Misc (freq + temp)
    
    if not (tree1 != None and tree2 != None and tree3 != None and tree4 != None and tree5 != None):
        return None
    
    # Helper to flatten string table lines
    def _flatten(table):
        result = []
        for line in table:
            line = line.strip()
            eq_pos = line.find(" = ")
            if eq_pos != -1:
                result.append(line[eq_pos + 3:].strip())
        return result
    
    # Extract and flatten all tables
    rmsphase = _flatten(tree1)
    sumphase = _flatten(tree2)
    energy = _flatten(tree3)
    sumenergy = _flatten(tree4)
    misc = _flatten(tree5)
    
    # Build phases dict
    phases = {}
    for p in range(num_phases):
        offset_0 = _offset(0, p)  # voltage
        offset_2 = _offset(2, p)  # current
        offset_3 = _offset(3, p)  # real power
        offset_5 = _offset(5, p)  # apparent power
        
        if offset_0 < len(rmsphase) and offset_2 < len(rmsphase) and offset_3 < len(rmsphase) and offset_5 < len(rmsphase):
            phases["Phase %d" % (p + 1)] = {
                "voltage": int(rmsphase[offset_0]) / 10.0,
                "current": int(rmsphase[offset_2]) / 1000.0,
                "power": int(rmsphase[offset_3]),
                "appower": int(rmsphase[offset_5]),
                "energy": int(energy[p]) / 10.0,
            }
    
    # Build total
    total = {
        "power": int(sumphase[0]) if len(sumphase) > 0 else 0,
        "energy": int(sumenergy[0]) if len(sumenergy) > 0 else 0,
    }
    
    # Frequency and temperature (not present on UMG508/604)
    frequency = 0.0
    temperature = {}
    
    if len(misc) > 0:
        frequency = int(misc[0]) / 100.0
        if device_type == "96":
            for i in range(1, len(misc)):
                temp_val = int(misc[i])
                if temp_val != -1000:
                    temperature[str(i)] = temp_val / 10.0
    
    return {
        "phases": phases,
        "total": total,
        "frequency": frequency,
        "temperature": temperature,
    }

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        section = _parse_janitza_umg(ctx, host, community)
        
        if section == None:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Discover per-phase services
        discovery = []
        for item in section["phases"]:
            discovery.append({"item": item, "params": {}, "metrics": ["voltage", "current", "power", "appower", "energy"]})
        
        # Discover frequency service (fixed item "1")
        discovery.append({"item": "1", "params": {"levels_lower": [0, 0]}, "metrics": ["frequency"]})
        
        # Discover temperature services
        for num, temp in section["temperature"].items():
            if temp != -1000:
                discovery.append({"item": num, "params": {}, "metrics": ["temperature"]})
        
        return {"changed": False, "msg": "discovered %d services" % len(discovery), "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    section = _parse_janitza_umg(ctx, host, community)
    
    if section == None:
        return {"changed": False, "msg": "could not retrieve device data", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Phase check (e.g., "Phase 1")
    if item.startswith("Phase "):
        phase_data = section["phases"].get(item)
        if phase_data == None:
            return {"changed": False, "msg": "Phase %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Default threshold values (Checkmk defaults)
        warn_voltage = 260.0
        crit_voltage = 280.0
        warn_current = 16.0
        crit_current = 20.0
        
        # Extract voltage levels if provided in params
        if params.get("voltage_levels") != None:
            upper = params.get("voltage_levels").get("upper")
            if upper != None:
                if len(upper) > 0:
                    warn_voltage = upper[0]
                if len(upper) > 1:
                    crit_voltage = upper[1]
        
        # Extract current levels if provided in params
        if params.get("current_levels") != None:
            upper = params.get("current_levels").get("upper")
            if upper != None:
                if len(upper) > 0:
                    warn_current = upper[0]
                if len(upper) > 1:
                    crit_current = upper[1]
        
        # Calculate metrics and state
        metrics = {}
        state = "OK"
        details = []
        
        # Voltage: always report
        voltage = phase_data["voltage"]
        metrics["voltage"] = voltage
        if voltage >= crit_voltage:
            state = "CRIT"
        elif voltage >= warn_voltage:
            state = "WARN"
        
        # Current
        current = phase_data["current"]
        metrics["current"] = current
        if current >= crit_current:
            state = "CRIT"
        elif current >= warn_current:
            state = "WARN"
        
        # Power (always report)
        power = phase_data["power"]
        metrics["power"] = power
        
        # Apparent power (always report)
        appower = phase_data.get("appower")
        if appower != None:
            metrics["appower"] = appower
        
        # Energy (always report)
        energy = phase_data.get("energy")
        if energy != None:
            metrics["energy"] = energy
        
        return {"changed": False, "msg": "%s voltage=%fV current=%fA power=%dW" % (item, voltage, current, phase_data["power"]),
                "data": {"state": state, "metrics": metrics, "details": ""}}
    
    # Frequency check (item "1")
    if item == "1":
        frequency = section["frequency"]
        levels_lower = params.get("levels_lower", [0, 0])
        warn_freq = levels_lower[0] if len(levels_lower) > 0 else None
        crit_freq = levels_lower[1] if len(levels_lower) > 1 else None
        
        metrics = {"frequency": frequency}
        state = "OK"
        details = "Frequency: %f Hz" % frequency
        
        # Lower thresholds: CRIT if <= crit_freq, WARN if <= warn_freq
        if crit_freq != None and frequency <= crit_freq:
            state = "CRIT"
        elif warn_freq != None and frequency <= warn_freq:
            state = "WARN"
        
        return {"changed": False, "msg": "%s" % details, 
                "data": {"state": state, "metrics": metrics, "details": ""}}
    
    # Temperature check (numeric item like "1", "2", ...)
    if item.isdigit():
        temperature = section["temperature"].get(item)
        if temperature == None:
            return {"changed": False, "msg": "Temperature sensor %s not found" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        # Temperature params (default from Checkmk temperature check)
        warn_upper = None
        crit_upper = None
        warn_lower = None
        crit_lower = None
        
        # Parse levels if provided
        if params.get("levels") != None:
            levels = params.get("levels")
            if len(levels) > 0:
                warn_upper = levels[0]
            if len(levels) > 1:
                crit_upper = levels[1]
        
        if params.get("levels_lower") != None:
            levels_lower = params.get("levels_lower")
            if len(levels_lower) > 0:
                warn_lower = levels_lower[0]
            if len(levels_lower) > 1:
                crit_lower = levels_lower[1]
        
        metrics = {"temperature": temperature}
        state = "OK"
        details = "Temperature: %f°C" % temperature
        
        # Upper thresholds
        if crit_upper != None and temperature >= crit_upper:
            state = "CRIT"
        elif warn_upper != None and temperature >= warn_upper:
            state = "WARN"
        
        # Lower thresholds
        if state == "OK" and crit_lower != None and temperature <= crit_lower:
            state = "CRIT"
        elif state == "OK" and warn_lower != None and temperature <= warn_lower:
            state = "WARN"
        
        return {"changed": False, "msg": "%s" % details,
                "data": {"state": state, "metrics": metrics, "details": ""}}
    
    return {"changed": False, "msg": "Unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}