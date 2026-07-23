# Top-level constants for humidity thresholds
DEFAULT_WARN_UPPER = 70.0
DEFAULT_CRIT_UPPER = 75.0
DEFAULT_WARN_LOWER = 40.0
DEFAULT_CRIT_LOWER = 30.0

def _parse_snmp_lines(lines):
    result = []
    for line in lines:
        stripped_line = line.strip()
        if len(stripped_line) == 0:
            continue
        eq_pos = stripped_line.find("=")
        if eq_pos == -1:
            continue
        value_part = stripped_line[eq_pos+1:].strip()
        if len(value_part) == 0:
            continue
        
        # Extract numeric value (strip type prefix like "STRING:" or "INTEGER:")
        colon_pos = value_part.find(":")
        if colon_pos != -1:
            value_str = value_part[colon_pos+1:].strip()
            if len(value_str) == 0:
                continue
            # Remove surrounding quotes if present
            if len(value_str) >= 2 and value_str.startswith('"') and value_str.endswith('"'):
                value_str = value_str[1:-1]
            if len(value_str) == 0:
                continue
            # Check if it's a valid integer
            is_valid_int = True
            for c in value_str:
                if c < '0' or c > '9':
                    is_valid_int = False
                    break
            if is_valid_int:
                result.append((int(value_str)))
                continue
            # Try float conversion - manual validation
            is_valid_float = True
            has_dot = False
            has_digit = False
            for c in value_str:
                if c == '.':
                    if has_dot:
                        is_valid_float = False
                        break
                    has_dot = True
                elif c >= '0' and c <= '9':
                    has_digit = True
                elif c != '+' and c != '-' and c != 'e' and c != 'E':
                    is_valid_float = False
                    break
            if is_valid_float and has_digit:
                result.append((float(value_str)))
        else:
            # Try direct numeric parsing
            is_valid_int = True
            for c in value_str:
                if c < '0' or c > '9':
                    is_valid_int = False
                    break
            if is_valid_int:
                result.append((int(value_str)))
                continue
            # Try float
            is_valid_float = True
            has_dot = False
            has_digit = False
            for c in value_str:
                if c == '.':
                    if has_dot:
                        is_valid_float = False
                        break
                    has_dot = True
                elif c >= '0' and c <= '9':
                    has_digit = True
                elif c != '+' and c != '-' and c != 'e' and c != 'E':
                    is_valid_float = False
                    break
            if is_valid_float and has_digit:
                result.append((float(value_str)))
    return result

def _discover_humidity(ctx, params):
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.3711.15.1.1.1.2"
    ], mutates=False)
    
    if res.rc != 0:
        return []
    
    parsed = _parse_snmp_lines(res.stdout.splitlines())
    if len(parsed) == 0:
        return []
    
    return [{
        "item": "",
        "params": {
            "levels": (DEFAULT_WARN_UPPER, DEFAULT_CRIT_UPPER),
            "levels_lower": (DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER)
        },
        "metrics": ["humidity"]
    }]

def _check_humidity(value, params):
    warn_upper = params.get("levels", (DEFAULT_WARN_UPPER, DEFAULT_CRIT_UPPER))[0]
    crit_upper = params.get("levels", (DEFAULT_WARN_UPPER, DEFAULT_CRIT_UPPER))[1]
    warn_lower = params.get("levels_lower", (DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER))[0]
    crit_lower = params.get("levels_lower", (DEFAULT_WARN_LOWER, DEFAULT_CRIT_LOWER))[1]
    
    state = "OK"
    if value >= crit_upper:
        state = "CRIT"
    elif value >= warn_upper:
        state = "WARN"
    elif value <= crit_lower:
        state = "CRIT"
    elif value <= warn_lower:
        state = "WARN"
    
    return state, {"humidity": value}

def main(ctx, params):
    if params.get("_discover"):
        items = _discover_humidity(ctx, params)
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items}
        }
    
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.3711.15.1.1.1.2"
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    parsed = _parse_snmp_lines(res.stdout.splitlines())
    if len(parsed) == 0:
        return {
            "changed": False,
            "msg": "no humidity data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    reading = parsed[0]
    humidity_value = float(reading) / 10.0
    
    state, metrics = _check_humidity(humidity_value, params)
    
    msg = "Humidity: %f%%" % humidity_value
    if state == "OK":
        msg += " (within limits)"
    elif state == "WARN":
        msg += " (warning)"
    elif state == "CRIT":
        msg += " (critical)"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }