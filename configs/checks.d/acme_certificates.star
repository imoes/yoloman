# Metric name used in Checkmk
METRIC_NAME = "certificate_expiration_time"

# Default thresholds (seconds): 1 week, 30 days
DEFAULT_WARN = 604800.0
DEFAULT_CRIT = 2592000.0

# Base OID for ACME certificates
BASE_OID = ".1.3.6.1.4.1.9148.3.9.1.10.1"

# OIDs in order: name(3), start(5), expire(6), issuer(7)
OID_NAME = BASE_OID + ".3"
OID_START = BASE_OID + ".5"
OID_EXPIRE = BASE_OID + ".6"
OID_ISSUER = BASE_OID + ".7"

# Detection OID: systemOID begins with .1.3.6.1.4.1.9148
DETECT_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_PREFIX = ".1.3.6.1.4.1.9148"

def _parse_snmp_value(value_str):
    """Parse a raw SNMP string value, stripping whitespace and quotes if any."""
    if value_str == None:
        return ""
    s = value_str.strip()
    # Strip surrounding quotes if present (some agents quote strings)
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return s

def _snmp_to_dict(lines):
    """Parse snmpwalk output lines into a dict mapping item names to (start, expire, issuer)."""
    cert_data = {}  # index -> {"name": "", "start": "", "expire": "", "issuer": ""}
    
    for line in lines.splitlines():
        line = line.strip()
        if not line:
            continue
        # Split into OID and value parts
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid, value = parts
        value = value.strip()
        # Extract field type and index
        fields = oid.split('.')
        if len(fields) < 6:
            continue
        
        # Last field is the OID leaf (3,5,6,7); second last is index
        leaf = fields[-1]
        index = fields[-2]
        
        # Determine field type
        field_type = None
        if leaf == "3":
            field_type = "name"
        elif leaf == "5":
            field_type = "start"
        elif leaf == "6":
            field_type = "expire"
        elif leaf == "7":
            field_type = "issuer"
        else:
            continue
        
        # Extract value string after "STRING: "
        val_str = ""
        if value.startswith("STRING: "):
            val_str = value[8:]
        else:
            val_str = value
        
        # Initialize index if needed
        if index not in cert_data:
            cert_data[index] = {"name": "", "start": "", "expire": "", "issuer": ""}
        
        cert_data[index][field_type] = _parse_snmp_value(val_str)
    
    # Convert to final dict: name -> (start, expire, issuer)
    result = {}
    for idx, data in cert_data.items():
        name = data.get("name")
        if name != "" and data.get("expire") != "":
            result[name] = (data["start"], data["expire"], data["issuer"])
    return result

def _convert_date_to_epoch(year, month, day, hour, minute, second):
    """Convert date/time components to epoch seconds (approximate, UTC)."""
    # Days since epoch (1970-01-01)
    y = year - 1
    days = y * 365 + y // 4 - y // 100 + y // 400
    
    # Month days offset (for non-leap year)
    month_days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
    days = days + month_days[month - 1] + day - 1
    
    # Leap year adjustment if after February
    is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
    if is_leap and month > 2:
        days = days + 1
    
    total_seconds = days * 86400 + hour * 3600 + minute * 60 + second
    return total_seconds

def main(ctx, params):
    if params.get("_discover") == True:
        # Discovery mode: walk SNMP and enumerate all certificate items
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), BASE_OID], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        certs = _snmp_to_dict(res.stdout)
        if not certs:
            return {"changed": False, "msg": "discovered 0 certificates",
                    "data": {"discovery": []}}
        items = []
        for name in certs:
            items.append({"item": name, "params": {"expire_lower": ("fixed", (DEFAULT_WARN, DEFAULT_CRIT))},
                          "metrics": [METRIC_NAME]})
        return {"changed": False, "msg": "discovered %d certificates" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: examine one certificate item
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")
    
    # Walk SNMP data (same as discovery)
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), BASE_OID], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)
    
    certs = _snmp_to_dict(res.stdout)
    if item not in certs:
        return {"changed": False, "msg": "certificate '%s' not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    start_str, expire_str, issuer = certs[item]
    
    # Parse expiration date: "Jul 25 00:33:17 2003 GMT" -> components
    expire_parts = expire_str.rsplit(" ", 1)
    if len(expire_parts) != 2:
        return {"changed": False, "msg": "failed to parse expiration date: " + expire_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    expire_date = expire_parts[0]
    
    # Format: "%b %d %H:%M:%S %Y" -> e.g. "Jul 25 00:33:17 2003"
    date_parts = expire_date.split(" ")
    if len(date_parts) != 5:
        return {"changed": False, "msg": "failed to parse expiration date format: " + expire_date,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    months = {
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
    }
    month_str = date_parts[0]
    day_str = date_parts[1]
    time_str = date_parts[2] + " " + date_parts[3]
    year_str = date_parts[4]
    
    if month_str not in months:
        return {"changed": False, "msg": "failed to parse expiration date month: " + month_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    month = months[month_str]
    day = int(day_str) if day_str.isdigit() else 0
    year = int(year_str) if year_str.isdigit() else 0
    
    time_parts = time_str.split(":")
    if len(time_parts) != 3:
        return {"changed": False, "msg": "failed to parse expiration time: " + time_str,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    hour = int(time_parts[0]) if time_parts[0].isdigit() else 0
    minute = int(time_parts[1]) if time_parts[1].isdigit() else 0
    second = int(time_parts[2]) if time_parts[2].isdigit() else 0
    
    # Convert to epoch (UTC)
    expire_epoch = _convert_date_to_epoch(year, month, day, hour, minute, second)
    
    # Current time (in seconds since epoch)
    now_epoch = ctx.run(["date", "+%s"], mutates=False).stdout.strip()
    now_epoch = int(now_epoch) if now_epoch.isdigit() else 0
    
    time_diff = expire_epoch - now_epoch
    
    # Extract thresholds (from Checkmk params: "expire_lower": ("fixed", (warn, crit)))
    expire_lower = params.get("expire_lower", ("fixed", (DEFAULT_WARN, DEFAULT_CRIT)))
    warn, crit = expire_lower[1]  # ("fixed", (warn, crit)) -> (warn, crit)
    
    # Determine state: lower levels -> CRIT if <= crit, WARN if <= warn
    state = "CRIT" if time_diff <= crit else ("WARN" if time_diff <= warn else "OK")
    
    # Format human-readable message
    def render_timespan(seconds):
        if seconds < 0:
            return "expired %f seconds ago" % abs(seconds)
        days = int(seconds // 86400)
        hours = int((seconds % 86400) // 3600)
        minutes = int((seconds % 3600) // 60)
        parts = []
        if days > 0:
            parts.append("%d day%s" % (days, "" if days == 1 else "s"))
        if hours > 0:
            parts.append("%d hour%s" % (hours, "" if hours == 1 else "s"))
        if minutes > 0:
            parts.append("%d minute%s" % (minutes, "" if minutes == 1 else "s"))
        if not parts:
            return "%f seconds" % seconds
        return ", ".join(parts)
    
    msg = "%s: %s" % (item, render_timespan(time_diff))
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {METRIC_NAME: time_diff},
            "details": ""
        },
    }