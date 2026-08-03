def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the HP MSA storage array via SNMP
    probe = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", "-t", "5", "-r", "1",
                     host, ".1.3.6.1.4.1.23872.2.1.3.1.3.23"], mutates=False)

    if probe.rc == 127:
        return {"changed": False, "msg": "snmpget not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc != 0:
        return {"changed": False, "msg": "HP MSA not found on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "5", "-r", "1",
                       host, ".1.3.6.1.4.1.23872.2.1.3.1.3.23"], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "HP MSA not found",
                    "data": {"discovery": []}}

        found_disks = False
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            value = parts[1].strip()
            if value != "" and value != "noSuchInstance" and not value.startswith("STRING:"):
                found_disks = True
                break

        if found_disks:
            return {"changed": False, "msg": "discovered 1 items",
                    "data": {"discovery": [
                        {
                            "item": "Disks",
                            "params": {"levels": (40.0, 45.0)},
                            "metrics": ["disk_temp"],
                            "service_labels": {"storage_array": host},
                        }
                    ]}}
        return {"changed": False, "msg": "discovered 0 items",
                "data": {"discovery": []}}

    item = params.get("item", "")

    if item != "Disks":
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-t", "5", "-r", "1",
                   host, ".1.3.6.1.4.1.23872.2.1.3.1.3.23"], mutates=False)

    if res.rc != 0:
        return {"changed": False, "msg": "HP MSA not reachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temps = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        value = parts[1].strip()
        if value == "" or value == "noSuchInstance" or value.startswith("STRING:"):
            continue
        temp_val = _to_float(value)
        if temp_val != None:
            temps.append(temp_val)

    if not temps:
        return {"changed": False, "msg": "no disk temperature data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels", (40.0, 45.0))
    warn = levels[0]
    crit = levels[1]

    max_temp = max(temps)
    avg_temp = _avg(temps)

    state = "OK"
    if max_temp >= crit:
        state = "CRIT"
    elif max_temp >= warn:
        state = "WARN"

    detail_lines = ["Disk temperatures:"]
    for t in temps:
        detail_lines.append("  %s C" % t)
    details = "\n".join(detail_lines)

    msg = "Max: %s C, Avg: %s C" % (max_temp, avg_temp)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "disk_temp": max_temp,
                "avg_temp": avg_temp,
            },
            "details": details,
        },
    }

def _avg(values):
    if not values:
        return 0.0
    total = 0.0
    count = 0
    for v in values:
        total = total + v
        count = count + 1
    return total / count

def _to_float(s):
    stripped = s.strip()
    if stripped == "" or stripped == "noSuchInstance" or stripped.startswith("STRING:"):
        return None
    if stripped.startswith("-"):
        digits = stripped[1:]
        if digits.isdigit():
            return 0.0 - float(digits)
        parts = digits.split(".", 1)
        int_part = parts[0]
        frac_part = parts[1] if len(parts) > 1 else ""
        if int_part.isdigit() and (frac_part == "" or frac_part.isdigit()):
            return 0.0 - float(digits)
        return None
    if stripped.isdigit():
        return float(stripped)
    parts = stripped.split(".", 1)
    int_part = parts[0]
    frac_part = parts[1] if len(parts) > 1 else ""
    if int_part.isdigit() and (frac_part == "" or frac_part.isdigit()):
        return float(stripped)
    return None