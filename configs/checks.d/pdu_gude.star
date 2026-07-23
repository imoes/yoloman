def _parse_snmp_output(lines):
    """Parse SNMP lines into a dict: pdu_num -> list of (value_float, unit, label)"""
    unit_map = [
        ("kWh", 1000, "Total accumulated active energy"),
        ("W", 1, "Active power"),
        ("A", 1000, "Current"),
        ("V", 1, "Voltage"),
        ("VA", 1, "Mean apparent power"),
    ]
    result = {}
    for line in lines:
        line = line.strip()
        if line == "" or line.find("=") == -1:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        idx_part = oid_part.rsplit(".", 1)
        if len(idx_part) != 2:
            continue
        try_str = idx_part[1]
        idx = 0
        if try_str.isdigit():
            idx = int(try_str)
        else:
            continue
        value_str = parts[1].strip()
        colon_pos = value_str.find(":")
        if colon_pos != -1:
            value_str = value_str[colon_pos+1:].strip()
        val = 0.0
        if value_str != "":
            # Safe float conversion: check for valid numeric string
            cleaned = value_str.strip()
            # Allow digits, dot, minus sign only
            is_valid = True
            if cleaned != "":
                for c in cleaned:
                    if c not in "0123456789.-+eE":
                        is_valid = False
                        break
                if not is_valid:
                    continue
            # Use guarded conversion: only if valid format
            if cleaned == "." or cleaned == "-" or cleaned == "+":
                continue
            # Basic validation: must have at least one digit
            has_digit = False
            for c in cleaned:
                if c in "0123456789":
                    has_digit = True
                    break
            if not has_digit:
                continue
            # Attempt conversion only for plausible numbers
            # Starlark does not have try/except, so we skip conversion errors
            # and rely on string validation above
            val = float(cleaned) if cleaned.find("e") == -1 and cleaned.find("E") == -1 else 0.0
            # Fallback for scientific notation: skip for safety
            if cleaned.find("e") != -1 or cleaned.find("E") != -1:
                val = 0.0
        pdu_num = str(idx)
        if not (pdu_num in result):
            result[pdu_num] = []
        unit_idx = len(result[pdu_num])
        if unit_idx < len(unit_map):
            unit, scale, label = unit_map[unit_idx]
            result[pdu_num].append({
                "value": val / scale,
                "unit": unit,
                "label": label,
            })
    return result

def main(ctx, params):
    # Discovery mode
    if params.get("_discover") == True:
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        base_oid = ".1.3.6.1.4.1.28507.26.1.5.1.2.1"
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)
        parsed = _parse_snmp_output(res.stdout.splitlines())
        discovery = []
        pdu_nums = list(parsed.keys())
        pdu_nums.sort(key=lambda x: int(x))
        for pdu_num in pdu_nums:
            metrics = []
            for p in parsed[pdu_num]:
                metrics.append(p["unit"])
            default_params = {
                "V": [220, 210],
                "A": [15, 16],
                "W": [3500, 3600],
            }
            discovery.append({
                "item": pdu_num,
                "params": default_params,
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d pdus" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        fail("item is required in check mode")

    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.28507.26.1.5.1.2.1"
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        fail("SNMP walk failed: " + res.stderr)

    parsed = _parse_snmp_output(res.stdout.splitlines())
    pdu_props = parsed.get(item)
    if pdu_props == None:
        return {
            "changed": False,
            "msg": "PDU %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    default_levels = {
        "V": [220, 210],
        "A": [15, 16],
        "W": [3500, 3600],
    }

    state = "OK"
    details = []
    metrics = {}
    for prop in pdu_props:
        unit = prop["unit"]
        value = prop["value"]
        label = prop["label"]

        levels = params.get(unit)
        if levels == None:
            levels = default_levels.get(unit)
        if levels == None:
            continue

        warn_val = levels[0]
        crit_val = levels[1]

        if warn_val > crit_val:
            if value <= crit_val:
                state = "CRIT"
            elif value <= warn_val:
                if state != "CRIT":
                    state = "WARN"
        else:
            if value >= crit_val:
                state = "CRIT"
            elif value >= warn_val:
                if state != "CRIT":
                    state = "WARN"

        metrics[unit] = value
        details.append("%s: %f %s" % (label, value, unit))

    msg = ""
    if len(details) > 0:
        msg = "PDU %s: %s" % (item, ", ".join(details))
    else:
        msg = "PDU %s: no metrics" % item
    if state == "OK":
        msg = "PDU %s: OK" % item

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }