def _sanitize_mac(string):
    # Convert binary MAC to colon-separated hex string
    if string == None or len(string) == 0:
        return ""
    result = []
    for i in range(len(string)):
        c = string[i]
        if type(c) == "int":
            v = c
        else:
            v = ord(c)
        hex_str = "%x" % v
        result.append(hex_str)
    return ":".join(result)

def _saveint(s):
    # Safely convert string to int; return 0 on failure
    if s == None:
        return 0
    s = str(s).strip()
    if s == "":
        return 0
    # Guard instead of try/except
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    return 0

def _int_guard(s):
    # Parse integer safely: return int(s) if s is valid digit string, else 0
    s = str(s).strip()
    if s == "":
        return 0
    if s.isdigit() or (s.startswith("-") and s[1:].isdigit()):
        return int(s)
    return 0

def main(ctx, params):
    if params.get("_discover"):
        # SNMP discovery: fetch both tables
        res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
                        ".1.3.6.1.2.1.2.2.1.1,.1.3.6.1.2.1.2.2.1.2,.1.3.6.1.2.1.2.2.1.8"], mutates=False)
        res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
                        ".1.3.6.1.4.1.9.9.315.1.2.1.1.1,.1.3.6.1.4.1.9.9.315.1.2.1.1.2,.1.3.6.1.4.1.9.9.315.1.2.1.1.9,.1.3.6.1.4.1.9.9.315.1.2.1.1.10"], mutates=False)

        # Parse first table: ifIndex, ifName, ifOperStatus
        table1 = {}
        for line in res1.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            # Guard instead of try/except
            if not (oid_end.isdigit() or (oid_end.startswith("-") and oid_end[1:].isdigit())):
                continue
            ifIndex = int(oid_end)
            ifName = parts[2].strip('"') if len(parts) > 2 else ""
            ifOperStatus = parts[3] if len(parts) > 3 else ""
            table1[ifIndex] = {"name": ifName, "op_state": ifOperStatus}

        # Parse second table: ifIndex, ciscoSecureEnableStatus, ciscoSecureViolationStatus,
        #                     ciscoSecureViolationCount, ciscoSecureLastMacAddress
        table2 = []
        for line in res2.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 4:
                continue
            oid_end = parts[0].rsplit(".", 1)[-1]
            # Guard instead of try/except
            if not (oid_end.isdigit() or (oid_end.startswith("-") and oid_end[1:].isdigit())):
                continue
            ifIndex = int(oid_end)
            is_enabled = parts[2] if len(parts) > 2 else ""
            status = parts[3] if len(parts) > 3 else ""
            violation_count = parts[4] if len(parts) > 4 else ""
            lastmac_raw = parts[5] if len(parts) > 5 else ""

            # Convert lastmac_raw (ASCII string of 6 bytes) to MAC string
            lastmac = ""
            if len(lastmac_raw) == 12:
                lastmac = _sanitize_mac(lastmac_raw)

            table2.append((ifIndex, is_enabled, status, violation_count, lastmac))

        # Combine tables and run discovery logic
        section = []
        names = {item[0]: (item[1].get("name", ""), item[1].get("op_state", "0")) for item in table1.items()}
        for num, is_enabled, status, violation_count, lastmac in table2:
            enabled_txt = None
            if is_enabled == "1":
                enabled_txt = "yes"
            elif is_enabled == "2":
                enabled_txt = "no"

            op_state_str = "0"
            if num in names:
                op_state_str = names[num][1]

            # Guard instead of try/except
            if op_state_str.isdigit() or (op_state_str.startswith("-") and op_state_str[1:].isdigit()):
                op_state = int(op_state_str)
            else:
                op_state = 0

            # Guard instead of try/except
            if status.isdigit() or (status.startswith("-") and status[1:].isdigit()):
                status_int = int(status)
            else:
                status_int = None

            parsed = (names.get(num, ("",))[0] if num in names else str(num),
                      op_state, enabled_txt, status_int, _saveint(violation_count), lastmac)
            section.append(parsed)

        # Discovery logic: yield Service() if any port has security active
        should_discover = False
        for name, op_state, is_enabled, status, violation_count, lastmac in section:
            if status == 3 or (is_enabled != "no" and op_state == 1):
                should_discover = True
                break

        if should_discover:
            return {"changed": False, "msg": "discovered Port Security", "data": {
                "discovery": [{"item": "", "params": {}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered no Port Security", "data": {
                "discovery": []}}

    # Check mode
    res1 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
                    ".1.3.6.1.2.1.2.2.1.1,.1.3.6.1.2.1.2.2.1.2,.1.3.6.1.2.1.2.2.1.8"], mutates=False)
    res2 = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", ctx.facts().get("hostname", "localhost"),
                    ".1.3.6.1.4.1.9.9.315.1.2.1.1.1,.1.3.6.1.4.1.9.9.315.1.2.1.1.2,.1.3.6.1.4.1.9.9.315.1.2.1.1.9,.1.3.6.1.4.1.9.9.315.1.2.1.1.10"], mutates=False)

    # Parse tables (same as discovery)
    table1 = {}
    for line in res1.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 4:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        # Guard instead of try/except
        if not (oid_end.isdigit() or (oid_end.startswith("-") and oid_end[1:].isdigit())):
            continue
        ifIndex = int(oid_end)
        ifName = parts[2].strip('"') if len(parts) > 2 else ""
        ifOperStatus = parts[3] if len(parts) > 3 else ""
        table1[ifIndex] = {"name": ifName, "op_state": ifOperStatus}

    table2 = []
    for line in res2.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 4:
            continue
        oid_end = parts[0].rsplit(".", 1)[-1]
        # Guard instead of try/except
        if not (oid_end.isdigit() or (oid_end.startswith("-") and oid_end[1:].isdigit())):
            continue
        ifIndex = int(oid_end)
        is_enabled = parts[2] if len(parts) > 2 else ""
        status = parts[3] if len(parts) > 3 else ""
        violation_count = parts[4] if len(parts) > 4 else ""
        lastmac_raw = parts[5] if len(parts) > 5 else ""

        lastmac = ""
        if len(lastmac_raw) == 12:
            lastmac = _sanitize_mac(lastmac_raw)

        table2.append((ifIndex, is_enabled, status, violation_count, lastmac))

    section = []
    names = {item[0]: (item[1].get("name", ""), item[1].get("op_state", "0")) for item in table1.items()}
    for num, is_enabled, status, violation_count, lastmac in table2:
        enabled_txt = None
        if is_enabled == "1":
            enabled_txt = "yes"
        elif is_enabled == "2":
            enabled_txt = "no"

        op_state_str = "0"
        if num in names:
            op_state_str = names[num][1]

        # Guard instead of try/except
        if op_state_str.isdigit() or (op_state_str.startswith("-") and op_state_str[1:].isdigit()):
            op_state = int(op_state_str)
        else:
            op_state = 0

        # Guard instead of try/except
        if status.isdigit() or (status.startswith("-") and status[1:].isdigit()):
            status_int = int(status)
        else:
            status_int = None

        parsed = (names.get(num, ("",))[0] if num in names else str(num),
                  op_state, enabled_txt, status_int, _saveint(violation_count), lastmac)
        section.append(parsed)

    # Check logic
    secure_states = {
        1: "full Operational",
        2: "could not be enabled due to certain reasons",
        3: "shutdown due to security violation",
    }

    at_least_one_problem = False
    messages = []
    for name, op_state, is_enabled, status, violation_count, lastmac in section:
        # Skip ports with status=3 (shutdown) but no actual violation evidence
        if status == 3 and violation_count == 0 and not lastmac:
            continue

        message = "Port %s: %s (violation count: %d, last MAC: %s)" % (
            name,
            secure_states.get(status, "unknown"),
            violation_count,
            lastmac,
        )

        if is_enabled != None:
            # If port cant be enabled and is up and has violations -> WARN
            if status == 2 and op_state == 1 and violation_count > 0:
                messages.append(message)
                at_least_one_problem = True
            # Security issue -> CRIT
            elif status == 3:
                messages.append(message)
                at_least_one_problem = True
            elif status == None:
                messages.append(message)
                at_least_one_problem = True
        else:
            messages.append(message + " unknown enabled state")
            at_least_one_problem = True

    if at_least_one_problem:
        return {"changed": False, "msg": "; ".join(messages), "data": {
            "state": "CRIT",
            "metrics": {},
            "details": ""
        }}

    return {"changed": False, "msg": "No port security violation", "data": {
        "state": "OK",
        "metrics": {},
        "details": ""
    }}
