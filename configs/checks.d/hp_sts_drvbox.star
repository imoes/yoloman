# Mapping constants (defined at module top level)
HP_STS_DRVBOX_TYPE_MAP = {
    "1": "other",
    "2": "ProLiant Storage System",
    "3": "ProLiant-2 Storage System",
    "4": "internal ProLiant-2 Storage System",
    "5": "proLiant2DuplexTop",
    "6": "proLiant2DuplexBottom",
    "7": "proLiant2InternalDuplexTop",
    "8": "proLiant2InternalDuplexBottom",
}

HP_STS_DRVBOX_COND_MAP = {
    "1": (0, "other"),   # 0=UNKNOWN, 1=OK, 2=WARN, 3=CRIT
    "2": (1, "ok"),
    "3": (2, "degraded"),
    "4": (3, "failed"),
}

HP_STS_DRVBOX_FAN_MAP = {
    "1": (0, "other"),
    "2": (1, "ok"),
    "3": (3, "failed"),
    "4": (None, "noFan"),   # None means skip
    "5": (2, "degraded"),
}

HP_STS_DRVBOX_TEMP_MAP = {
    "1": (0, "other"),
    "2": (1, "ok"),
    "3": (2, "degraded"),
    "4": (3, "failed"),
    "5": (None, "noTemp"),
}

HP_STS_DRVBOX_SP_MAP = {
    "1": (0, "other"),
    "2": (1, "sidePanelInPlace"),
    "3": (3, "sidePanelRemoved"),
    "4": (None, "noSidePanelStatus"),
}

HP_STS_DRVBOX_PWR_MAP = {
    "1": (0, "other"),
    "2": (1, "ok"),
    "3": (2, "degraded"),
    "4": (3, "failed"),
    "5": (None, "noFltTolPower"),
}

# State code mapping (Checkmk State constants)
STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

def _hp_sts_get_state(code):
    if code == None:
        return None
    if code == 0:
        return STATE_UNKNOWN
    if code == 1:
        return STATE_OK
    if code == 2:
        return STATE_WARN
    if code == 3:
        return STATE_CRIT
    return STATE_UNKNOWN

def _hp_sts_parse_section(section):
    # Parse SNMP output: list of lines, each line is list of strings
    parsed = []
    for line in section:
        if len(line) >= 11:
            parsed.append(line)
    return parsed

def _hp_sts_build_section(raw_data):
    # raw_data: string from snmpwalk, each line is "OID = TYPE: value"
    # Returns list of lines, each line is list of values
    lines = raw_data.splitlines()
    result = []
    current = []
    for line in lines:
        stripped = line.strip()
        if stripped == "":
            continue
        if "=" in stripped:
            parts = stripped.rsplit(":", 1)
            if len(parts) == 2:
                value = parts[1].strip()
                current.append(value)
                if len(current) == 11:
                    result.append(current)
                    current = []
            else:
                # Handle cases where value contains ":"
                value = parts[1].strip() if len(parts) > 1 else ""
                current.append(value)
                if len(current) == 11:
                    result.append(current)
                    current = []
    return result

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch SNMP data and enumerate items
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.232.8.2.1.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }
        
        section = _hp_sts_build_section(res.stdout)
        items = []
        for line in section:
            if len(line) >= 4 and line[3] != "":
                item_name = "%s/%s" % (line[0], line[1])
                items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": []
                })
        
        return {
            "changed": False,
            "msg": "discovered %d drive boxes" % len(items),
            "data": {"discovery": items}
        }
    
    # Check mode
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.232.8.2.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}
        }
    
    section = _hp_sts_build_section(res.stdout)
    found = False
    
    for line in section:
        if len(line) < 11:
            continue
        key = "%s/%s" % (line[0], line[1])
        if key != item:
            continue
        found = True
        
        (
            _c_index,
            _b_index,
            ty,
            model,
            fan_status,
            cond,
            temp_status,
            sp_status,
            pwr_status,
            serial,
            loc,
        ) = line[:11]
        
        details_parts = []
        
        # Check Fan-Status
        state_data = HP_STS_DRVBOX_FAN_MAP.get(fan_status)
        if state_data != None:
            state_code, name = state_data
            state = _hp_sts_get_state(state_code)
            if state != None:
                details_parts.append("Fan-Status: %s" % name)
        
        # Check Condition
        state_data = HP_STS_DRVBOX_COND_MAP.get(cond)
        if state_data != None:
            state_code, name = state_data
            state = _hp_sts_get_state(state_code)
            if state != None:
                details_parts.append("Condition: %s" % name)
        
        # Check Temp-Status
        state_data = HP_STS_DRVBOX_TEMP_MAP.get(temp_status)
        if state_data != None:
            state_code, name = state_data
            state = _hp_sts_get_state(state_code)
            if state != None:
                details_parts.append("Temp-Status: %s" % name)
        
        # Check Sidepanel-Status
        state_data = HP_STS_DRVBOX_SP_MAP.get(sp_status)
        if state_data != None:
            state_code, name = state_data
            state = _hp_sts_get_state(state_code)
            if state != None:
                details_parts.append("Sidepanel-Status: %s" % name)
        
        # Check Power-Status
        state_data = HP_STS_DRVBOX_PWR_MAP.get(pwr_status)
        if state_data != None:
            state_code, name = state_data
            state = _hp_sts_get_state(state_code)
            if state != None:
                details_parts.append("Power-Status: %s" % name)
        
        # Always include basic info
        type_name = HP_STS_DRVBOX_TYPE_MAP.get(ty, "unknown")
        details_parts.append("Type: %s, Model: %s, Serial: %s, Location: %s" % (type_name, model, serial, loc))
        
        # Determine worst state among the conditions we checked
        worst_state = STATE_OK
        for state_data in [
            HP_STS_DRVBOX_FAN_MAP.get(fan_status),
            HP_STS_DRVBOX_COND_MAP.get(cond),
            HP_STS_DRVBOX_TEMP_MAP.get(temp_status),
            HP_STS_DRVBOX_SP_MAP.get(sp_status),
            HP_STS_DRVBOX_PWR_MAP.get(pwr_status)
        ]:
            if state_data != None:
                state_code, _name = state_data
                state = _hp_sts_get_state(state_code)
                if state != None:
                    if state == STATE_CRIT:
                        worst_state = STATE_CRIT
                    elif state == STATE_WARN and worst_state != STATE_CRIT:
                        worst_state = STATE_WARN
                    elif state == STATE_UNKNOWN and worst_state == STATE_OK:
                        worst_state = STATE_UNKNOWN
        
        return {
            "changed": False,
            "msg": ", ".join(details_parts),
            "data": {"state": worst_state, "metrics": {}, "details": ", ".join(details_parts)}
        }
    
    if not found:
        return {
            "changed": False,
            "msg": "Controller not found in snmp data",
            "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}
        }