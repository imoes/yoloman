def main(ctx, params):
    # Constants for SNMP OIDs (from the Checkmk source)
    BASE_OID = ".1.3.6.1.4.1.34278"
    OID_MIB_TREE = [
        ".8",      # base device info
        ".1",      # rmsphase
        ".2",      # sumphase
        ".3",      # energy
        ".4",      # sumenergy
        ".5",      # ??
        ".6",      # ??
        ".7",      # ??
        ".8",      # misc (contains frequency)
    ]

    # Discovery mode: emit single service item "1"
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 frequency service(s)",
            "data": {
                "discovery": [
                    {
                        "item": "1",
                        "params": {"levels_lower": [0, 0]},
                        "metrics": ["in_freq"]
                    }
                ]
            },
        }

    # Check mode: gather frequency from SNMP
    item = params.get("item", "1")
    if item != "1":
        return {
            "changed": False,
            "msg": "no such frequency item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Fetch the misc section (OID .8) — contains frequency at first value
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        BASE_OID + ".8"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpwalk lines: "OID = STRING: value"
    freq_raw = None
    for line in res.stdout.splitlines():
        # Look for frequency (value at first line of .8 tree)
        # In practice, OID .1.3.6.1.4.1.34278.8.6.x or .8.8.x etc gives frequency in 0.01 Hz
        if line.strip().startswith(BASE_OID + ".8.6.1") or line.strip().startswith(BASE_OID + ".8.8.1"):
            parts = line.split(" = ")
            if len(parts) >= 2:
                val_part = parts[1].strip()
                # Extract integer after colon/space (e.g., "Integer32: 5000" or " Gauge32: 5000")
                if ":" in val_part:
                    val_str = val_part.split(":")[-1].strip()
                    if val_str.isdigit():
                        freq_raw = int(val_str)
                        break

    # Fallback: parse any line in .8 tree that yields an integer
    if freq_raw == None:
        for line in res.stdout.splitlines():
            parts = line.split(" = ")
            if len(parts) >= 2:
                val_part = parts[1].strip()
                val_str = None
                if ":" in val_part:
                    val_str = val_part.split(":")[-1].strip()
                elif " " in val_part:
                    val_str = val_part.split(" ")[-1].strip()
                if val_str and val_str.lstrip("-").isdigit():
                    freq_raw = int(val_str)
                    break

    if freq_raw == None:
        return {
            "changed": False,
            "msg": "could not parse frequency from SNMP",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Convert to Hz (frequency stored as centi-Hz: /100)
    freq_hz = float(freq_raw) / 100.0

    # Thresholds (levels_lower in Checkmk format: (warn, crit) lower bounds)
    levels_lower = params.get("levels_lower", [0, 0])
    warn = levels_lower[0] if len(levels_lower) >= 1 and levels_lower[0] != None else None
    crit = levels_lower[1] if len(levels_lower) >= 2 and levels_lower[1] != None else None

    # Determine state: lower levels -> CRIT if freq <= crit, WARN if freq <= warn
    state = "OK"
    if crit != None and freq_hz <= crit:
        state = "CRIT"
    elif warn != None and freq_hz <= warn:
        state = "WARN"

    # Build msg (Checkmk style)
    msg = "Frequency: %f Hz" % freq_hz
    if warn != None or crit != None:
        msg += ", thresholds: warn=%f/crit=%f" % (warn or 0, crit or 0)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"in_freq": freq_hz},
            "details": ""
        },
    }