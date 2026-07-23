# Module-level constants
FORTIGATE_KEY_TO_TITLE_MAP = {
    "av_age": "AV",
    "ips_age": "IPS",
    "av_ext_age": "AV Extended",
    "ips_ext_age": "IPS Extended",
}

DEFAULT_LEVELS = {
    "av_age": (86400, 172800),
    "ips_age": (86400, 172800),
}

def _parse_version(version_string):
    # sample: 27.00768(2015-09-01 15:10)
    # Checkmk uses re.compile but Starlark has no re; use string methods
    if version_string.find("(") == -1 or version_string.find(")") == -1:
        return None, None
    
    # Split into version and timestamp parts
    paren_idx = version_string.find("(")
    version = version_string[:paren_idx]
    timestamp_str = version_string[paren_idx+1:-1]  # Remove closing paren
    
    # Validate timestamp format "YYYY-MM-DD HH:MM"
    if len(timestamp_str) != 19:
        return None, None
    if timestamp_str[4] != "-" or timestamp_str[7] != "-" or timestamp_str[10] != " " or timestamp_str[13] != ":":
        return None, None
    
    # Guard before parsing integers
    year_str = timestamp_str[0:4]
    month_str = timestamp_str[5:7]
    day_str = timestamp_str[8:10]
    hour_str = timestamp_str[11:13]
    minute_str = timestamp_str[14:16]
    
    # Check all are numeric
    if not year_str.isdigit() or not month_str.isdigit() or not day_str.isdigit() or not hour_str.isdigit() or not minute_str.isdigit():
        return None, None
    
    year = int(year_str)
    month = int(month_str)
    day = int(day_str)
    hour = int(hour_str)
    minute = int(minute_str)
    
    # Simplified time calculation (days since epoch * 86400)
    # Approximate calculation for Starlark compatibility
    days = (year - 1970) * 365 + (year - 1969) // 4
    days += [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][month - 1] + day - 1
    if month > 2 and ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0):
        days += 1
    age = days * 86400 + hour * 3600 + minute * 60
    return version, age

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: check if we can get signature data
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.12356.101.4.2"
        ], mutates=False)
        
        # Check if we got any data
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 services",
                    "data": {"discovery": []}}
        
        # Count number of signature entries (4 OIDs expected)
        lines = res.stdout.splitlines()
        if len(lines) >= 4:
            return {"changed": False, "msg": "discovered 1 service",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": ["av_age", "ips_age", "av_ext_age", "ips_ext_age"]}]}}
        return {"changed": False, "msg": "discovered 0 services",
                "data": {"discovery": []}}
    
    # Check mode: get signature data and evaluate thresholds
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.12356.101.4.2"
    ], mutates=False)
    
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse SNMP output: map OIDs to values
    # .1.3.6.1.4.1.12356.101.4.2.1.0 = "27.00768(2015-09-01 15:10)"
    # .1.3.6.1.4.1.12356.101.4.2.2.0 = "6.00689(2015-09-01 00:15)"
    # .1.3.6.1.4.1.12356.101.4.2.3.0 = ...
    # .1.3.6.1.4.1.12356.101.4.2.4.0 = ...
    
    oids_map = {}
    for line in res.stdout.splitlines():
        if line.find("=") == -1:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        if value.startswith("\"") and value.endswith("\""):
            value = value[1:-1]
        
        # Extract the number after .1.3.6.1.4.1.12356.101.4.2.
        if oid.startswith(".1.3.6.1.4.1.12356.101.4.2."):
            suffix = oid[32:]  # Get the last part after base OID
            if suffix == "1.0":
                oids_map["av_age"] = value
            elif suffix == "2.0":
                oids_map["ips_age"] = value
            elif suffix == "3.0":
                oids_map["av_ext_age"] = value
            elif suffix == "4.0":
                oids_map["ips_ext_age"] = value
    
    # Process each signature type
    state = "OK"
    details_lines = []
    metrics = {}
    
    for key in ["av_age", "ips_age", "av_ext_age", "ips_ext_age"]:
        value = oids_map.get(key)
        if value == None or value == "":
            continue
        
        version, age = _parse_version(value)
        if age == None:
            continue
        
        # Get levels for this key
        levels = params.get(key)
        if levels == None:
            default = DEFAULT_LEVELS.get(key, (86400, 172800))
            warn, crit = default
        else:
            # Checkmk uses tuple[int, int] or None for each level
            warn, crit = levels[0] if levels[0] != None else None, levels[1] if levels[1] != None else None
        
        # Determine state based on age
        if age < 0:
            # Future age - system time issue
            summary = "The age of the signature appears to be %f seconds. Since this is in the future you should check your system time." % age
            msg_part = "[Future time]"
            details_lines.append(summary)
            if state == "OK":
                state = "WARN"
            continue
        
        # Apply levels
        if crit != None and age >= crit:
            msg_part = "[%s] %s age: %f seconds (warn at %f, crit at %f)" % (
                version, FORTIGATE_KEY_TO_TITLE_MAP[key], age,
                warn if warn != None else 0, crit)
            details_lines.append("%s age: %f seconds (warn at %f, crit at %f)" % (
                FORTIGATE_KEY_TO_TITLE_MAP[key], age,
                warn if warn != None else 0, crit))
            state = "CRIT"
            metrics[key] = age
        elif warn != None and age >= warn:
            msg_part = "[%s] %s age: %f seconds (warn at %f)" % (
                version, FORTIGATE_KEY_TO_TITLE_MAP[key], age, warn)
            details_lines.append("%s age: %f seconds (warn at %f)" % (
                FORTIGATE_KEY_TO_TITLE_MAP[key], age, warn))
            if state == "OK":
                state = "WARN"
            metrics[key] = age
        else:
            # OK state
            msg_part = "[%s] %s age: %f seconds" % (version, FORTIGATE_KEY_TO_TITLE_MAP[key], age)
            if state == "OK":
                details_lines.append("%s age: %f seconds" % (FORTIGATE_KEY_TO_TITLE_MAP[key], age))
            metrics[key] = age
    
    # Build message
    if state == "OK":
        msg = "All signature ages within limits"
    elif state == "WARN":
        msg = "Some signature ages approaching limits"
    else:  # CRIT
        msg = "Some signature ages exceed limits"
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": "; ".join(details_lines)}}
