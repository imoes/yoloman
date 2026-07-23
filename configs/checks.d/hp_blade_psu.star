_PRESENT_MAP = {1: "other", 2: "absent", 3: "present"}
_STATUS_MAP = {1: "other", 2: "Ok", 3: "Degraded", 4: "Failed"}
_PSU_STATUS = {
    1: "noError", 2: "generalFailure", 3: "bistFailure", 4: "fanFailure",
    5: "tempFailure", 6: "interlockOpen", 7: "epromFailed", 8: "vrefFailed",
    9: "dacFailed", 10: "ramTestFailed", 11: "voltageChannelFailed",
    12: "oringdiodeFailed", 13: "brownOut", 14: "giveupOnStartup",
    15: "nvramInvalid", 16: "calibrationTableInvalid"
}
_INPUTLINE_STATUS = {1: "noError", 2: "lineOverVoltage", 3: "lineUnderVoltage",
                     4: "lineHit", 5: "brownOut", 6: "linePowerLoss"}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            ".1.3.6.1.4.1.232.22.2.5.1.1.1.16"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            value = parts[1].strip()
            present = int(value) if value.isdigit() else 0
            if present == 3:
                oid_full = parts[0].strip()
                oid_parts = oid_full.rsplit(".", 1)
                if len(oid_parts) == 2:
                    item = oid_parts[1]
                    discovery.append({
                        "item": item,
                        "params": {},
                        "metrics": ["output"]
                    })
        return {"changed": False, "msg": "discovered %d PSUs" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        ".1.3.6.1.4.1.232.22.2.5.1.1.1"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    psus = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or " = " not in line:
            continue
        oid_full, value = line.split(" = ", 1)
        value = value.strip()
        
        if not oid_full.startswith(".1.3.6.1.4.1.232.22.2.5.1.1.1."):
            continue
        remainder = oid_full[len(".1.3.6.1.4.1.232.22.2.5.1.1.1."):]
        dot_idx = remainder.find(".")
        if dot_idx == -1:
            continue
        oid_num = remainder[:dot_idx]
        idx = remainder[dot_idx+1:]
        
        if idx not in psus:
            psus[idx] = {
                "index": "", "serial": "", "output": 0.0, "status": 0,
                "inputLine": 0, "present": 0
            }
        if oid_num == "3":
            psus[idx]["index"] = int(value) if value.isdigit() else 0
        elif oid_num == "5":
            psus[idx]["serial"] = value.strip('"')
        elif oid_num == "10":
            # Parse float: strip whitespace, handle potential .0 etc
            s_val = value
            if "." in s_val:
                parts_float = s_val.split(".")
                if len(parts_float) == 2 and parts_float[0].isdigit() and parts_float[1].isdigit():
                    psus[idx]["output"] = float(s_val)
            elif s_val.isdigit():
                psus[idx]["output"] = float(int(s_val))
        elif oid_num == "14":
            psus[idx]["status"] = int(value) if value.isdigit() else 0
        elif oid_num == "15":
            psus[idx]["inputLine"] = int(value) if value.isdigit() else 0
        elif oid_num == "16":
            psus[idx]["present"] = int(value) if value.isdigit() else 0
    
    found = False
    for idx, data in psus.items():
        if str(idx) != item:
            continue
        found = True
        
        present_state = _PRESENT_MAP.get(data["present"], "unknown")
        if present_state != "present":
            return {"changed": False, "msg": "PSU was present but is not available anymore. (Present state: %s)" % present_state,
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        
        status_val = data["status"]
        if status_val not in _STATUS_MAP:
            snmp_state = "unknown"
            state = "UNKNOWN"
        else:
            snmp_state = _STATUS_MAP[status_val]
            if snmp_state == "Ok":
                state = "OK"
            elif snmp_state == "Degraded":
                state = "WARN"
            else:
                state = "CRIT"
        
        detail_output = ""
        if state == "OK":
            detail_output = ", Output: %fW" % data["output"]
        else:
            if data["status"] >= 1:
                detail_output = ", (%s)" % _PSU_STATUS[4]
            if data["inputLine"] >= 1:
                il_state = _INPUTLINE_STATUS.get(data["inputLine"], "unknown")
                detail_output = ", Inputline: %s" % il_state
        
        summary = "PSU is %s%s (S/N: %s)" % (snmp_state, detail_output, data["serial"])
        return {"changed": False, "msg": summary,
                "data": {"state": state, "metrics": {"output": data["output"]}, "details": ""}}
    
    if not found:
        return {"changed": False, "msg": "PSU not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}