def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysDescr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sysDescr.rc == 127:
            return {"changed": False, "msg": "snmpget not found", "data": {"discovery": []}}
        if sysDescr.rc != 0:
            return {"changed": False, "msg": "SNMP not reachable", "data": {"discovery": []}}
        descr = sysDescr.stdout.strip()
        if not (descr.endswith(" mips") or descr.endswith(" sh4a")):
            return {"changed": False, "msg": "not IBM IMM", "data": {"discovery": []}}
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2.3.51.3.1.4"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no IBM IMM health data", "data": {"discovery": []}}
        if not res.stdout.strip():
            return {"changed": False, "msg": "no IBM IMM health data", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered System health", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    return _check(ctx, params)

def _check(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.2.3.51.3.1.4"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no IBM IMM health data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    if not raw:
        return {"changed": False, "msg": "Health info not found in SNMP data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = raw.splitlines()
    # Each line: "<column-OID>.<idx> <value>"; index = oid_suffix after base
    base = ".1.3.6.1.4.1.2.3.51.3.1.4"
    section = []
    idx = 0
    for line in lines:
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        value = parts[1]
        suffix = oid[len(base) + 1:]
        # index is the suffix after the last dot
        dot = suffix.rfind(".")
        if dot == -1:
            continue
        index = suffix[dot + 1:]
        # store as row: use index order
        section.append((index, value))
    # Sort by index
    section_sorted = sorted(section, key=lambda x: x[0])
    # The first row (index) is the overall state
    if not section_sorted:
        return {"changed": False, "msg": "Health info not found in SNMP data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    state = section_sorted[0][1]
    infotext = ""
    num_alerts = (len(section_sorted) - 1) // 3
    for i in range(num_alerts):
        state_row = section_sorted[num_alerts + 1 + i]
        text_row = section_sorted[num_alerts * 2 + 1 + i]
        if infotext != "":
            infotext += ", "
        infotext += text_row[1] + "(" + state_row[1] + ")"
    if state == "255":
        return {"changed": False, "msg": "no problem found", "data": {"state": "OK", "metrics": {}, "details": ""}}
    if state == "0":
        return {"changed": False, "msg": infotext + " - manual log clearing needed to recover state", "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if state == "2":
        return {"changed": False, "msg": infotext, "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    if state == "4":
        return {"changed": False, "msg": infotext, "data": {"state": "WARN", "metrics": {}, "details": ""}}
    return {"changed": False, "msg": infotext, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}