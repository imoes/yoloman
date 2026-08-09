# hepta_syncmoduletimesyncstate starlark check module
# Reads SNMP data from Hopf hepta GPS devices via SNMPv2

# OID constants for hepta section (base .1.3.6.1.4.1.12527.29 or .1.3.6.1.4.1.12527.40)
_HEPTA_BASE_OID = ".1.3.6.1.4.1.12527"
_HEPTA_DEVICETYPE_OID = _HEPTA_BASE_OID + ".29.1.1.0"
_HEPTA_SERIALNUMBER_OID = _HEPTA_BASE_OID + ".29.1.3.0"
_HEPTA_FIRMWAREVERSION_OID = _HEPTA_BASE_OID + ".29.1.4.0"
_HEPTA_FIRMWAREDATE_OID = _HEPTA_BASE_OID + ".29.1.5.0"
_HEPTA_VERSION_OID = _HEPTA_BASE_OID + ".29.1.6.0"
_HEPTA_NTP_STRATUM_OID = _HEPTA_BASE_OID + ".29.2.1.2.0"
_HEPTA_LOCALTIME_OID = _HEPTA_BASE_OID + ".29.3.1.0"
_HEPTA_SYNCTIMESTATE_OID = _HEPTA_BASE_OID + ".29.3.5.0"

# Alternative base OID for hepta40 devices
_HEPTA40_DEVICETYPE_OID = _HEPTA_BASE_OID + ".40.1.1.0"
_HEPTA40_SERIALNUMBER_OID = _HEPTA_BASE_OID + ".40.1.3.0"
_HEPTA40_FIRMWAREVERSION_OID = _HEPTA_BASE_OID + ".40.1.4.0"
_HEPTA40_FIRMWAREDATE_OID = _HEPTA_BASE_OID + ".40.1.5.0"
_HEPTA40_VERSION_OID = _HEPTA_BASE_OID + ".40.1.6.0"
_HEPTA40_NTP_STRATUM_OID = _HEPTA_BASE_OID + ".40.2.1.2.0"
_HEPTA40_LOCALTIME_OID = _HEPTA_BASE_OID + ".40.3.1.0"
_HEPTA40_SYNCTIMESTATE_OID = _HEPTA_BASE_OID + ".40.3.5.0"

def _parse_time(time_str):
    """Parse Hopf hepta time string (8 or 11 bytes encoded as latin-1) to readable format"""
    length = len(time_str)
    if length == 0:
        return ""
    
    # For 8-byte format: year high, year low, month, day, hour, min, sec, ms (2 bytes)
    # For 11-byte format: 8 bytes above + offset: sign, hours, minutes
    if length < 8:
        return ""
    
    # Convert string to bytes (latin-1 encoding) - simple implementation
    time_bytes = []
    i = 0
    while i < len(time_str):
        # Get character code manually
        c = time_str[i]
        code = ord(c) if c != None else 0
        time_bytes.append(code)
        i = i + 1
    
    if len(time_bytes) < 8:
        return ""
    
    # Extract year (big-endian: high byte first)
    year_high = time_bytes[0]
    year_low = time_bytes[1]
    year = year_high * 256 + year_low
    
    month = time_bytes[2]
    day = time_bytes[3]
    hour = time_bytes[4]
    minute = time_bytes[5]
    second = time_bytes[6]
    
    # For 8-byte format
    if length == 8:
        return "%d-%d-%d %d:%d:%d" % (day, month, year, hour, minute, second)
    elif length == 11:
        if len(time_bytes) < 10:
            return "%d-%d-%d %d:%d:%d" % (day, month, year, hour, minute, second)
        offset_sign = time_bytes[7]
        offset_hours = time_bytes[8]
        offset_minutes = time_bytes[9]
        
        if offset_sign == 0:
            offset_str = "+%d:%d" % (offset_hours, offset_minutes)
        else:
            offset_str = "-%d:%d" % (offset_hours, offset_minutes)
        return "%d-%d-%d %d:%d:%d %s" % (day, month, year, hour, minute, second, offset_str)
    else:
        # Fallback for unknown length
        return ""

def _get_snmp_value(ctx, host, community, oid):
    """Get a single SNMP value using snmpget"""
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    
    # Parse snmpget output: "OID = TYPE: value"
    lines = res.stdout.splitlines()
    if len(lines) == 0:
        return ""
    
    line = lines[0].strip()
    # Split on " = " to separate OID from value
    parts = line.split(" = ", 1)
    if len(parts) != 2:
        return ""
    
    # Extract value part (after the colon)
    value_part = parts[1].strip()
    colon_idx = value_part.find(":")
    if colon_idx >= 0:
        return value_part[colon_idx + 1:].strip()
    return value_part

def _get_hepta_section(ctx, host, community):
    """Fetch all hepta SNMP values"""
    # Try base 29 first, then fall back to base 40
    device_type_29 = _get_snmp_value(ctx, host, community, _HEPTA_DEVICETYPE_OID)
    
    if device_type_29 != "":
        return {
            "devicetype": device_type_29,
            "serialnumber": _get_snmp_value(ctx, host, community, _HEPTA_SERIALNUMBER_OID),
            "firmwareversion": _get_snmp_value(ctx, host, community, _HEPTA_FIRMWAREVERSION_OID),
            "firmwaredate": _parse_time(_get_snmp_value(ctx, host, community, _HEPTA_FIRMWAREDATE_OID)),
            "version": _get_snmp_value(ctx, host, community, _HEPTA_VERSION_OID),
            "ntpstratum": _get_snmp_value(ctx, host, community, _HEPTA_NTP_STRATUM_OID),
            "syncmoduletimesyncstate": _get_snmp_value(ctx, host, community, _HEPTA_SYNCTIMESTATE_OID),
            "syncmoduletimelocal": _parse_time(_get_snmp_value(ctx, host, community, _HEPTA_LOCALTIME_OID)),
        }
    else:
        # Fall back to base 40
        return {
            "devicetype": _get_snmp_value(ctx, host, community, _HEPTA40_DEVICETYPE_OID),
            "serialnumber": _get_snmp_value(ctx, host, community, _HEPTA40_SERIALNUMBER_OID),
            "firmwareversion": _get_snmp_value(ctx, host, community, _HEPTA40_FIRMWAREVERSION_OID),
            "firmwaredate": _parse_time(_get_snmp_value(ctx, host, community, _HEPTA40_FIRMWAREDATE_OID)),
            "version": _get_snmp_value(ctx, host, community, _HEPTA40_VERSION_OID),
            "ntpstratum": _get_snmp_value(ctx, host, community, _HEPTA40_NTP_STRATUM_OID),
            "syncmoduletimesyncstate": _get_snmp_value(ctx, host, community, _HEPTA40_SYNCTIMESTATE_OID),
            "syncmoduletimelocal": _parse_time(_get_snmp_value(ctx, host, community, _HEPTA40_LOCALTIME_OID)),
        }

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode: check for hepta device availability
    if params.get("_discover"):
        section = _get_hepta_section(ctx, host, community)
        if section != None and section.get("syncmoduletimesyncstate") != None:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "SyncModuleTimeSyncState", "params": {}, "metrics": []}
                ]}
            }
        else:
            return {
                "changed": False,
                "msg": "discovered 0 services",
                "data": {"discovery": []}
            }
    
    # Check mode: retrieve data and evaluate sync state
    section = _get_hepta_section(ctx, host, community)
    
    # Handle missing or invalid section
    if section == None or section.get("syncmoduletimesyncstate") == None or section.get("syncmoduletimesyncstate") == "":
        return {
            "changed": False,
            "msg": "No data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    sync_state = section.get("syncmoduletimesyncstate", "")
    
    # Evaluate sync state
    if sync_state == "R":
        state = "OK"
        summary = "Radio synchronous with high precision"
    elif sync_state == "r":
        state = "WARN"
        summary = "Radio synchronous with low precision"
    elif sync_state == "C":
        state = "CRIT"
        summary = "Crystal"
    elif sync_state == "I":
        state = "CRIT"
        summary = "Invalid time and date"
    else:
        state = "UNKNOWN"
        summary = "No data available"
    
    # Build details with additional information
    details = ""
    if section.get("devicetype"):
        details = "DeviceType %s; " % section.get("devicetype")
    if section.get("serialnumber"):
        details = details + "SerialNumber %s; " % section.get("serialnumber")
    if section.get("firmwareversion"):
        details = details + "FirmwareVersion %s; " % section.get("firmwareversion")
    if section.get("firmwaredate"):
        details = details + "FirmwareDate %s; " % section.get("firmwaredate")
    if section.get("version"):
        details = details + "Version %s; " % section.get("version")
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details.strip()
        }
    }