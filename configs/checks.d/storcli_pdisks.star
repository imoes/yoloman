# Map state abbreviations to full descriptions (as in Checkmk's megaraid.expand_abbreviation)
# Using common Broadcom/LSI MegaRAID states
STATE_MAP = {
    "onln": "Online",
    "onbld": "Online, rebuilding",
    "dgo": "Dedicated hot spare",
    "ugood": "Unconfigured good",
    "ubad": "Unconfigured bad",
    "hsp": "Hot spare",
    "pfr": "Failed, replacing",
    "clpr": "Failed, cloning in progress",
    "pred": "Failed, predictive failure",
    "bnl": "Blocked",
    "dgd": "Degraded",
    "n/a": "Not Available",
    "uck": "Unknown",
    "pde": "Pattern degradation error",
    "cde": "Consistency data error",
    "sde": "Self decryption error",
    "ncd": "No capacity data",
    "pnc": "Partner not complete",
    "bld": "Rebuild failed",
    "bad": "Failed",
}

def _expand_state(state):
    return STATE_MAP.get(state.lower(), state)

# Default thresholds mapping states to Checkmk State (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
# Based on megaraid.PDISKS_DEFAULTS
DEFAULT_STATE_MAP = {
    "onln": 0,
    "onbld": 1,
    "dgo": 0,
    "ugood": 0,
    "ubad": 2,
    "hsp": 0,
    "pfr": 1,
    "clpr": 1,
    "pred": 1,
    "bnl": 2,
    "dgd": 2,
    "n/a": 3,
    "uck": 3,
    "pde": 2,
    "cde": 2,
    "sde": 2,
    "ncd": 2,
    "pnc": 2,
    "bld": 2,
    "bad": 2,
}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover") != None:
        res = ctx.run(["storcli", "/c0", "/eall", "/sall", "show", "all", "J"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        if res.stdout == "":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        
        if type(data) != "dict":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        controllers = data.get("Controllers", [])
        if type(controllers) != "list":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        drive_info = []
        
        for ctrl in controllers:
            if type(ctrl) != "dict":
                continue
            response_data = ctrl.get("Response Data", {})
            if type(response_data) != "dict":
                continue
            drives = response_data.get("Drive Information", [])
            if type(drives) != "list":
                continue
            controller_num = ctrl.get("Controller", 0)
            if type(controller_num) != "int":
                controller_num = 0
            
            for drive in drives:
                if type(drive) != "dict":
                    continue
                eid_slot = drive.get("EID:Slt", "")
                device_id = drive.get("Device Id", "")
                state = drive.get("State", "")
                size_val = drive.get("Size (in GB)", 0)
                if size_val == 0:
                    size_val = drive.get("Size", 0)
                    if type(size_val) == "int":
                        size_val = float(size_val)
                    elif type(size_val) != "float":
                        size_val = 0.0
                
                if eid_slot != "" and device_id != "":
                    item_name = "C%d.%s-%s" % (controller_num, eid_slot, device_id)
                    drive_info.append({
                        "item": item_name,
                        "params": DEFAULT_STATE_MAP,
                        "metrics": [],
                    })
        
        return {"changed": False, "msg": "discovered %d PDs" % len(drive_info),
                "data": {"discovery": drive_info}}

    # Check mode
    item = params.get("item", "")
    state_map = params.get("state_map", DEFAULT_STATE_MAP)
    
    res = ctx.run(["storcli", "/c0", "/eall", "/sall", "show", "all", "J"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "storcli command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if res.stdout == "":
        return {
            "changed": False,
            "msg": "failed to parse storcli JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = json.decode(res.stdout)

    if type(data) != "dict":
        return {
            "changed": False,
            "msg": "failed to parse storcli JSON",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    controllers = data.get("Controllers", [])
    if type(controllers) != "list":
        return {
            "changed": False,
            "msg": "PDisk not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found = False
    disk_state = ""
    size_val = 0.0
    size_unit = "GB"

    for ctrl in controllers:
        if type(ctrl) != "dict":
            continue
        response_data = ctrl.get("Response Data", {})
        if type(response_data) != "dict":
            continue
        drives = response_data.get("Drive Information", [])
        if type(drives) != "list":
            continue
        controller_num = ctrl.get("Controller", 0)
        if type(controller_num) != "int":
            controller_num = 0
        
        for drive in drives:
            if type(drive) != "dict":
                continue
            eid_slot = drive.get("EID:Slt", "")
            device_id = drive.get("Device Id", "")
            state = drive.get("State", "")
            size_val = drive.get("Size (in GB)", 0)
            if size_val == 0:
                size_val = drive.get("Size", 0)
                if type(size_val) == "int":
                    size_val = float(size_val)
                elif type(size_val) != "float":
                    size_val = 0.0
            
            candidate_item = "C%d.%s-%s" % (controller_num, eid_slot, device_id)
            
            if candidate_item == item:
                found = True
                disk_state = state
                size_unit = "GB"
                break
        if found:
            break

    if not found:
        return {
            "changed": False,
            "msg": "PDisk not found: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Determine state
    state_key = disk_state.lower()
    status = state_map.get(state_key, 3)  # 3 = UNKNOWN
    state_text = "OK" if status == 0 else ("WARN" if status == 1 else ("CRIT" if status == 2 else "UNKNOWN"))
    
    infotext = "Size: %s %s, Disk State: %s" % (str(size_val), size_unit, _expand_state(disk_state))
    details = ""

    # Add extra info for unknown states
    if state_key not in state_map:
        infotext += " (state '%s' not in thresholds)" % disk_state
        details = "Disk state '%s' not known in thresholds." % disk_state

    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state_text,
            "metrics": {},
            "details": details,
        },
    }