def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_temp_section(ctx, params)
        if section == None:
            return {"changed": False, "msg": "junos ScreenOS not detected", "data": {"discovery": []}}
        discovery = []
        for name in section:
            discovery.append({"item": name, "params": {"levels": (70.0, 80.0)}, "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d temperature sensors" % len(discovery), "data": {"discovery": discovery}}
        # check mode
    item = params.get("item", "")
    section = _fetch_temp_section(ctx, params)
    if section == None:
        return {"changed": False, "msg": "junos ScreenOS not detected", "data": {"state": "UNKNOWN", "metrics": {}, "details": "host is not a Juniper ScreenOS device"}}
    if item not in section:
        return {"changed": False, "msg": "sensor %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    reading = float(section[item])
    warn, crit = params.get("levels", (70.0, 80.0))
    state = "CRIT" if reading >= crit else ("WARN" if reading >= warn else "OK")
    return {"changed": False, "msg": "Temperature: %f C" % reading, "data": {"state": state, "metrics": {"temperature": reading}, "details": ""}}


def _is_screenos(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ovqn", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    return sys_oid.startswith(".1.3.6.1.4.1.3224.1")


def _fetch_temp_section(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    if not _is_screenos(ctx, params):
        return None
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.3224.21.4.1"], mutates=False)
    if res.rc != 0:
        return None
    section = {}
    lines = res.stdout.splitlines()
    i = 0
    while i + 1 < len(lines):
        name = lines[i].strip()
        temp_str = lines[i + 1].strip()
        if name.endswith("Temperature"):
            name = name.rsplit(" ", 1)[0]
        if temp_str.lstrip("-").isdigit():
            section[name] = int(temp_str)
        i = i + 2
    return section