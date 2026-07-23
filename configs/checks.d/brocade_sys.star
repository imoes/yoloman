def main(ctx, params):
    # Constants for SNMP OIDs
    SNMP_BASE = ".1.3.6.1.4.1.1588.2.1.1.1.26"
    OID_CPU_UTIL = "1"
    OID_MEM_USED = "6"
    OID_SYS_OID = ".1.3.6.1.2.1.1.2.0"
    BROCADE_SYS_OID = ".1.3.6.1.4.1.1588.2.1.1"
    # Additional OIDs for detection
    BROCADE_FABRIC_OID = ".1.3.6.1.4.1.1916.2.306"

    # Helper: discover if brocade_sys section applies
    def detect_brocade():
        sys_oid_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                               "-On", params.get("host", "localhost"), OID_SYS_OID], mutates=False)
        if sys_oid_res.rc != 0:
            return False
        # Parse output: "<oid> = STRING: <value>" or similar
        line = sys_oid_res.stdout.strip()
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            return False
        sys_oid_value = parts[1].strip()
        # Check if sys OID starts with brocade OIDs
        return sys_oid_value.startswith(BROCADE_SYS_OID) or sys_oid_value == BROCADE_FABRIC_OID

    # Helper: get snmp values as list
    def get_snmp_values(oids):
        # Build full OIDs list
        full_oids = [SNMP_BASE + "." + oid for oid in oids]
        # Use snmpwalk for multiple OIDs; filter output
        res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost")] + full_oids, mutates=False)
        if res.rc != 0:
            return None
        values = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            # Format: "oid.1 = INTEGER: 123" or similar
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            value_part = parts[1].strip()
            # Extract last numeric segment
            suffix = oid_part.rsplit(".", 1)[-1] if "." in oid_part else oid_part
            if suffix == OID_CPU_UTIL:
                values["cpu"] = value_part
            elif suffix == OID_MEM_USED:
                values["mem"] = value_part
        return values if values else None

    # Discovery mode
    if params.get("_discover"):
        if not detect_brocade():
            return {"changed": False, "msg": "no brocade system data",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 2 services",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["cpu_util"]},
                    {"item": "", "params": {"levels": None}, "metrics": ["mem_used_percent"]}
                ]}}

    # Check mode
    item = params.get("item", "")
    # Detect section existence first
    if not detect_brocade():
        return {"changed": False, "msg": "no brocade system data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    values = get_snmp_values([OID_CPU_UTIL, OID_MEM_USED])
    if values == None:
        return {"changed": False, "msg": "snmp query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Extract values
    cpu_str = values.get("cpu", "")
    mem_str = values.get("mem", "")
    if not cpu_str.isdigit() or not mem_str.isdigit():
        return {"changed": False, "msg": "invalid snmp value format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cpu_util = int(cpu_str)
    mem_used = int(mem_str)

    if item == "" or item == "CPU utilization":
        # CPU check
        levels = params.get("levels", (None, None))
        warn, crit = levels if levels else (None, None)
        state = "OK"
        if crit != None and cpu_util >= crit:
            state = "CRIT"
        elif warn != None and cpu_util >= warn:
            state = "WARN"
        msg = "CPU utilization: %d%%" % cpu_util
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"cpu_util": cpu_util}, "details": ""}}

    if item == "Memory":
        # Memory check
        levels = params.get("levels", None)
        state = "OK"
        if levels != None:
            if levels >= 0 and mem_used >= levels:
                state = "CRIT"
            elif levels >= 0 and mem_used >= levels * 0.8:  # Approximate Checkmk default
                # But per Checkmk spec, levels is fixed tuple (warn, crit) or single value
                # We interpret levels as upper bound for CRIT, and warn = levels * 0.8 if not set
                # However source uses levels directly: levels_upper=("fixed", levels)
                # So warn/crit both use same value (levels is a single number or None)
                if levels >= 0:
                    crit_val = levels
                    warn_val = levels
                    if mem_used >= crit_val:
                        state = "CRIT"
                    elif mem_used >= warn_val:
                        state = "WARN"
        msg = "Memory: %d%% used" % mem_used
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {"mem_used_percent": mem_used}, "details": ""}}

    # Unknown item
    return {"changed": False, "msg": "unknown item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
