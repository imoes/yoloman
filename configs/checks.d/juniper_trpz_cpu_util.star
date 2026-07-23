def main(ctx, params):
    # SNMP base OID for juniper_trpz_cpu_util section
    base_oid = ".1.3.6.1.4.1.14525.4.8.1.1.11"
    
    # Discovery mode: yield single service
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {"util": (80.0, 90.0)},
                        "metrics": ["utilc", "util1", "util5"]
                    }
                ]
            }
        }
    
    # Check mode: gather CPU utilization via SNMP
    # Fetch three OIDs using snmpget
    utilc_oid = base_oid + ".1"
    util1_oid = base_oid + ".2"
    util5_oid = base_oid + ".3"
    
    res_utilc = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), utilc_oid], mutates=False)
    res_util1 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), util1_oid], mutates=False)
    res_util5 = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), util5_oid], mutates=False)
    
    # Parse values safely using string methods (no try/except allowed)
    def parse_value(res):
        if res.rc != 0 or len(res.stdout.strip()) == 0:
            return None
        parts = res.stdout.strip().split(" = ")
        if len(parts) != 2:
            return None
        value_part = parts[1].strip()
        if value_part.startswith("INTEGER: "):
            val_str = value_part[9:].strip()
            if val_str.isdigit():
                return int(val_str)
            return None
        return None
    
    utilc_val = parse_value(res_utilc)
    util1_val = parse_value(res_util1)
    util5_val = parse_value(res_util5)
    
    # Determine state: UNKNOWN if any value missing
    if utilc_val == None or util1_val == None or util5_val == None:
        return {
            "changed": False,
            "msg": "CPU utilization data unavailable",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    # Thresholds from params (Checkmk defaults)
    warn, crit = params.get("util", (80.0, 90.0))
    
    # Helper to determine state for upper thresholds
    def state_for_upper(value, warn_level, crit_level):
        if value >= crit_level:
            return "CRIT"
        if value >= warn_level:
            return "WARN"
        return "OK"
    
    # Overall state is worst of the three
    state_c = state_for_upper(utilc_val, warn, crit)
    state_1 = state_for_upper(util1_val, warn, crit)
    state_5 = state_for_upper(util5_val, warn, crit)
    
    state = "CRIT" if state_c == "CRIT" or state_1 == "CRIT" or state_5 == "CRIT" else \
            "WARN" if state_c == "WARN" or state_1 == "WARN" or state_5 == "WARN" else "OK"
    
    # Message summarizing utilization
    msg = "Current: %d%%, 1min: %d%%, 5min: %d%%" % (utilc_val, util1_val, util5_val)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "utilc": utilc_val,
                "util1": util1_val,
                "util5": util5_val
            },
            "details": ""
        }
    }