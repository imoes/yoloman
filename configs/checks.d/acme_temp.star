def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.9148.3.3.1.3.1.1"
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        lines = res.stdout.splitlines()
        section = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.strip().split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            oid_tokens = oid_part.rsplit(".", 1)
            if len(oid_tokens) != 2:
                continue
            idx = oid_tokens[1]
            if oid_part.endswith(".3." + idx):
                descr = val_part.strip('"')
                value_str = ""
                state = ""
            elif oid_part.endswith(".4." + idx):
                value_str = val_part
            elif oid_part.endswith(".5." + idx):
                state = val_part
                section[descr] = (value_str, state)
        out = []
        ACME_ENVIRONMENT_STATES = {
            "1": ("OK", "initial"),
            "2": ("OK", "normal"),
            "3": ("WARN", "minor"),
            "4": ("WARN", "major"),
            "5": ("CRIT", "critical"),
            "6": ("CRIT", "shutdown"),
            "7": ("CRIT", "not present"),
            "8": ("CRIT", "not functioning"),
            "9": ("CRIT", "unknown"),
        }
        for descr, (value_str, state) in section.items():
            if state == "7":
                continue
            out.append({
                "item": descr,
                "params": {},
                "metrics": ["temp"]
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(out),
            "data": {"discovery": out}
        }

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.9148.3.3.1.3.1.1"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    lines = res.stdout.splitlines()
    section = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        oid_tokens = oid_part.rsplit(".", 1)
        if len(oid_tokens) != 2:
            continue
        idx = oid_tokens[1]
        if oid_part.endswith(".3." + idx):
            descr = val_part.strip('"')
            value_str = ""
            state = ""
        elif oid_part.endswith(".4." + idx):
            value_str = val_part
        elif oid_part.endswith(".5." + idx):
            state = val_part
            section[descr] = (value_str, state)

    ACME_ENVIRONMENT_STATES = {
        "1": ("OK", "initial"),
        "2": ("OK", "normal"),
        "3": ("WARN", "minor"),
        "4": ("WARN", "major"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "shutdown"),
        "7": ("CRIT", "not present"),
        "8": ("CRIT", "not functioning"),
        "9": ("CRIT", "unknown"),
    }

    if item not in section:
        return {
            "changed": False,
            "msg": "temperature item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    value_str, state = section[item]
    temp = float(value_str) if value_str.replace(".", "").replace("-", "").isdigit() else -999.0
    if temp == -999.0:
        return {
            "changed": False,
            "msg": "invalid temperature value: " + value_str,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    dev_state, dev_state_readable = ACME_ENVIRONMENT_STATES.get(state, ("UNKNOWN", "unknown"))
    if dev_state == "UNKNOWN":
        state_out = "UNKNOWN"
    else:
        state_out = dev_state

    warn = params.get("levels", (None, None))
    warn_upper = warn[0] if warn[0] != None else 80.0
    crit_upper = warn[1] if warn[1] != None else 90.0

    if state_out == "OK":
        if temp >= crit_upper:
            state_out = "CRIT"
        elif temp >= warn_upper:
            state_out = "WARN"
    elif state_out == "WARN":
        if temp >= crit_upper:
            state_out = "CRIT"

    return {
        "changed": False,
        "msg": "%s: %f C (%s)" % (item, temp, dev_state_readable),
        "data": {
            "state": state_out,
            "metrics": {"temp": temp},
            "details": ""
        }
    }