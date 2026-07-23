def main(ctx, params):
    # Checkmk blade_blowers check: per-blower monitoring via SNMP
    # Discovery yields services like "1/2", "2/2" for each functional blower.
    # Check mode: examine one item, report OK if state is "1", else CRIT, plus RPM and % metrics.

    # Module-level constant for SNMP base OID
    BLADE_BASE_OID = ".1.3.6.1.4.1.2.3.51.2.2"

    if params.get("_discover"):
        # Discover how many blowers exist by checking blowerState entries
        # OIDs: .1.3.6.1.4.1.2.3.51.2.2.3.<i>.0 for i=1..n
        blowers = []
        i = 1
        while i <= 16:
            state_oid = BLADE_BASE_OID + ".3." + str(i) + ".0"
            res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                           "-On", params.get("host", "localhost"), state_oid], mutates=False)
            if res.rc != 0:
                break
            # Parse: '<OID> = STRING: "<value>"'
            line = res.stdout.strip()
            # Extract value: split on '=' then strip and remove quotes
            eq_idx = line.find("=")
            if eq_idx == -1:
                break
            value_part = line[eq_idx + 1:].strip()
            # Remove quotes if present
            if value_part.startswith('"') and value_part.endswith('"'):
                value_part = value_part[1:-1]
            # Stop when we see "0" or "unknown" (non-existent or unknown state)
            if value_part == "0":
                i += 1
                continue
            # If we get here, we found a real blower entry
            blowers.append(i)
            i += 1
        n = len(blowers)
        discovery_items = []
        for idx in range(1, n + 1):
            # Skip if state is "0" (unknown/missing)
            state_oid = BLADE_BASE_OID + ".3." + str(idx) + ".0"
            res_state = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                                 "-On", params.get("host", "localhost"), state_oid], mutates=False)
            if res_state.rc != 0:
                continue
            line = res_state.stdout.strip()
            eq_idx = line.find("=")
            if eq_idx == -1:
                continue
            value = line[eq_idx + 1:].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            if value == "0":
                continue
            # Build item like "1/3"
            item = str(idx) + "/" + str(n)
            discovery_items.append({"item": item, "params": {}, "metrics": ["rpm", "perc"]})
        return {"changed": False, "msg": "discovered %d blowers" % n,
                "data": {"discovery": discovery_items}}

    # Check mode: item is "idx/total"
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "item not specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parts = item.split("/")
    if len(parts) != 2:
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    blower_idx_str = parts[0]
    num_blowers_str = parts[1]
    if not blower_idx_str.isdigit() or not num_blowers_str.isdigit():
        return {"changed": False, "msg": "item must be like '1/2'",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    blower_idx = int(blower_idx_str)
    num_blowers = int(num_blowers_str)

    # Fetch required OIDs:
    # speed OID: .3.<i>.0
    speed_oid = BLADE_BASE_OID + ".3." + str(blower_idx) + ".0"
    res_speed = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), speed_oid], mutates=False)
    
    # state OID: .10.<i>.0
    state_oid = BLADE_BASE_OID + ".10." + str(blower_idx) + ".0"
    res_state = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                         "-On", params.get("host", "localhost"), state_oid], mutates=False)
    
    # rpm OID: .20.<i>.0
    rpm_oid = BLADE_BASE_OID + ".20." + str(blower_idx) + ".0"
    res_rpm = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"),
                       "-On", params.get("host", "localhost"), rpm_oid], mutates=False)

    # Parse speed string
    speed_val = ""
    if res_speed.rc == 0:
        line = res_speed.stdout.strip()
        eq_idx = line.find("=")
        if eq_idx != -1:
            value = line[eq_idx + 1:].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            speed_val = value

    # Parse state
    state_str = ""
    if res_state.rc == 0:
        line = res_state.stdout.strip()
        eq_idx = line.find("=")
        if eq_idx != -1:
            value = line[eq_idx + 1:].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            state_str = value

    # Parse RPM
    rpm_val = ""
    if res_rpm.rc == 0:
        line = res_rpm.stdout.strip()
        eq_idx = line.find("=")
        if eq_idx != -1:
            value = line[eq_idx + 1:].strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            rpm_val = value

    # Build output and metrics
    output_parts = []
    metrics = {}

    # Extract percentage from speed_val if present and contains "%"
    if speed_val != "" and speed_val.find("%") != -1:
        # Split on "%" and get the number part
        parts_speed = speed_val.split("%", 1)
        if len(parts_speed) == 2 and parts_speed[0].isdigit():
            perc = int(parts_speed[0])
            output_parts.append("Speed is at %d%% of max" % perc)
            metrics["perc"] = perc

    # Extract RPM
    if rpm_val != "" and rpm_val.isdigit():
        rpm = int(rpm_val)
        if len(output_parts) > 0:
            output_parts[-1] += " (%d RPM)" % rpm
        else:
            output_parts.append("Speed at %d RPM" % rpm)
        metrics["rpm"] = rpm

    # Determine state
    final_state = "CRIT"
    if state_str == "1" or state_str == "good":
        final_state = "OK"

    # Construct summary
    if len(output_parts) > 0:
        summary = "; ".join(output_parts)
    else:
        summary = "Blower %d state: %s" % (blower_idx, state_str if state_str != "" else "unknown")

    return {"changed": False,
            "msg": summary,
            "data": {"state": final_state, "metrics": metrics, "details": ""}}
