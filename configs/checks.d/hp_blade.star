_STATUS_MAP = {
    1: ("CRIT", "Other"),
    2: ("OK", "Ok"),
    3: ("WARN", "Degraded"),
    4: ("CRIT", "Failed"),
}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"),
                       ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovery failed",
                    "data": {"discovery": []}}
        oid_val = res.stdout.strip()
        if ".11.5.7.1.2" in oid_val:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

    base = ".1.3.6.1.4.1.232.22.2.3.1.1.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"),
                   "-On", params.get("host", "localhost"),
                   base], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    fw = ""
    state_raw = 0
    serial = ""
    for line in lines:
        if not line.strip():
            continue
        parts = line.split(" = ", 1)
        if len(parts) < 2:
            continue
        oid_part, val_part = parts
        val_part = val_part.strip()
        if oid_part.endswith(".8"):
            if val_part.startswith("STRING: "):
                fw = val_part[8:].strip().strip('"')
            else:
                fw = val_part
        elif oid_part.endswith(".16"):
            if val_part.startswith("INTEGER: "):
                fw_val = val_part[9:].strip()
                state_raw = int(fw_val) if fw_val.isdigit() else 0
            else:
                fw_val = val_part.strip()
                state_raw = int(fw_val) if fw_val.isdigit() else 0
        elif oid_part.endswith(".7"):
            if val_part.startswith("STRING: "):
                serial = val_part[8:].strip().strip('"')
            else:
                serial = val_part

    if not fw and state_raw == 0 and not serial:
        return {"changed": False, "msg": "no HP Blade data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_text = "Other"
    if state_raw in _STATUS_MAP:
        state_text = _STATUS_MAP[state_raw][1]
    state = _STATUS_MAP.get(state_raw, ("CRIT", "Other"))[0]

    return {
        "changed": False,
        "msg": "General Status is %s (Firmware: %s, S/N: %s)" % (state_text, fw, serial),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }