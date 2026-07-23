# ===== brocade_sys_mem starlark check module =====
# Memory usage check for Brocade devices via SNMP
# Discovery: one single-service entry; check: memory utilization with configurable levels

# Module-level constants
SNMP_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.26"
OID_CPU_UTIL = "1"
OID_MEM_USED = "6"

def main(ctx, params):
    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")

        # Fetch both OIDs in one walk (base + specific OID suffix)
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            SNMP_BASE + "." + OID_MEM_USED
        ], mutates=False)

        # If we got any output, there's a Brocade system and memory data exists
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no data (SNMP error or no Brocade device)",
                    "data": {"discovery": []}}

        # Single-service check: always discover one service
        return {
            "changed": False,
            "msg": "discovered 1 services",
            "data": {"discovery": [{"item": "", "params": {"levels": None},
                                   "metrics": ["mem_used_percent"]}]}
        }

    # ===== CHECK MODE (item is always "" for this single-service check) =====
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("levels", None)  # Checkmk default: None

    # Fetch memory usage OID
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host,
        SNMP_BASE + "." + OID_MEM_USED
    ], mutates=False)

    # Parse SNMP output: "OID = INTEGER: value"
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP error or no data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract value from line like: .1.3.6.1.4.1.1588.2.1.1.1.26.6 = INTEGER: 45
    line = res.stdout.strip()
    value_str = None
    if " = " in line:
        value_part = line.split(" = ", 1)[1]
        if value_part.startswith("INTEGER:"):
            val = value_part.split(":", 1)[1].strip()
            if val.isdigit():
                value_str = int(val)

    if value_str == None:
        return {
            "changed": False,
            "msg": "could not parse memory value from SNMP output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply levels
    state = "OK"
    if levels != None:
        warn, crit = levels
        if value_str >= crit:
            state = "CRIT"
        elif value_str >= warn:
            state = "WARN"

    return {
        "changed": False,
        "msg": "Memory: %d%%" % value_str,
        "data": {
            "state": state,
            "metrics": {"mem_used_percent": value_str},
            "details": ""
        }
    }
