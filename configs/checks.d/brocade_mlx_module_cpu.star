def _combine_item(id_, descr):
    # "Module" may be present in description; remove it
    if descr == "":
        return id_
    # Remove "Module" substring only (Checkmk logic)
    if descr.find(" Module") >= 0:
        descr = descr.replace(" Module", "").strip()
    elif descr.find("Module ") >= 0:
        descr = descr.replace("Module ", "").strip()
    else:
        descr = descr.strip()
    return id_ + " " + descr if descr != "" else id_


def _parse_snmp_section(output, num_fields):
    # Parse snmpwalk output into list of lists
    # Each line: OID = type: value  (type can be INTEGER:, STRING:, etc.)
    lines = output.splitlines()
    result = []
    current_row = []
    for line in lines:
        if len(line.strip()) == 0:
            continue
        # Split OID and value parts
        eq_idx = line.find("=")
        if eq_idx < 0:
            current_row = []  # reset
            continue
        value_part = line[eq_idx + 1:].strip()
        # Extract raw value string after colon (for STRING: "value", remove quotes)
        # Examples:
        # INTEGER: 10
        # STRING: "NI-MLX Module 1"
        if value_part.startswith("INTEGER:"):
            val = value_part[8:].strip()
        elif value_part.startswith("STRING:"):
            val = value_part[7:].strip()
            if len(val) >= 2 and val[0] == '"' and val[len(val) - 1] == '"':
                val = val[1:len(val) - 1]
        elif value_part.startswith("Counter32:"):
            val = value_part[10:].strip()
        else:
            # Fallback: take everything after first space
            val = value_part.strip()
        current_row.append(val)
        if len(current_row) == num_fields:
            result.append(current_row)
            current_row = []
    return result


def _saveint(s):
    # Safely convert string to int; return 0 on failure
    s = str(s).strip()
    if s == "":
        return 0
    # Check if it's a valid integer string
    is_negative = False
    if s.startswith("-"):
        is_negative = True
        s = s[1:]
    if s.isdigit():
        v = int(s)
        return -v if is_negative else v
    return 0


def main(ctx, params):
    # === CONFIGURATION ===
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("levels", [80.0, 90.0])
    if len(levels) != 2:
        levels = [80.0, 90.0]
    warn = levels[0]
    crit = levels[1]

    # === SNMP OIDs ===
    # Section 0: .1.3.6.1.4.1.1991.1.1.2.2.1.1 -> [1,2,12,24,25]
    # Section 1: .1.3.6.1.4.1.1991.1.1.2.11.1.1 -> [OIDEnd, 5]
    base0 = ".1.3.6.1.4.1.1991.1.1.2.2.1.1"
    base1 = ".1.3.6.1.4.1.1991.1.1.2.11.1.1"

    # === DISCOVERY MODE ===
    if params.get("_discover") == True:
        # Fetch section 0: module_id, module_descr, module_state, mem_total, mem_avail
        res0 = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, base0
        ], mutates=False)
        if res0.rc != 0:
            fail("SNMP walk failed for base0: " + res0.stderr)

        # Parse section0 lines: OID = type: value
        section0 = _parse_snmp_section(res0.stdout, 5)

        items = []
        for row in section0:
            if len(row) < 5:
                continue
            mod_id = row[0]
            mod_descr = row[1]
            mod_state = row[2]
            if mod_state != "0" and (mod_descr.startswith("NI-MLX") or mod_descr.startswith("BR-MLX")):
                item = _combine_item(mod_id, mod_descr)
                items.append({
                    "item": item,
                    "params": {"levels": [warn, crit]},
                    "metrics": ["cpu_util1", "cpu_util5", "cpu_util60", "cpu_util300"]
                })

        return {
            "changed": False,
            "msg": "discovered %d modules" % len(items),
            "data": {"discovery": items}
        }

    # === CHECK MODE (single item) ===
    item = params.get("item", "")
    if item == "":
        fail("item is required for check mode")

    # Fetch section0 (module state check) and section1 (CPU utilization)
    res0 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base0
    ], mutates=False)
    if res0.rc != 0:
        fail("SNMP walk failed for base0: " + res0.stderr)

    res1 = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, base1
    ], mutates=False)
    if res1.rc != 0:
        fail("SNMP walk failed for base1: " + res1.stderr)

    # Parse section0 and section1
    section0 = _parse_snmp_section(res0.stdout, 5)
    section1 = _parse_snmp_section(res1.stdout, 2)

    # Look for target module in section0
    module_found = False
    module_state = ""
    mod_id = ""
    for row in section0:
        if len(row) < 5:
            continue
        candidate = _combine_item(row[0], row[1])
        if candidate == item:
            module_found = True
            module_state = row[2]
            mod_id = row[0]
            break

    if module_found == False:
        return {
            "changed": False,
            "msg": "Module not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Module must be in state 10 (Running)
    if module_state != "10":
        return {
            "changed": False,
            "msg": "Module is not in state running",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract CPU utilization values from section1 for this module
    # OID structure: <base1>.<mod_id>.1.<window> = INTEGER: <value>
    utils = {"1": None, "5": None, "60": None, "300": None}

    for row in section1:
        if len(row) < 2:
            continue
        oid_end = row[0]
        cpu_val_raw = row[1]
        # Example oid_end: "1.1.1" -> module_id=1, window=1
        prefix = mod_id + ".1."
        if oid_end.startswith(prefix):
            window = oid_end[len(prefix):]
            if window == "1" or window == "5" or window == "60" or window == "300":
                utils[window] = _saveint(cpu_val_raw)

    # Check all windows are present
    if utils["1"] == None or utils["5"] == None or utils["60"] == None or utils["300"] == None:
        return {
            "changed": False,
            "msg": "did not find all cpu utilization values in snmp output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    cpu_util1 = utils["1"]
    cpu_util5 = utils["5"]
    cpu_util60 = utils["60"]
    cpu_util300 = utils["300"]

    # Determine state
    state = "OK"
    errorstring = ""
    if cpu_util60 >= crit:
        state = "CRIT"
        errorstring = "(!!)"
    elif cpu_util60 >= warn:
        state = "WARN"
        errorstring = "(!)"

    msg = "CPU utilization was %d/%d/%d%s/%d%% for the last 1/5/60/300 sec" % (
        cpu_util1, cpu_util5, cpu_util60, errorstring, cpu_util300
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "cpu_util1": cpu_util1,
                "cpu_util5": cpu_util5,
                "cpu_util60": cpu_util60,
                "cpu_util300": cpu_util300
            },
            "details": ""
        }
    }