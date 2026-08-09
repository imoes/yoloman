# Module-level constants
DEFAULT_POWER_LEVELS = [5.0, 1.0]
BASE_OID = ".1.3.6.1.2.1.10.127.1.1.1.1"
OID_ID = BASE_OID + ".1"
OID_FREQ = BASE_OID + ".2"
OID_POWER = BASE_OID + ".6"

def _parse_snmp_output(stdout):
    """Parse snmpwalk output into list of [channel_id, frequency, power] strings."""
    result = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split(" = ")
        if len(parts) != 2:
            continue
        oid_full, value_part = parts
        if ":" in value_part:
            value = value_part.split(":", 1)[1].strip()
        else:
            value = value_part.strip()
        index = oid_full.rsplit(".", 1)[-1]
        if oid_full == OID_ID + "." + index:
            result.append([index, "", ""])
        elif oid_full == OID_FREQ + "." + index:
            found = False
            for item in result:
                if item[0] == index:
                    item[1] = value
                    found = True
                    break
            if not found:
                result.append([index, value, ""])
        elif oid_full == OID_POWER + "." + index:
            found = False
            for item in result:
                if item[0] == index:
                    item[2] = value
                    found = True
                    break
            if not found:
                result.append([index, "", value])
    return [item for item in result if len(item) == 3 and item[1] != "" and item[2] != ""]


def main(ctx, params):
    discover = params.get("_discover")
    
    if discover:
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, BASE_OID
        ], mutates=False)
        
        section = _parse_snmp_output(res.stdout)
        items = []
        for channel_id, frequency, power in section:
            if frequency != "0":
                items.append({
                    "item": channel_id,
                    "params": {
                        "power": list(DEFAULT_POWER_LEVELS),
                    },
                    "metrics": ["power", "frequency"]
                })
        return {
            "changed": False,
            "msg": "discovered %d downstream channels" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, BASE_OID
    ], mutates=False)
    
    section = _parse_snmp_output(res.stdout)
    
    for channel_id, frequency, power in section:
        if channel_id == item:
            # Guard for power parsing
            power_int = int(power) if power.isdigit() else 0
            power_dbmv = float(power_int) / 10.0
            
            power_levels = params.get("power", DEFAULT_POWER_LEVELS)
            warn_p = power_levels[0]
            crit_p = power_levels[1]
            
            state = "OK"
            infotext = "Power is %f dBmV" % power_dbmv
            
            if power_dbmv <= crit_p:
                state = "CRIT"
                infotext += " (Levels Warn/Crit at %f dBmV/ %f dBmV)" % (warn_p, crit_p)
            elif power_dbmv <= warn_p:
                state = "WARN"
                infotext += " (Levels Warn/Crit at %f dBmV/ %f dBmV)" % (warn_p, crit_p)
            
            # Guard for frequency parsing
            freq_int = int(frequency) if frequency.isdigit() else 0
            frequency_mhz = float(freq_int) / 1000000.0
            
            freq_info = "Frequency is %f MHz" % frequency_mhz
            freq_state = "OK"
            
            if "frequency" in params:
                freq_params = params.get("frequency")
                warn_f = freq_params[0] if type(freq_params) == "list" else 0
                crit_f = freq_params[1] if type(freq_params) == "list" else 0
                freq_levels = " (warn/crit at %f MHz/ %f MHz)" % (warn_f, crit_f)
                if frequency_mhz >= crit_f:
                    freq_state = "CRIT"
                    freq_info += freq_levels
                elif frequency_mhz >= warn_f:
                    freq_state = "WARN"
                    freq_info += freq_levels
            
            final_state = "CRIT" if state == "CRIT" or freq_state == "CRIT" else ("WARN" if state == "WARN" or freq_state == "WARN" else "OK")
            final_msg = infotext + ", " + freq_info
            
            return {
                "changed": False,
                "msg": final_msg,
                "data": {
                    "state": final_state,
                    "metrics": {
                        "power": power_dbmv,
                        "frequency": frequency_mhz
                    },
                    "details": ""
                }
            }
    
    return {
        "changed": False,
        "msg": "Channel information not found in SNMP data",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
    }
