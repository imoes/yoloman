def main(ctx, params):
    res = ctx.run(["storcli", "/c0", "/eall", "/sall", "show", "all"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "storcli command failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    
    parsed = {}
    adapters = {0: {}}
    current_adapter = adapters[0]
    adapter = 0
    enclosure_devid = -181
    slot = None
    predictive_failure_count = None
    
    NORMALIZE_STATE = {
        "Unconfigured(good)": "Unconfigured Good",
        "Unconfigured(bad)": "Unconfigured Bad",
    }
    
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("Adapter #"):
            parts = line.split("#")
            if len(parts) >= 2:
                val = parts[1].rstrip(":").strip()
                if val.isdigit():
                    adapter = int(val)
                    current_adapter = {}
                    adapters[adapter] = current_adapter
        elif line.startswith("Enclosure Device ID:"):
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    enclosure_devid = int(val)
                    adapters[adapter][enclosure_devid] = enclosure_devid
        elif line.startswith("Enclosure Number:"):
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    enc_num = int(val)
                    for devid, number in current_adapter.items():
                        if number == enc_num:
                            enclosure_devid = devid
                            break
        elif line.startswith("Slot Number:"):
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    slot = int(val)
        elif line.startswith("Predictive Failure Count:"):
            parts = line.split(":")
            if len(parts) >= 2:
                val = parts[1].strip()
                if val.isdigit():
                    predictive_failure_count = int(val)
        elif line.startswith("Firmware state:"):
            state = line.split(":", 1)[1].strip().rstrip(",")
        elif line.startswith("Inquiry Data:"):
            name = line.split(":", 1)[1].strip()
            enclosure = adapters[adapter].get(enclosure_devid, 0)
            item = "/c%d/e%d/s%d" % (adapter, enclosure, slot)
            disk_state = NORMALIZE_STATE.get(state, state)
            disk = {"name": name, "state": disk_state, "failures": predictive_failure_count}
            parsed[item] = disk
            predictive_failure_count = None
        i += 1
    
    if params.get("_discover"):
        out = []
        for it in parsed:
            if it.startswith("/c"):
                out.append({"item": it, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d physical disks" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    disk = parsed.get(item)
    if disk == None:
        return {"changed": False, "msg": "disk not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state_map = {
        "Hotspare": 0,
        "JBOD": 0,
        "Failed": 2,
        "Copyback": 1,
        "Rebuild": 1,
    }
    
    state = disk["state"]
    nagios_state = state_map.get(state, 3)
    
    state_str = "OK" if nagios_state == 0 else ("WARN" if nagios_state == 1 else ("CRIT" if nagios_state == 2 else "UNKNOWN"))
    
    msg_parts = []
    msg_parts.append(state.capitalize())
    if disk["name"] != item:
        msg_parts.append("Name: " + disk["name"])
    
    failures = disk["failures"]
    if failures != None:
        if failures > 0:
            state_str = "WARN"
            msg_parts.append("Predictive fail count: %d (WARN)" % failures)
        else:
            msg_parts.append("Predictive fail count: %d" % failures)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state_str,
            "metrics": {},
            "details": "",
        },
    }