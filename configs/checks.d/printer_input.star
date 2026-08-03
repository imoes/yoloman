def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    base_input = ".1.3.6.1.2.1.43.8.2.1"
    base_output = ".1.3.6.1.2.1.43.9.2.1"

    if params.get("_discover"):
        trays = gather_trays(ctx, host, community, base_input)
        if len(trays) == 0:
            return {"changed": False, "msg": "no printer trays found", "data": {"discovery": []}}
        discovery = []
        for tray in trays:
            if not tray["description"]:
                continue
            if tray["capacity_max"] == 0:
                continue
            if tray["availability"] in (3, 5):
                continue
            discovery.append({
                "item": tray["name"],
                "params": {"capacity_levels": (0.0, 0.0)},
                "metrics": [],
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    trays = gather_trays(ctx, host, community, base_input)
    tray = None
    for t in trays:
        if t["name"] == item:
            tray = t
            break
    if tray == None:
        return {"changed": False, "msg": "no such tray: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    parts = []
    state = "OK"
    if tray["description"]:
        parts.append(tray["description"])
    if tray["offline"]:
        state = "CRIT"
        parts.append("Offline")
    if tray["transitioning"]:
        parts.append("Transitioning")
    status_name = availability_name(tray["availability"])
    parts.append("Status: " + status_name)
    if tray["availability"] in (1, 3, 5):
        if tray["availability"] in (1,):
            if state == "OK":
                state = "WARN"
        elif tray["availability"] in (3, 5):
            state = "CRIT"
    alert_str = alert_name(tray["alert"])
    parts.append("Alerts: " + alert_str)
    if tray["alert"] == "Critical":
        state = "CRIT"
    elif tray["alert"] == "Non-Critical":
        if state == "OK":
            state = "WARN"

    level = tray["level"]
    if level in (-1, -2) or level < -3:
        return {"changed": False, "msg": "; ".join(parts), "data": {"state": state, "metrics": {}, "details": ""}}

    capacity_unit = tray["capacity_unit"]
    if tray["capacity_max"] in (-2, -1, 0):
        if capacity_unit != " unknown":
            parts.append("Capacity: " + str(level) + capacity_unit)
        return {"changed": False, "msg": "; ".join(parts), "data": {"state": state, "metrics": {}, "details": ""}}

    if capacity_unit != " unknown":
        parts.append("Maximal capacity: " + str(tray["capacity_max"]) + capacity_unit)

    if level == -3:
        parts.append("At least one remaining")
        return {"changed": False, "msg": "; ".join(parts), "data": {"state": state, "metrics": {}, "details": ""}}

    warn, crit = params.get("capacity_levels", (0.0, 0.0))
    if warn == None:
        warn = 0.0
    if crit == None:
        crit = 0.0
    percent = 100.0 * level / tray["capacity_max"] if tray["capacity_max"] else 0.0
    parts.append("Remaining: " + render_percent(percent))
    if percent <= crit:
        state = "CRIT"
    elif percent <= warn:
        state = "WARN"
    return {"changed": False, "msg": "; ".join(parts), "data": {"state": state, "metrics": {"remaining": percent}, "details": ""}}


def gather_trays(ctx, host, community, base):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, base], mutates=False)
    if res.rc != 0:
        return []
    rows = {}
    for line in res.stdout.splitlines():
        parts = split_first_space(line)
        if parts == None:
            continue
        oid, value = parts
        if not oid.startswith(base + "."):
            continue
        suffix = oid[len(base) + 1:]
        idx_dot = suffix.find(".")
        if idx_dot < 0:
            continue
        tray_index = suffix[:idx_dot]
        col = suffix[idx_dot + 1:]
        if not tray_index in rows:
            rows[tray_index] = {}
        rows[tray_index][col] = value
    trays = []
    for tray_index, cols in rows.items():
        name = unescape(cols.get("13", ""))
        descr = unescape(cols.get("18", ""))
        status_raw = cols.get("11", "")
        capacity_unit = cols.get("8", "")
        capacity_max = cols.get("9", "")
        level = cols.get("10", "")
        snmp_status = int(status_raw) if status_raw != "" and status_raw.lstrip("-").isdigit() else 0
        transitioning = bool(snmp_status & 64)
        offline = bool(snmp_status & 32)
        if snmp_status & 16:
            alert = "Critical"
        elif snmp_status & 8:
            alert = "Non-Critical"
        else:
            alert = "None"
        availability = snmp_status % 8
        if name == "unknown" or name == "":
            name = descr if descr != "" else tray_index.split(".")[-1]
        if capacity_unit == "":
            unit_str = " unknown"
        else:
            unit_str = " " + printer_io_units.get(capacity_unit, "unknown")
        cm = int(capacity_max) if capacity_max != "" and capacity_max.lstrip("-").isdigit() else 0
        lv = int(level) if level != "" and level.lstrip("-").isdigit() else 0
        trays.append({
            "tray_index": tray_index,
            "name": name,
            "description": descr,
            "availability": availability,
            "alert": alert,
            "offline": offline,
            "transitioning": transitioning,
            "capacity_unit": unit_str,
            "capacity_max": cm,
            "level": lv,
        })
    return trays


def availability_name(code):
    names = {
        0: "Available and idle",
        2: "Available and standby",
        4: "Available and active",
        6: "Available and busy",
        1: "Unavailable and on request",
        3: "Unavailable because broken",
        5: "Unknown",
    }
    return names.get(code, "Unknown")


def alert_name(alert):
    return alert


def render_percent(value):
    return "%f%%" % value


def unescape(s):
    return s.replace("\\.", ".").replace("\\=", "=").replace("\\ ", " ")


def split_first_space(line):
    idx = line.find(" ")
    if idx < 0:
        return None
    return (line[:idx], line[idx + 1:])


printer_io_units = {
    "-1": "unknown",
    "0": "unknown",
    "1": "unknown",
    "2": "unknown",
    "3": "1/10000 in",
    "4": "micrometers",
    "8": "sheets",
    "16": "feet",
    "17": "meters",
    "18": "items",
    "19": "percent",
}