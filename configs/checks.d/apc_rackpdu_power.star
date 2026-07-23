# Top-level constants (no imports, no dynamic definitions)
STATE_MAP = {
    "1": (0, "load normal"),
    "2": (2, "load low"),
    "3": (1, "load near over load"),
    "4": (2, "load over load"),
}

def main(ctx, params):
    # DISCOVERY MODE
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch device info: name + power
        res_dev = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.12.1.1.0",
            ".1.3.6.1.4.1.318.1.1.12.1.16.0"
        ], mutates=False)
        # Fetch phase count
        res_phases = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.12.2.1.2.0"
        ], mutates=False)
        # Fetch per-bank/phase info
        res_bank = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.2",  # rPDULoadStatusLoad
            ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.3",  # rPDULoadStatusLoadState
            ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.4",  # rPDULoadStatusPhaseNumber
            ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.5",  # rPDULoadStatusBankNumber
        ], mutates=False)

        # Parse device info
        pdu_name = ""
        power_str = ""
        for line in res_dev.stdout.splitlines():
            if ".1.3.6.1.4.1.318.1.1.12.1.1.0 =" in line:
                pdu_name = line.rsplit(" ", 1)[-1].strip('"')
            elif ".1.3.6.1.4.1.318.1.1.12.1.16.0 =" in line:
                power_str = line.rsplit(" ", 1)[-1]
        
        device_name = "Device " + pdu_name
        
        # Parse phase count
        n_phases_str = ""
        for line in res_phases.stdout.splitlines():
            if ".1.3.6.1.4.1.318.1.1.12.2.1.2.0 =" in line:
                n_phases_str = line.rsplit(" ", 1)[-1]
                break
        n_phases = int(n_phases_str) if n_phases_str.isdigit() else 0
        
        # Parse bank/phase info
        entries = []
        for line in res_bank.stdout.splitlines():
            parts = line.strip().split(" ")
            if len(parts) < 2:
                continue
            oid_tail = parts[0].rsplit(".", 1)[-1]
            value = parts[-1]
            if oid_tail == "2":  # Load
                entries.append({"load": value})
            elif oid_tail == "3":  # State
                entries[-1]["state"] = value
            elif oid_tail == "4":  # PhaseNumber
                entries[-1]["phase"] = value
            elif oid_tail == "5":  # BankNumber
                entries[-1]["bank"] = value
        
        out = []
        # Always include the device (PDU) itself
        out.append({"item": device_name, "params": {}, "metrics": ["power"]})
        
        # Process per-phase/bank entries
        for i in range(len(entries)):
            entry = entries[i]
            if i == 0 and n_phases == 1:
                # First entry maps to device phase (skip — already included in device)
                continue
            
            bank = entry.get("bank", "0")
            phase = entry.get("phase", "0")
            
            name_part = ""
            num = ""
            if bank != "0":
                name_part = "Bank"
                num = bank
            elif phase != "0":
                name_part = "Phase"
                num = phase
            else:
                continue
            
            item_name = name_part + " " + num
            out.append({"item": item_name, "params": {}, "metrics": ["current"]})
        
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    
    # CHECK MODE
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch data for this item
    res_dev = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.12.1.1.0",
        ".1.3.6.1.4.1.318.1.1.12.1.16.0"
    ], mutates=False)
    res_phases = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.12.2.1.2.0"
    ], mutates=False)
    res_bank = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.2",
        ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.3",
        ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.4",
        ".1.3.6.1.4.1.318.1.1.12.2.3.1.1.5"
    ], mutates=False)
    
    # Parse device info
    pdu_name = ""
    power_str = ""
    for line in res_dev.stdout.splitlines():
        if ".1.3.6.1.4.1.318.1.1.12.1.1.0 =" in line:
            pdu_name = line.rsplit(" ", 1)[-1].strip('"')
        elif ".1.3.6.1.4.1.318.1.1.12.1.16.0 =" in line:
            power_str = line.rsplit(" ", 1)[-1]
    
    device_name = "Device " + pdu_name
    
    # Parse phase count
    n_phases_str = ""
    for line in res_phases.stdout.splitlines():
        if ".1.3.6.1.4.1.318.1.1.12.2.1.2.0 =" in line:
            n_phases_str = line.rsplit(" ", 1)[-1]
            break
    n_phases = int(n_phases_str) if n_phases_str.isdigit() else 0
    
    # Parse bank/phase info
    entries = []
    for line in res_bank.stdout.splitlines():
        parts = line.strip().split(" ")
        if len(parts) < 2:
            continue
        oid_tail = parts[0].rsplit(".", 1)[-1]
        value = parts[-1]
        if oid_tail == "2":
            entries.append({"load": value})
        elif oid_tail == "3":
            entries[-1]["state"] = value
        elif oid_tail == "4":
            entries[-1]["phase"] = value
        elif oid_tail == "5":
            entries[-1]["bank"] = value
    
    # Determine which value to check
    value = None
    state_code = 0
    state_text = ""
    metric_name = ""
    human_func = lambda v: str(v)
    infoname = ""
    
    if item == device_name:
        # PDU power (watts)
        if not power_str.isdigit():
            return {"changed": False, "msg": "cannot read power value",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        value = float(power_str)
        metric_name = "power"
        human_func = lambda v: "%f W" % v
        infoname = "Power"
        # PDU has no per-item current; current is per-phase/bank only
    else:
        # Look for matching phase/bank entry
        phase_match = False
        bank_match = False
        name_part = ""
        num = ""
        
        if item.startswith("Phase "):
            name_part = "Phase"
            num = item[6:]
            phase_match = True
        elif item.startswith("Bank "):
            name_part = "Bank"
            num = item[5:]
            bank_match = True
        
        # Find matching entry
        for entry in entries:
            entry_phase = entry.get("phase", "0")
            entry_bank = entry.get("bank", "0")
            
            if bank_match and entry_bank == num:
                if not entry.get("load", "").isdigit():
                    return {"changed": False, "msg": "cannot read current for " + item,
                            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
                value = float(entry["load"]) / 10
                state_code = int(entry.get("state", "1"))
                if str(state_code) not in STATE_MAP:
                    state_code = 0
                _, state_text = STATE_MAP.get(str(state_code), (0, "unknown"))
                metric_name = "current"
                human_func = lambda v: "%f A" % v
                infoname = "Current"
                break
            elif phase_match and entry_phase == num:
                if not entry.get("load", "").isdigit():
                    return {"changed": False, "msg": "cannot read current for " + item,
                            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
                value = float(entry["load"]) / 10
                state_code = int(entry.get("state", "1"))
                if str(state_code) not in STATE_MAP:
                    state_code = 0
                _, state_text = STATE_MAP.get(str(state_code), (0, "unknown"))
                metric_name = "current"
                human_func = lambda v: "%f A" % v
                infoname = "Current"
                break
        
        if value == None:
            # Item not found
            return {"changed": False, "msg": "item not found: " + item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Apply levels (defaults: no levels — per Checkmk default params)
    # Since Checkmk default is empty dict, no levels means always OK
    params_levels = params.get(metric_name, {})
    if metric_name == "current":
        warn = params_levels.get("levels_upper")
        crit = params_levels.get("levels_upper_critical")
        # Checkmk default levels: None for both
        if warn != None:
            if value >= crit:
                state = "CRIT"
            elif value >= warn:
                state = "WARN"
            else:
                state = "OK"
        else:
            # No levels defined: use only state from SNMP
            state = "OK" if state_code == 0 else ("WARN" if state_code == 1 else "CRIT")
    else:
        # Power: only levels apply; SNMP state_code is not used for PDU power
        warn = params_levels.get("levels_upper")
        crit = params_levels.get("levels_upper_critical")
        if crit != None and value >= crit:
            state = "CRIT"
        elif warn != None and value >= warn:
            state = "WARN"
        else:
            state = "OK"
    
    # Build summary message
    msg = infoname + ": " + human_func(value)
    if metric_name == "current" and state_text != "":
        msg = msg + ", " + state_text
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {metric_name: value}, "details": ""}}
