# Constants for SNMP OIDs
_BINTEC_CPU_BASE = ".1.3.6.1.4.1.272.4.17.4.1.1"
_OID_USER = _BINTEC_CPU_BASE + ".15"
_OID_SYSTEM = _BINTEC_CPU_BASE + ".16"
_OID_STREAMS = _BINTEC_CPU_BASE + ".17"

def _parse_snmp_output(stdout):
    """Parse snmpwalk output lines like '.1.3.6.1.4.1.272.4.17.4.1.1.15.1.0 = INTEGER: 5' -> ['5', '1', '9']"""
    values = {}
    for line in stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        if line.find("=") == -1:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract last numeric segment after last dot to identify OID index
        # We only expect index .1.0 at the end per the original OIDs
        if oid_part.endswith(".1.0"):
            oid_prefix = oid_part[:-len(".1.0")]
            # Map prefixes to keys
            if oid_prefix == _OID_USER:
                values["user"] = value_part
            elif oid_prefix == _OID_SYSTEM:
                values["system"] = value_part
            elif oid_prefix == _OID_STREAMS:
                values["streams"] = value_part
    return values

def main(ctx, params):
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    if params.get("_discover"):
        # Discover mode: check if we can retrieve any CPU data
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, _BINTEC_CPU_BASE
        ], mutates=False)
        # If we got any output lines, we have a service
        if res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["user", "system", "streams"]}
                ]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 services",
            "data": {"discovery": []},
        }
    
    # Check mode: get CPU values via snmpget (single OID queries for speed)
    # Since we expect exactly one instance, fetch each OID individually
    user_val = "0"
    system_val = "0"
    streams_val = "0"
    
    # User CPU
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, _OID_USER + ".1.0"
    ], mutates=False)
    if res.rc == 0 and res.stdout.strip().find("=") != -1:
        user_val = res.stdout.strip().split(":", 1)[1].strip()
    
    # System CPU
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, _OID_SYSTEM + ".1.0"
    ], mutates=False)
    if res.rc == 0 and res.stdout.strip().find("=") != -1:
        system_val = res.stdout.strip().split(":", 1)[1].strip()
    
    # Streams CPU
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On",
        host, _OID_STREAMS + ".1.0"
    ], mutates=False)
    if res.rc == 0 and res.stdout.strip().find("=") != -1:
        streams_val = res.stdout.strip().split(":", 1)[1].strip()
    
    # Validate values are numeric strings
    if user_val == "" or system_val == "" or streams_val == "":
        return {
            "changed": False,
            "msg": "invalid snmp values",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Guard before parsing to ensure valid numeric values
    user = float(user_val) if user_val.replace(".", "", 1).isdigit() or (user_val.startswith("-") and user_val[1:].replace(".", "", 1).isdigit()) else 0.0
    system = float(system_val) if system_val.replace(".", "", 1).isdigit() or (system_val.startswith("-") and system_val[1:].replace(".", "", 1).isdigit()) else 0.0
    streams = float(streams_val) if streams_val.replace(".", "", 1).isdigit() or (streams_val.startswith("-") and streams_val[1:].replace(".", "", 1).isdigit()) else 0.0
    
    util = user + system + streams
    
    # Default thresholds (Checkmk uses cpu_utilization_os rule)
    warn = params.get("levels", [80.0, 90.0])
    if type(warn) == "list" and len(warn) == 2:
        warn_val = warn[0]
        crit_val = warn[1]
    else:
        warn_val = 80.0
        crit_val = 90.0
    
    # Determine state
    if util >= crit_val:
        state = "CRIT"
    elif util >= warn_val:
        state = "WARN"
    else:
        state = "OK"
    
    # Build message
    msg = "user: %f%%, system: %f%%, streams: %f%%, total: %f%%" % (user, system, streams, util)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"user": user, "system": system, "streams": streams, "util": util},
            "details": "",
        },
    }
