def main(ctx, params):
    # Discovery mode: single-service check, always yields exactly one Service
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.534.1.6"
        
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout.strip():
            return {"changed": False, "msg": "no SNMP data available",
                    "data": {"discovery": []}}
        
        lines = res.stdout.strip().split("\n")
        values = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value_str = parts[1].strip()
            last_part = oid_full.rsplit(".", 1)[-1]
            if last_part in ("1", "5", "6"):
                if ":" in value_str:
                    value_str = value_str.split(":", 1)[1].strip()
                # Guard instead of try/except: check if numeric
                if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
                    values[last_part] = int(value_str)
        
        if len(values) == 3 and "1" in values and "5" in values and "6" in values:
            return {"changed": False, "msg": "discovered environment service",
                    "data": {"discovery": [{
                        "item": "",
                        "params": {
                            "temp": params.get("temp", (40, 50)),
                            "remote_temp": params.get("remote_temp", (40, 50)),
                            "humidity": params.get("humidity", (65, 80)),
                        },
                        "metrics": ["temp", "remote_temp", "humidity"]
                    }]}
                    }
        else:
            return {"changed": False, "msg": "incomplete SNMP data",
                    "data": {"discovery": []}}
    
    # Check mode: single service (item == "")
    temp_raw = params.get("temp")
    remote_temp_raw = params.get("remote_temp")
    humidity_raw = params.get("humidity")
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res_temp = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.534.1.6.1"
    ], mutates=False)
    
    res_remote = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.534.1.6.5"
    ], mutates=False)
    
    res_hum = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.534.1.6.6"
    ], mutates=False)
    
    def parse_snmp_value(res):
        if res.rc != 0 or not res.stdout.strip():
            return None
        line = res.stdout.strip()
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            return None
        value_str = parts[1].strip()
        if ":" in value_str:
            value_str = value_str.split(":", 1)[1].strip()
        if value_str.isdigit() or (value_str.startswith("-") and value_str[1:].isdigit()):
            return int(value_str)
        return None
    
    temp = parse_snmp_value(res_temp)
    remote_temp = parse_snmp_value(res_remote)
    humidity = parse_snmp_value(res_hum)
    
    if temp == None or remote_temp == None or humidity == None:
        return {
            "changed": False,
            "msg": "unable to retrieve all environment values",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }
    
    def apply_levels(value, levels_tuple):
        if levels_tuple == None:
            return "OK"
        warn, crit = levels_tuple
        if value >= crit:
            return "CRIT"
        if value >= warn:
            return "WARN"
        return "OK"
    
    state_temp = apply_levels(temp, temp_raw)
    state_remote = apply_levels(remote_temp, remote_temp_raw)
    state_humidity = apply_levels(humidity, humidity_raw)
    
    if state_temp == "CRIT" or state_remote == "CRIT" or state_humidity == "CRIT":
        overall_state = "CRIT"
    elif state_temp == "WARN" or state_remote == "WARN" or state_humidity == "WARN":
        overall_state = "WARN"
    else:
        overall_state = "OK"
    
    msg_parts = [
        "Temperature: %d C" % temp,
        "Remote-Temperature: %d C" % remote_temp,
        "Humidity: %d %%" % humidity
    ]
    if overall_state != "OK":
        msg_parts.append("Status: " + overall_state)
    msg = ", ".join(msg_parts)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": overall_state,
            "metrics": {
                "temp": temp,
                "remote_temp": remote_temp,
                "humidity": humidity
            },
            "details": ""
        }
    }