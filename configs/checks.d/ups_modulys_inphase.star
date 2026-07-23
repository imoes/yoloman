# Top-level helpers (no classes, no imports, no try/except)
def _parse_value(raw_value):
    return int(raw_value) / 10.0 if raw_value.isdigit() else None

def _parse_phase(raw_frequency, raw_voltage, raw_current):
    return {
        "frequency": _parse_value(raw_frequency),
        "voltage": _parse_value(raw_voltage),
        "current": _parse_value(raw_current),
    }

def _check_elphase(params, phase_data):
    # Map parameter keys used by Checkmk's el_inphase ruleset
    warn_voltage = params.get("voltage_low", 198.0)
    crit_voltage = params.get("voltage_critical_low", 180.0)
    warn_current = params.get("current_low", 0.0)
    crit_current = params.get("current_critical_low", 0.0)
    warn_frequency = params.get("frequency_low", 49.0)
    crit_frequency = params.get("frequency_critical_low", 47.0)
    # Voltage thresholds (upper bounds — warn/crit if <= thresholds)
    state = "OK"
    details_parts = []

    # Voltage
    voltage = phase_data.get("voltage")
    if voltage != None:
        details_parts.append("Voltage: %f V" % voltage)
        if voltage <= crit_voltage:
            state = "CRIT"
        elif voltage <= warn_voltage:
            state = "WARN" if state == "OK" else state
    else:
        details_parts.append("Voltage: N/A")
        state = "UNKNOWN"

    # Current
    current = phase_data.get("current")
    if current != None:
        details_parts.append("Current: %f A" % current)
        if current <= crit_current:
            state = "CRIT"
        elif current <= warn_current:
            state = "WARN" if state == "OK" else state
    else:
        details_parts.append("Current: N/A")
        state = "UNKNOWN"

    # Frequency
    frequency = phase_data.get("frequency")
    if frequency != None:
        details_parts.append("Frequency: %f Hz" % frequency)
        if frequency <= crit_frequency:
            state = "CRIT"
        elif frequency <= warn_frequency:
            state = "WARN" if state == "OK" else state
    else:
        details_parts.append("Frequency: N/A")
        state = "UNKNOWN"

    metrics = {}
    if voltage != None:
        metrics["voltage"] = voltage
    if current != None:
        metrics["current"] = current
    if frequency != None:
        metrics["frequency"] = frequency

    return state, ", ".join(details_parts), metrics

def main(ctx, params):
    # SNMP OID base and host/community defaults
    base_oid = ".1.3.6.1.4.1.2254.2.4.4"
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            base_oid,
        ], mutates=False)

        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse raw output lines into lines of 10 values (OID values only)
        # Expected: 1,2,3,4,5,6,7,8,9,10
        # Format: .1.3.6.1.4.1.2254.2.4.4.1 = INTEGER: 3
        #         .1.3.6.1.4.1.2254.2.4.4.2 = INTEGER: 2300
        #         ...
        lines = res.stdout.splitlines()
        parsed_lines = []
        i = 0
        while i < len(lines):
            # Look for lines starting with .1.3.6.1.4.1.2254.2.4.4.
            oid_vals = []
            j = i
            while j < len(lines) and len(oid_vals) < 10:
                line = lines[j].strip()
                if line.startswith(base_oid + "."):
                    # Extract value: split at " = " and take the second part
                    parts = line.split(" = ", 1)
                    if len(parts) == 2:
                        val_part = parts[1].strip()
                        # Strip "INTEGER: " prefix if present
                        if val_part.startswith("INTEGER: "):
                            val = val_part[9:].strip()
                        else:
                            val = val_part
                        oid_vals.append(val)
                j += 1
            if len(oid_vals) == 10:
                parsed_lines.append(oid_vals)
            i = j if j > i else i + 1  # avoid infinite loop

        discovery_items = []
        for idx, line in enumerate(parsed_lines):
            # line[0] = number of phases ("1" or "3")
            if idx == 0:  # Only first SNMP row yields items
                phases = int(line[0])
                # Phase 1 always present
                item = "Phase 1"
                suggested_params = {}
                metrics = ["voltage", "current", "frequency"]
                discovery_items.append({
                    "item": item,
                    "params": suggested_params,
                    "metrics": metrics,
                })
                if phases == 3:
                    discovery_items.append({
                        "item": "Phase 2",
                        "params": suggested_params,
                        "metrics": metrics,
                    })
                    discovery_items.append({
                        "item": "Phase 3",
                        "params": suggested_params,
                        "metrics": metrics,
                    })
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(discovery_items),
            "data": {"discovery": discovery_items},
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid,
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse SNMP walk into lines of 10 values
    lines = res.stdout.splitlines()
    parsed_lines = []
    i = 0
    while i < len(lines):
        oid_vals = []
        j = i
        while j < len(lines) and len(oid_vals) < 10:
            line = lines[j].strip()
            if line.startswith(base_oid + "."):
                parts = line.split(" = ", 1)
                if len(parts) == 2:
                    val_part = parts[1].strip()
                    if val_part.startswith("INTEGER: "):
                        val = val_part[9:].strip()
                    else:
                        val = val_part
                    oid_vals.append(val)
            j += 1
        if len(oid_vals) == 10:
            parsed_lines.append(oid_vals)
        i = j if j > i else i + 1

    if not parsed_lines:
        return {
            "changed": False,
            "msg": "no data received",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    first_line = parsed_lines[0]
    parsed = {}
    # Parse Phase 1 always
    phase1_data = _parse_phase(first_line[1], first_line[2], first_line[3])
    if phase1_data != None:
        parsed["Phase 1"] = phase1_data

    # Parse Phase 2/3 only if 3-phase
    if first_line[0] == "3":
        phase2_data = _parse_phase(first_line[4], first_line[5], first_line[6])
        if phase2_data != None:
            parsed["Phase 2"] = phase2_data
        phase3_data = _parse_phase(first_line[7], first_line[8], first_line[9])
        if phase3_data != None:
            parsed["Phase 3"] = phase3_data

    phase_data = parsed.get(item)
    if phase_data == None:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state, details, metrics = _check_elphase(params, phase_data)
    return {
        "changed": False,
        "msg": details,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }