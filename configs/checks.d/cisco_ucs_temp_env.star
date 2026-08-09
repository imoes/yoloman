def _parse_temp(value):
    if value == None:
        return None
    return int(value)

# OID suffix -> friendly name, as in parse_cisco_ucs_temp_env
OID_NAMES = ["Ambient", "Front", "IO-Hub", "Rear"]

# sysObjectID values that identify Cisco UCS (from lib_ucs.DETECT)
UCS_OID_SUFFIXES = [
    ".1.3.6.1.4.1.9.1.1682",
    ".1.3.6.1.4.1.9.1.1683",
    ".1.3.6.1.4.1.9.1.1684",
    ".1.3.6.1.4.1.9.1.1685",
    ".1.3.6.1.4.1.9.1.2178",
    ".1.3.6.1.4.1.9.1.2179",
    ".1.3.6.1.4.1.9.1.2424",
    ".1.3.6.1.4.1.9.1.2492",
    ".1.3.6.1.4.1.9.1.2493",
    ".1.3.6.1.4.1.9.1.3100",
]

def main(ctx, params):
    if params.get("_discover"):
        # PROBE FOR THE REAL THING FIRST: confirm this is a Cisco UCS host
        sysoid_res = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sysoid_res.rc != 0:
            # not installed (rc 127) or unreachable or no SNMP -> no UCS here
            return {"changed": False, "msg": "no SNMP reachable", "data": {"discovery": []}}

        sysoid = sysoid_res.stdout.strip()
        is_ucs = False
        for suffix in UCS_OID_SUFFIXES:
            if sysoid == suffix or sysoid.endswith(suffix):
                is_ucs = True
                break
        if not is_ucs:
            return {"changed": False, "msg": "host is not a Cisco UCS device", "data": {"discovery": []}}

        # Walk the temperature table: .1.3.6.1.4.1.9.9.719.1.9.44.1.<4|8|13|21>
        base = ".1.3.6.1.4.1.9.9.719.1.9.44.1"
        temps = {}
        for col in ["4", "8", "13", "21"]:
            res = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"), base + "." + col],
                mutates=False,
            )
            if res.rc == 0:
                temps[col] = res.stdout.strip()
            else:
                temps[col] = ""

        if not temps:
            return {"changed": False, "msg": "no temperature data", "data": {"discovery": []}}

        discovery = []
        # Preserve order Ambient, Front, IO-Hub, Rear (indices 0..3)
        for idx, col in enumerate(["4", "8", "13", "21"]):
            name = OID_NAMES[idx]
            if temps.get(col) != "":
                discovery.append({
                    "item": name,
                    "params": {"levels": (30.0, 35.0)},
                    "metrics": ["temperature"],
                })
        return {"changed": False, "msg": "discovered %d sensors" % len(discovery), "data": {"discovery": discovery}}

    # CHECK MODE for a single item
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.9.9.719.1.9.44.1"
    col_map = {"Ambient": "4", "Front": "8", "IO-Hub": "13", "Rear": "21"}
    col = col_map.get(item)
    if col == None:
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"), base + "." + col],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no temperature data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = res.stdout.strip()
    temp = _parse_temp(raw)
    if temp == None:
        return {"changed": False, "msg": "cannot parse temperature for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    levels = params.get("levels")
    if levels == None:
        warn = 30.0
        crit = 35.0
    else:
        warn = levels[0]
        crit = levels[1]
    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    return {"changed": False, "msg": "Temperature %s: %d C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": float(temp)}, "details": ""}}