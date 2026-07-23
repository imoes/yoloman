# ===== megaraid_bbu.star =====
# Checkmk check: megaraid_bbu
# Translated Starlark module: RAID BBU check

# Reference values: (expected_value, state_code)
# state_code: 0=OK, 1=WARN, 2=CRIT
MEGARAI_BBU_REFVALUES = {
    "Remaining Capacity Low": ("No", 1),
    "I2c Errors Detected": ("No", 1),
    "Temperature": ("OK", 2),
    "Pack is about to fail & should be replaced": ("No", 1),
    "Charging Status": ("None", 1),
    "Battery State": ("Operational", 2),
    "Learn Cycle Status": ("OK", 1),
    "Learn Cycle Active": ("No", 0),
    "Battery Pack Missing": ("No", 2),
    "Battery Replacement required": ("No", 1),
    "Over Temperature": ("No", 2),
    "Over Charged": ("No", 1),
    "Voltage": ("OK", 2),
    "isSOHGood": ("Yes", 2),
}

def _parse_bbu_info(ctx):
    res = ctx.run(["megacli", "-AdpBbuCmd -GetBbuStatus -aALL", "-NoLog"], mutates=False)
    if res.rc != 0:
        return None
    
    controllers = {}
    current_hba = None
    for line in res.stdout.splitlines():
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        if len(parts) < 2:
            continue
        name = parts[0].strip()
        data = parts[1].strip()
        
        if name in ["BBU status for Adapter", "BBU status for Adpater"]:
            item = "/c" + data
            current_hba = {}
            controllers[item] = current_hba
            # Also add legacy item for compatibility
            controllers[data] = current_hba
        elif current_hba != None:
            current_hba[name] = data
    
    return controllers

def _check_state(state_code, label, actual, expected):
    if actual == expected:
        return {"state": 0, "summary": "%s: %s" % (label.capitalize(), actual)}
    elif state_code == 2:
        return {"state": 2, "summary": "%s: %s (expected: %s)" % (label.capitalize(), actual, expected)}
    else:
        return {"state": 1, "summary": "%s: %s (expected: %s)" % (label.capitalize(), actual, expected)}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        section = _parse_bbu_info(ctx)
        if section == None:
            return {"changed": False, "msg": "discovered 0 BBU controllers",
                    "data": {"discovery": []}}
        
        items = []
        for name in section:
            if name.startswith("/c"):
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["charge_level", "full_charge_capacity"]
                })
        
        return {"changed": False, "msg": "discovered %d BBU controllers" % len(items),
                "data": {"discovery": items}}
    
    # Check mode
    item = params.get("item", "")
    section = _parse_bbu_info(ctx)
    if section == None:
        return {"changed": False, "msg": "could not retrieve BBU information",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    controller = section.get(item)
    if controller == None:
        return {"changed": False, "msg": "BBU controller %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    charge_level = controller.get("Relative State of Charge", "not reported for this controller")
    results = [{"state": "OK", "summary": "Charge: %s" % charge_level}]
    
    capacity = controller.get("Full Charge Capacity")
    if capacity != None:
        results.append({"state": "OK", "summary": "Capacity: %s" % capacity})
    
    # Check learn cycle status
    if controller.get("Learn Cycle Active") == "Yes":
        results.append({"state": "OK", "summary": "No states to check (controller is in learn cycle)"})
        return {"changed": False, "msg": "; ".join([r["summary"] for r in results]),
                "data": {"state": "OK", "metrics": {}, "details": ""}}
    
    # Check reference values
    yielded = False
    for varname, (refvalue, state_code) in MEGARAI_BBU_REFVALUES.items():
        value = controller.get(varname)
        if value == None:
            continue
        
        # Some controllers report "Optimal" instead of "Operational"
        if value == "Optimal":
            continue
        
        # Some controllers do not output Temperature: OK and Voltage: OK.
        if varname in ["Temperature", "Voltage"] and value[0].isdigit():
            continue
        
        result = _check_state(state_code, varname, value, refvalue)
        if result["state"] != 0:
            yielded = True
            results.append({"state": "CRIT" if result["state"] == 2 else "WARN", "summary": result["summary"]})
    
    if not yielded:
        results.append({"state": "OK", "summary": "All states as expected"})
    
    # Determine overall state (worst state wins)
    state_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst_state = "OK"
    for r in results:
        if state_order.get(r["state"], 0) > state_order.get(worst_state, 0):
            worst_state = r["state"]
    
    return {"changed": False, "msg": "; ".join([r["summary"] for r in results]),
            "data": {"state": worst_state, "metrics": {}, "details": ""}}