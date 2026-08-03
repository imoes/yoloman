# megaraid_bbu.star — read-only translation of Checkmk megaraid_bbu check

MEGARAID_BBU_REFVALUES = {
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


def state_name(level):
    if level == 0:
        return "OK"
    if level == 1:
        return "WARN"
    if level == 2:
        return "CRIT"
    return "UNKNOWN"


def check_state(mismatch_level, label, actual, expected):
    short = "%s: %s" % (label.capitalize(), actual)
    if actual == expected:
        return {"state": "OK", "summary": short}
    return {"state": state_name(mismatch_level), "summary": "%s (expected: %s)" % (short, expected)}


def parse_megaraid_bbu(output):
    controllers = {}
    current_hba = None
    current_item = None
    for line in output.splitlines():
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if ":" not in line:
            continue
        name, data = line.split(":", 1)
        name = name.strip()
        data = data.strip()
        if name in ["BBU status for Adapter", "BBU status for Adpater"]:
            item = "/c%s" % data
            current_hba = {}
            current_item = item
            controllers[item] = current_hba
            controllers[data] = current_hba
        elif current_hba != None and current_item != None:
            current_hba[name] = data
    return controllers


def main(ctx, params):
    # Probe for megacli to establish the real data source exists.
    # Per the contract: absence of the product -> empty discovery / UNKNOWN.
    probe = ctx.run(["megacli", "-adpEventInfo", "-aALL", "-out", "/tmp/_cmk_bbu_probe.txt"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "megacli not installed", "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        controllers = parse_megaraid_bbu(probe.stdout)
        discovery = []
        for item in sorted(controllers.keys()):
            if item.startswith("/c"):
                discovery.append({"item": item, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery, "host_labels": {}},
        }

    # CHECK MODE: evaluate one adapter item.
    item = params.get("item", "")
    section = parse_megaraid_bbu(probe.stdout)
    controller = section.get(item)
    if controller == None:
        return {
            "changed": False,
            "msg": "no such controller: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    summaries = []

    # Charge level
    charge_level = controller.get("Relative State of Charge", "not reported for this controller")
    summaries.append("Charge: %s" % charge_level)
    capacity = controller.get("Full Charge Capacity")
    if capacity != None:
        summaries.append("Capacity: %s" % capacity)

    # Learn Cycle Active short-circuit
    if controller.get("Learn Cycle Active") == "Yes":
        summaries.append("No states to check (controller is in learn cycle)")
        return {
            "changed": False,
            "msg": "; ".join(summaries),
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    # Verify important parameters
    yielded = False
    worst_level = 0
    worst_state = "OK"
    for varname, (refvalue, refstate) in MEGARAID_BBU_REFVALUES.items():
        value = controller.get(varname)
        if value == None:
            continue
        if value == "Optimal":
            continue
        if varname in ["Temperature", "Voltage"] and len(value) > 0 and value[0].isdigit():
            continue
        result = check_state(refstate, varname, value, refvalue)
        summaries.append(result["summary"])
        if result["state"] != "OK":
            yielded = True
            if refstate > worst_level:
                worst_level = refstate
                worst_state = result["state"]

    if not yielded:
        summaries.append("All states as expected")

    final_state = worst_state if yielded else "OK"
    return {
        "changed": False,
        "msg": "; ".join(summaries),
        "data": {"state": final_state, "metrics": {}, "details": ""},
    }