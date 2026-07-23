# Module-level constants
SNMP_BASE_ALCATEL = ".1.3.6.1.4.1.6486.800.1.2.1.16.1.1.1"
SNMP_BASE_ALCATEL_AOS7 = ".1.3.6.1.4.1.6486.801.1.2.1.16.1.1.1.1.1"
SNMP_OID_CPU = "13"
SNMP_OID_AOS7_CPU = "15"
DETECT_ALCATEL_OID = ".1.3.6.1.2.1.1.2.0"
DETECT_ALCATEL_PREFIX = ".1.3.6.1.4.1.6486.800"
DETECT_ALCATEL_AOS7_PREFIX = ".1.3.6.1.4.1.6486.801"

# Default thresholds (from Checkmk source: levels_upper=("fixed", (90.0, 95.0)))
DEFAULT_WARN = 90.0
DEFAULT_CRIT = 95.0


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Get system OID to determine device type
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), DETECT_ALCATEL_OID],
                      mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items (SNMP error)",
                "data": {"discovery": []}
            }
        
        # Check if Alcatel or Alcatel AOS7
        sys_oid = res.stdout.strip()
        if sys_oid.endswith(DETECT_ALCATEL_PREFIX):
            base_oid = SNMP_BASE_ALCATEL
        elif sys_oid.endswith(DETECT_ALCATEL_AOS7_PREFIX):
            base_oid = SNMP_BASE_ALCATEL_AOS7
        else:
            return {
                "changed": False,
                "msg": "discovered 0 items (not an Alcatel device)",
                "data": {"discovery": []}
            }
        
        # Get CPU utilization
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"),
                       base_oid + "." + (SNMP_OID_AOS7_CPU if base_oid == SNMP_BASE_ALCATEL_AOS7 else SNMP_OID_CPU)],
                      mutates=False)
        
        if res.rc != 0 or "=" not in res.stdout:
            return {
                "changed": False,
                "msg": "discovered 0 items (CPU OID not available)",
                "data": {"discovery": []}
            }
        
        # Parse value: "OID = INTEGER: <value>"
        parts = res.stdout.strip().split("=")
        if len(parts) < 2:
            return {
                "changed": False,
                "msg": "discovered 0 items (malformed response)",
                "data": {"discovery": []}
            }
        
        value_str = parts[1].strip()
        
        # Guard before parsing
        colon_idx = value_str.find(":")
        if colon_idx >= 0:
            value_str = value_str[colon_idx+1:].strip()
        
        # Check if string contains only digits before converting
        i = 0
        valid = True
        while i < len(value_str):
            if not (value_str[i] == " " or value_str[i] == "\t" or
                    value_str[i] == "\n" or value_str[i] == "\r" or
                    ("0" <= value_str[i] and value_str[i] <= "9")):
                valid = False
                break
            i = i + 1
        
        if not valid or value_str == "":
            return {
                "changed": False,
                "msg": "discovered 0 items (invalid CPU value)",
                "data": {"discovery": []}
            }
        
        cpu_util = int(value_str)
        
        # Single service check: one entry with empty item
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [{
                    "item": "",
                    "params": {"warn": DEFAULT_WARN, "crit": DEFAULT_CRIT},
                    "metrics": ["util"]
                }]
            }
        }
    
    # Check mode (normal path)
    warn = params.get("warn", DEFAULT_WARN)
    crit = params.get("crit", DEFAULT_CRIT)
    
    # Determine which device type based on discovery data or use fallback logic
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"), DETECT_ALCATEL_OID],
                  mutates=False)
    
    if res.rc != 0 or "=" not in res.stdout:
        return {
            "changed": False,
            "msg": "SNMP error retrieving system OID",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    sys_oid = res.stdout.strip()
    if sys_oid.endswith(DETECT_ALCATEL_PREFIX):
        base_oid = SNMP_BASE_ALCATEL
        oid_cpu = SNMP_OID_CPU
    elif sys_oid.endswith(DETECT_ALCATEL_AOS7_PREFIX):
        base_oid = SNMP_BASE_ALCATEL_AOS7
        oid_cpu = SNMP_OID_AOS7_CPU
    else:
        return {
            "changed": False,
            "msg": "not an Alcatel device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get CPU utilization
    res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   base_oid + "." + oid_cpu],
                  mutates=False)
    
    if res.rc != 0 or "=" not in res.stdout:
        return {
            "changed": False,
            "msg": "CPU utilization data unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse value: "OID = INTEGER: <value>"
    parts = res.stdout.strip().split("=")
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "malformed SNMP response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value_str = parts[1].strip()
    
    # Guard before parsing
    colon_idx = value_str.find(":")
    if colon_idx >= 0:
        value_str = value_str[colon_idx+1:].strip()
    
    # Check if string contains only digits before converting
    i = 0
    valid = True
    while i < len(value_str):
        if not (value_str[i] == " " or value_str[i] == "\t" or
                value_str[i] == "\n" or value_str[i] == "\r" or
                ("0" <= value_str[i] and value_str[i] <= "9")):
            valid = False
            break
        i = i + 1
    
    if not valid or value_str == "":
        return {
            "changed": False,
            "msg": "invalid CPU value format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    cpu_util = int(value_str)
    
    # Determine state based on thresholds (fixed upper levels from Checkmk source)
    state = "CRIT" if cpu_util >= crit else ("WARN" if cpu_util >= warn else "OK")
    
    return {
        "changed": False,
        "msg": "Total: %d%%" % cpu_util,
        "data": {
            "state": state,
            "metrics": {"util": cpu_util},
            "details": ""
        }
    }
