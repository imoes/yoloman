# ===== Starlark check module: liebert_maintenance =====

# Constants for SNMP OIDs
_BASE_OID = ".1.3.6.1.4.1.476.1.42.3.9.20.1"
_OID_MONTH_NAME = ".10.1.2.1.4868"
_OID_MONTH_VALUE = ".20.1.2.1.4868"
_OID_YEAR_NAME = ".10.1.2.1.4869"
_OID_YEAR_VALUE = ".20.1.2.1.4869"

# Default threshold levels (days)
_DEFAULT_WARN_DAYS = 10
_DEFAULT_CRIT_DAYS = 5

# Helper to parse integer safely
def _parse_int(s):
    return int(s) if s.isdigit() or (len(s) > 1 and s[0] == "-" and s[1:].isdigit()) else None

def main(ctx, params):
    # Check discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            _BASE_OID
        ], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        # Parse output: look for month/year maintenance fields
        month_found = False
        year_found = False
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            # Format: OID = STRING: "value"
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            value = value_part.strip()
            if value.startswith("STRING:"):
                value = value[7:].strip().strip('"')
            elif value.startswith("INTEGER:"):
                value = value[8:].strip()
            else:
                continue
            
            # Check if this is a month or year name OID
            if oid_part == _OID_MONTH_NAME and "month" in value.lower():
                month_found = True
            elif oid_part == _OID_YEAR_NAME and "year" in value.lower():
                year_found = True
        
        # Discover service if both fields exist
        if month_found and year_found:
            return {
                "changed": False,
                "msg": "discovered Maintenance service",
                "data": {"discovery": [
                    {"item": "", "params": {"levels": [_DEFAULT_WARN_DAYS, _DEFAULT_CRIT_DAYS]}, "metrics": ["time_left_days"]}
                ]}
            }
        else:
            return {
                "changed": False,
                "msg": "no maintenance fields found",
                "data": {"discovery": []}
            }

    # Check mode
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Fetch both month and year values
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        _OID_MONTH_VALUE, _OID_YEAR_VALUE
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP get failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "SNMP query failed"}
        }
    
    # Parse values from output
    month = None
    year = None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Format: OID = INTEGER: value
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        value = value_part.strip()
        if value.startswith("INTEGER:"):
            value = value[8:].strip()
        
        parsed = _parse_int(value)
        if parsed != None:
            if oid_part == _OID_MONTH_VALUE:
                month = parsed
            elif oid_part == _OID_YEAR_VALUE:
                year = parsed
    
    if month == None or year == None:
        return {
            "changed": False,
            "msg": "maintenance fields missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Could not read month/year values"}
        }
    
    # Get current time (seconds since epoch)
    res = ctx.run(["date", "+%s"], mutates=False)
    current_time = 0
    if res.rc == 0 and res.stdout.strip().isdigit():
        current_time = int(res.stdout.strip())
    
    # Approximate calculation: days since 1970 to maintenance date
    days_until = (year - 1970) * 365.25 + (month - 1) * 30.44
    maintenance_seconds = days_until * 86400
    time_left_seconds = maintenance_seconds - current_time
    
    # Get thresholds
    levels = params.get("levels", [_DEFAULT_WARN_DAYS, _DEFAULT_CRIT_DAYS])
    warn_days = levels[0]
    crit_days = levels[1]
    warn_seconds = warn_days * 86400
    crit_seconds = crit_days * 86400
    
    # Determine state based on lower levels (time remaining)
    state = "OK"
    if time_left_seconds <= crit_seconds:
        state = "CRIT"
    elif time_left_seconds <= warn_seconds:
        state = "WARN"
    
    # Calculate remaining days
    remaining_days = int(time_left_seconds / 86400)
    days_text = str(int(days_until))
    
    msg = "Next maintenance: %d/%d" % (year, month)
    if remaining_days >= 0:
        msg = msg + ", %d days left" % remaining_days
    else:
        msg = msg + ", %d days overdue" % (-remaining_days)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"time_left_days": float(time_left_seconds) / 86400.0},
            "details": ""
        }
    }