# State mapping: Checkmk State values (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3

# Checkmk LDISKS_DEFAULTS from megaraid library
LDISKS_DEFAULTS = {
    "Optimal": STATE_OK,
    "Partially Degraded": STATE_WARN,
    "Degraded": STATE_CRIT,
    "Offline": STATE_WARN,
    "Recovery": STATE_WARN,
}

# Abbreviation mapping: raw state abbreviation -> full state label
_ABBREVIATIONS = {
    "awb": "Always WriteBack",
    "b": "Blocked",
    "cac": "CacheCade",
    "cbshld": "Copyback Shielded",
    "c": "Cached IO",
    "cfshld": "Configured shielded",
    "consist": "Consistent",
    "cpybck": "CopyBack",
    "dg": "Drive Group",
    "dgrd": "Degraded",
    "dhs": "Dedicated Hot Spare",
    "did": "Device ID",
    "eid": "Enclosure Device ID",
    "f": "Foreign",
    "ghs": "Global Hot Spare",
    "hd": "Hidden",
    "hspshld": "Hot Spare shielded",
    "intf": "Interface",
    "med": "Media Type",
    "nr": "No Read Ahead",
    "offln": "Offline",
    "ofln": "OffLine",
    "onln": "Online",
    "optl": "Optimal",
    "pdgd": "Partially Degraded",
    "pi": "Protection Info",
    "rec": "Recovery",
    "ro": "Read Only",
    "r": "Read Ahead Always",
    "rw": "Read Write",
    "scc": "Scheduled Check Consistency",
    "sed": "Self Encryptive Drive",
    "sesz": "Sector Size",
    "slt": "Slot No.",
    "sp": "Spun",
    "trans": "TransportReady",
    "t": "Transition",
    "ubad": "Unconfigured Bad",
    "ubunsp": "Unconfigured Bad Unsupported",
    "ugood": "Unconfigured Good",
    "ugshld": "Unconfigured shielded",
    "ugunsp": "Unsupported",
    "u": "Up",
    "vd": "Virtual Drive",
    "wb": "WriteBack",
    "wt": "WriteThrough",
}


def expand_abbreviation(short):
    return _ABBREVIATIONS.get(short.lower(), short)


def main(ctx, params):
    # Discovery mode: enumerate all virtual drives
    if params.get("_discover"):
        res = ctx.run(["storcli", "/call/vall", "show", "json"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "failed to run storcli",
                "data": {"discovery": []},
            }
        
        if res.stdout == "":
            return {
                "changed": False,
                "msg": "empty output from storcli",
                "data": {"discovery": []},
            }
        
        data = json.decode(res.stdout)
        
        # Parse vdrives data
        drives = []
        controllers = data.get("Controllers", [])
        for controller in controllers:
            response_data = controller.get("Response Data", {})
            vdrives = response_data.get("VD_LIST", [])
            controller_num = controller.get("Command Status", {}).get("Controller", 0)
            
            for vd in vdrives:
                dg_vd = vd.get("DG/VD", "")
                raid_type = vd.get("TYPE", "")
                raw_state = vd.get("State", "")
                access = vd.get("Access", "")
                consistent = vd.get("Consist", "No")
                
                item = "C%d.%s" % (controller_num, dg_vd)
                state_label = expand_abbreviation(raw_state)
                
                drives.append({
                    "item": item,
                    "params": LDISKS_DEFAULTS,
                    "metrics": [],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d virtual drives" % len(drives),
            "data": {"discovery": drives},
        }
    
    # Check mode: verify one virtual drive
    item = params.get("item", "")
    res = ctx.run(["storcli", "/call/vall", "show", "json"], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to run storcli",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if res.stdout == "":
        return {
            "changed": False,
            "msg": "empty output from storcli",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    data = json.decode(res.stdout)
    
    # Find drive by item
    found = False
    state = ""
    raid_type = ""
    access = ""
    consistent = False
    
    controllers = data.get("Controllers", [])
    for controller in controllers:
        response_data = controller.get("Response Data", {})
        vdrives = response_data.get("VD_LIST", [])
        controller_num = controller.get("Command Status", {}).get("Controller", 0)
        
        for vd in vdrives:
            dg_vd = vd.get("DG/VD", "")
            item_id = "C%d.%s" % (controller_num, dg_vd)
            
            if item_id == item:
                found = True
                state = expand_abbreviation(vd.get("State", ""))
                raid_type = vd.get("TYPE", "")
                access = vd.get("Access", "")
                consistent_str = vd.get("Consist", "No")
                consistent = consistent_str == "Yes"
                break
        
        if found:
            break
    
    if not found:
        return {
            "changed": False,
            "msg": "no such virtual drive: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    # Build check results
    state_str = "OK"
    summary_parts = []
    details_parts = []
    metrics = {}
    
    # raid_type info
    summary_parts.append("Raid type is %s" % raid_type)
    
    # access info
    summary_parts.append("Access: %s" % access)
    
    # consistency check
    if not consistent:
        state_str = "WARN"
        summary_parts.append("Drive is not consistent")
    else:
        summary_parts.append("Drive is consistent")
    
    # state mapping (from params or defaults)
    state_params = params.get("state", {})
    if state_params == {}:
        state_params = LDISKS_DEFAULTS
    
    raw_state_value = state_params.get(state)
    if raw_state_value == None:
        state_str = "UNKNOWN"
        summary_parts.append("State is %s (unknown)" % state)
    else:
        state_map = {
            STATE_OK: "OK",
            STATE_WARN: "WARN",
            STATE_CRIT: "CRIT",
            STATE_UNKNOWN: "UNKNOWN",
        }
        state_str = state_map.get(raw_state_value, "UNKNOWN")
        summary_parts.append("State is %s" % state)
    
    # Assemble output
    summary = ", ".join(summary_parts)
    details = ""
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": metrics,
            "details": details,
        },
    }