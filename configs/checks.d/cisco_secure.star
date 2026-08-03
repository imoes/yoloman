def saveint(i):
    return int(i) if (type(i) == "string" and i.isdigit()) else 0

def _sanitize_mac(string):
    hexes = []
    for m in string:
        code = ord(m)
        hx = "%x" % code
        hexes.append("%s" % hx)
    return ":".join(hexes).replace(" ", "0")

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", 0)
    crit = params.get("crit", 0)

    if params.get("_discover"):
        sys_descr = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if sys_descr.rc != 0 or "cisco" not in sys_descr.stdout.lower():
            return {"changed": False, "msg": "no cisco device found", "data": {"discovery": []}}
        exists_check = ctx.run(["snmpget", "-v2c", "-c", community, "-Onq", host, ".1.3.6.1.4.1.9.9.315.1.2.1.1.1"], mutates=False)
        if exists_check.rc != 0:
            return {"changed": False, "msg": "no port security data found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {"warn": warn, "crit": crit}, "metrics": []}]},
        }

    if_table = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.2.1.2.2.1"], mutates=False)
    sec_table = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, ".1.3.6.1.4.1.9.9.315.1.2.1.1"], mutates=False)

    if if_table.rc != 0 and sec_table.rc != 0:
        return {"changed": False, "msg": "no cisco device or port security data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    names = {}
    for line in if_table.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        oid_parts = oid.split(".")
        if len(oid_parts) < 2:
            continue
        if_index = oid_parts[-1]
        col = oid_parts[-2]
        if col == "2":
            names[if_index] = [value, "0"]
        elif col == "8":
            if if_index not in names:
                names[if_index] = [None, value]
            else:
                names[if_index][1] = value

    rows = {}
    for line in sec_table.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip().strip('"')
        oid_parts = oid.split(".")
        if len(oid_parts) < 2:
            continue
        if_index = oid_parts[-1]
        col = oid_parts[-2]
        if if_index not in rows:
            rows[if_index] = {"1": "", "2": "", "9": "0", "10": ""}
        rows[if_index][col] = value

    parsed = []
    for num, row in rows.items():
        if num in names:
            nm = names[num][0]
            op_state = int(names[num][1]) if names[num][1].isdigit() else 0
        else:
            nm = num
            op_state = 0
        is_enabled = row.get("1", "")
        status = row.get("2", "")
        violation_count = row.get("9", "0")
        lastmac = row.get("10", "")
        mac = _sanitize_mac(lastmac)
        enabled_txt = {"1": "yes", "2": "no"}.get(is_enabled)
        status_int = int(status) if status.isdigit() else None
        parsed.append((nm, op_state, enabled_txt, status_int, saveint(violation_count), mac))

    secure_states = {
        1: "full Operational",
        2: "could not be enabled due to certain reasons",
        3: "shutdown due to security violation",
    }

    messages = []
    at_least_one_problem = False
    state = "OK"
    for name, op_state, is_enabled, status, violation_count, lastmac in parsed:
        if status == 3 and violation_count == 0 and not lastmac:
            continue
        msg = "Port %s: %s (violation count: %d, last MAC: %s)" % (
            name,
            secure_states.get(status, "unknown"),
            violation_count,
            lastmac,
        )
        if is_enabled != None:
            if status == 2 and op_state == 1 and violation_count > 0:
                messages.append(msg)
                at_least_one_problem = True
                if state != "CRIT":
                    state = "WARN"
            elif status == 3:
                messages.append(msg)
                at_least_one_problem = True
                state = "CRIT"
            elif status == None:
                messages.append(msg)
                at_least_one_problem = True
                state = "UNKNOWN"
        else:
            messages.append(msg + " unknown enabled state")
            at_least_one_problem = True
            state = "UNKNOWN"

    if not at_least_one_problem:
        return {"changed": False, "msg": "No port security violation",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    summary = " | ".join(messages)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": summary}}