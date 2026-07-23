def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/tmp/siemens_plc"], mutates=False)
        sections = res.stdout.split("\n\n")
        temp_section = []
        flag_section = []
        duration_section = []
        counter_section = []
        info_section = []
        cpu_state_section = []

        for section in sections:
            lines = section.strip().splitlines()
            if not lines:
                continue
            first = lines[0].strip()
            if first == "<<<siemens_plc>>>":
                for line in lines[1:]:
                    if line.strip():
                        parts = line.strip().split()
                        if len(parts) >= 3:
                            temp_section.append(parts)
                for line in lines[1:]:
                    if line.strip():
                        parts = line.strip().split()
                        if len(parts) >= 3 and parts[1] == "flag":
                            flag_section.append(parts)
                for line in lines[1:]:
                    if line.strip():
                        parts = line.strip().split()
                        if len(parts) >= 3 and (parts[1].startswith("hours") or parts[1].startswith("seconds")):
                            duration_section.append(parts)
                for line in lines[1:]:
                    if line.strip():
                        parts = line.strip().split()
                        if len(parts) >= 3 and parts[1].startswith("counter"):
                            counter_section.append(parts)
                for line in lines[1:]:
                    if line.strip():
                        parts = line.strip().split()
                        if len(parts) >= 3 and parts[1] == "text":
                            info_section.append(parts)
            elif first == "<<<siemens_plc_cpu_state>>>":
                for line in lines[1:]:
                    if line.strip():
                        cpu_state_section.append([line.strip()])
        
        discovery = []
        
        # Temp items
        for line in temp_section:
            if len(line) >= 3:
                item = line[0] + " " + line[2]
                discovery.append({
                    "item": item,
                    "params": {
                        "levels": [70.0, 80.0],
                        "device_levels_handling": "devdefault"
                    },
                    "metrics": ["temp"]
                })
        
        # Flag items
        for line in flag_section:
            if len(line) >= 3:
                item = line[0] + " " + line[2]
                discovery.append({
                    "item": item,
                    "params": {
                        "expected_state": False
                    },
                    "metrics": []
                })
        
        # Duration items
        for line in duration_section:
            if len(line) >= 3:
                item = line[0] + " " + line[2]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [line[1]]
                })
        
        # Counter items
        for line in counter_section:
            if len(line) >= 3:
                item = line[0] + " " + line[2]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": [line[1]]
                })
        
        # Info items
        for line in info_section:
            if len(line) >= 3:
                item = line[0] + " " + line[2]
                discovery.append({
                    "item": item,
                    "params": {},
                    "metrics": []
                })
        
        # CPU state (single service)
        if cpu_state_section:
            discovery.append({
                "item": "",
                "params": {},
                "metrics": []
            })
        
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery}
        }
    
    item = params.get("item", "")
    
    # Read the siemens_plc data
    res = ctx.run(["cat", "/tmp/siemens_plc"], mutates=False)
    sections = res.stdout.split("\n\n")
    temp_section = []
    flag_section = []
    duration_section = []
    counter_section = []
    info_section = []
    cpu_state_section = []

    for section in sections:
        lines = section.strip().splitlines()
        if not lines:
            continue
        first = lines[0].strip()
        if first == "<<<siemens_plc>>>":
            for line in lines[1:]:
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 3:
                        temp_section.append(parts)
            for line in lines[1:]:
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 3 and parts[1] == "flag":
                        flag_section.append(parts)
            for line in lines[1:]:
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 3 and (parts[1].startswith("hours") or parts[1].startswith("seconds")):
                        duration_section.append(parts)
            for line in lines[1:]:
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 3 and parts[1].startswith("counter"):
                        counter_section.append(parts)
            for line in lines[1:]:
                if line.strip():
                    parts = line.strip().split()
                    if len(parts) >= 3 and parts[1] == "text":
                        info_section.append(parts)
        elif first == "<<<siemens_plc_cpu_state>>>":
            for line in lines[1:]:
                if line.strip():
                    cpu_state_section.append([line.strip()])
    
    # Check for CPU state (single service, item == "")
    if item == "" and cpu_state_section:
        state = ""
        if len(cpu_state_section) > 0 and len(cpu_state_section[0]) > 0:
            state = cpu_state_section[0][0]
        
        if state == "S7CpuStatusRun":
            return {
                "changed": False,
                "msg": "CPU is running",
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }
        if state == "S7CpuStatusStop":
            return {
                "changed": False,
                "msg": "CPU is stopped",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}
            }
        return {
            "changed": False,
            "msg": "CPU is in unknown state",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Temp check
    for line in temp_section:
        if len(line) >= 3 and line[1] == "temp" and (line[0] + " " + line[2]) == item:
            temp_str = line[-1]
            temp = 0.0
            if temp_str != "" and temp_str.replace(".", "").replace("-", "").isdigit():
                temp = float(temp_str)
            else:
                return {
                    "changed": False,
                    "msg": "Temperature value invalid",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            
            levels = params.get("levels", [70.0, 80.0])
            device_levels_handling = params.get("device_levels_handling", "devdefault")
            
            # Apply Checkmk style temperature levels logic
            state = "OK"
            summary = "Temperature: %f °C" % temp
            
            if device_levels_handling == "devdefault":
                warn = levels[0] if len(levels) > 0 else None
                crit = levels[1] if len(levels) > 1 else None
            else:
                warn = None
                crit = None
            
            if warn != None and temp >= warn:
                state = "WARN"
                summary += " (warn at %f °C)" % warn
            if crit != None and temp >= crit:
                state = "CRIT"
                summary += " (crit at %f °C)" % crit
            
            return {
                "changed": False,
                "msg": summary,
                "data": {"state": state, "metrics": {"temp": temp}, "details": ""}
            }
    
    # Flag check
    for line in flag_section:
        if len(line) >= 3 and line[1] == "flag" and (line[0] + " " + line[2]) == item:
            expected_state = params.get("expected_state", False)
            flag_state = False
            if len(line) >= 4 and line[-1] == "True":
                flag_state = True
            
            if flag_state:
                if expected_state:
                    state = "OK"
                    summary = "On"
                else:
                    state = "CRIT"
                    summary = "On (expected off)"
            else:
                if expected_state:
                    state = "CRIT"
                    summary = "Off (expected on)"
                else:
                    state = "OK"
                    summary = "Off"
            
            return {
                "changed": False,
                "msg": summary,
                "data": {"state": state, "metrics": {}, "details": ""}
            }
    
    # Duration check
    for line in duration_section:
        if len(line) >= 3 and (line[1].startswith("hours") or line[1].startswith("seconds")) and (line[0] + " " + line[2]) == item:
            value_str = line[-1]
            seconds = 0.0
            if value_str != "" and value_str.replace(".", "").replace("-", "").isdigit():
                if line[1].startswith("hours"):
                    seconds = float(value_str) * 3600
                else:
                    seconds = float(value_str)
            else:
                return {
                    "changed": False,
                    "msg": "Duration value invalid",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            
            duration = params.get("duration", None)
            state = "OK"
            summary = "Duration: %f s" % seconds
            
            if duration != None and "upper" in duration:
                warn = duration["upper"][0] if len(duration["upper"]) > 0 else None
                crit = duration["upper"][1] if len(duration["upper"]) > 1 else None
                
                if warn != None and seconds >= warn:
                    state = "WARN"
                    summary += " (warn at %s)" % str(warn)
                if crit != None and seconds >= crit:
                    state = "CRIT"
                    summary += " (crit at %s)" % str(crit)
            
            return {
                "changed": False,
                "msg": summary,
                "data": {"state": state, "metrics": {line[1]: seconds}, "details": ""}
            }
    
    # Counter check
    for line in counter_section:
        if len(line) >= 3 and line[1].startswith("counter") and (line[0] + " " + line[2]) == item:
            value_str = line[-1]
            value = 0
            if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                value = int(value_str)
            else:
                return {
                    "changed": False,
                    "msg": "Counter value invalid",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            
            levels = params.get("levels", None)
            state = "OK"
            summary = "Counter: %d" % value
            
            if levels != None:
                if "upper" in levels:
                    warn = levels["upper"][0] if len(levels["upper"]) > 0 else None
                    crit = levels["upper"][1] if len(levels["upper"]) > 1 else None
                    
                    if warn != None and value >= warn:
                        state = "WARN"
                        summary += " (warn at %d)" % warn
                    if crit != None and value >= crit:
                        state = "CRIT"
                        summary += " (crit at %d)" % crit
                
                if "lower" in levels:
                    warn = levels["lower"][0] if len(levels["lower"]) > 0 else None
                    crit = levels["lower"][1] if len(levels["lower"]) > 1 else None
                    
                    if warn != None and value <= warn:
                        state = "WARN"
                        summary += " (warn at %d)" % warn
                    if crit != None and value <= crit:
                        state = "CRIT"
                        summary += " (crit at %d)" % crit
            
            return {
                "changed": False,
                "msg": summary,
                "data": {"state": state, "metrics": {line[1]: value}, "details": ""}
            }
    
    # Info check
    for line in info_section:
        if len(line) >= 3 and line[1] == "text" and (line[0] + " " + line[2]) == item:
            return {
                "changed": False,
                "msg": line[-1],
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }
    
    # Item not found
    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
