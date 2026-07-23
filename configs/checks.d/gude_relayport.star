def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.28507.38.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed",
                    "data": {"discovery": []}}
        lines = res.stdout.splitlines()
        ports = {}
        for line in lines:
            if not line:
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            val = parts[1].strip()
            rel = oid_full[len(".1.3.6.1.4.1.28507.38.1."):]
            if rel.startswith("3.1.2.1.2."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        portname = val.strip('"')
                        if idx not in ports:
                            ports[idx] = {"name": portname}
                        else:
                            ports[idx]["name"] = portname
            elif rel.startswith("3.1.2.1.3."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        state = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["state"] = state
            elif rel.startswith("5.5.2.1.4."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        power = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["power"] = power
            elif rel.startswith("5.5.2.1.5."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        current = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["current"] = current
            elif rel.startswith("5.5.2.1.6."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        voltage = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["voltage"] = voltage
            elif rel.startswith("5.5.2.1.7."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        freq = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["freq"] = freq
            elif rel.startswith("5.5.2.1.10."):
                segments = rel.split(".")
                if len(segments) >= 2:
                    last_segment = segments[-1]
                    if last_segment.isdigit():
                        idx = int(last_segment)
                        appower = val.strip()
                        if idx not in ports:
                            ports[idx] = {}
                        ports[idx]["appower"] = appower
        discovery = []
        for idx in sorted(ports.keys()):
            p = ports[idx]
            name = p.get("name", "")
            if name:
                discovery.append({
                    "item": name,
                    "params": {"voltage": (220, 210), "current": (15, 16)},
                    "metrics": ["power", "current", "voltage", "frequency", "appower"]
                })
        return {"changed": False, "msg": "discovered %d relay ports" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.28507.38.1"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        if not line:
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        val = parts[1].strip()
        rel = oid_full[len(".1.3.6.1.4.1.28507.38.1."):]
        if rel.startswith("3.1.2.1.2."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    name = val.strip('"')
                    data["portname"] = name
                    data["idx"] = idx
        elif rel.startswith("3.1.2.1.3."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    state = val.strip()
                    if idx == data.get("idx", -1):
                        data["state"] = state
        elif rel.startswith("5.5.2.1.4."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    power = val.strip()
                    if idx == data.get("idx", -1):
                        data["power"] = power
        elif rel.startswith("5.5.2.1.5."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    current = val.strip()
                    if idx == data.get("idx", -1):
                        data["current"] = current
        elif rel.startswith("5.5.2.1.6."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    voltage = val.strip()
                    if idx == data.get("idx", -1):
                        data["voltage"] = voltage
        elif rel.startswith("5.5.2.1.7."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    freq = val.strip()
                    if idx == data.get("idx", -1):
                        data["freq"] = freq
        elif rel.startswith("5.5.2.1.10."):
            segments = rel.split(".")
            if len(segments) >= 2:
                last_segment = segments[-1]
                if last_segment.isdigit():
                    idx = int(last_segment)
                    appower = val.strip()
                    if idx == data.get("idx", -1):
                        data["appower"] = appower

    portname = data.get("portname", "")
    if portname != item:
        return {"changed": False, "msg": "relay port %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_val = data.get("state", "0")
    state_map = {"0": ("CRIT", "off"), "1": ("OK", "on")}
    state_tuple = state_map.get(state_val, ("UNKNOWN", "unknown"))
    state = state_tuple[0]

    def safe_float(s):
        if s == None:
            return None
        stripped = s.strip()
        if stripped == "":
            return None
        # Check for numeric-only (allow one minus at start, one dot)
        if stripped.startswith("-"):
            rest = stripped[1:]
            if rest == "" or rest == "-" or rest == ".":
                return None
            # Validate rest
            for c in rest:
                if c not in "0123456789.":
                    return None
            if rest.count(".") > 1:
                return None
        else:
            for c in stripped:
                if c not in "0123456789.":
                    return None
            if stripped.count(".") > 1:
                return None
        return float(stripped)

    power = safe_float(data.get("power"))
    current = safe_float(data.get("current"))
    voltage = safe_float(data.get("voltage"))
    freq = safe_float(data.get("freq"))
    appower = safe_float(data.get("appower"))

    metrics = {}
    if power != None:
        metrics["power"] = power
    if current != None:
        metrics["current"] = current * 0.001
    if voltage != None:
        metrics["voltage"] = voltage
    if freq != None:
        metrics["frequency"] = freq * 0.01
    if appower != None:
        metrics["appower"] = appower

    warn_voltage = 220
    crit_voltage = 210
    warn_current = 15
    crit_current = 16

    if voltage != None:
        if voltage <= crit_voltage:
            state = "CRIT"
        elif voltage <= warn_voltage:
            if state != "CRIT":
                state = "WARN"

    if current != None:
        if current * 0.001 >= crit_current:
            state = "CRIT"
        elif current * 0.001 >= warn_current:
            if state != "CRIT":
                state = "WARN"

    details = []
    if power != None:
        details.append("power: %f W" % power)
    if current != None:
        details.append("current: %f A" % (current * 0.001))
    if voltage != None:
        details.append("voltage: %f V" % voltage)
    if freq != None:
        details.append("freq: %f Hz" % (freq * 0.01))
    if appower != None:
        details.append("appower: %f VA" % appower)

    status_text = state_tuple[1]
    msg = "Relay port %s: %s" % (item, status_text)
    if len(details) > 0:
        msg += ", " + ", ".join(details)

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}