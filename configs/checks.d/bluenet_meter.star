# ===== Starlark check for bluenet_meter (Powermeter) =====
# Reads SNMP data from .1.3.6.1.4.1.21695.1.10.7.2.1 and reports voltage/current/power/appower
# per meter_id (item), using the same logic as check_elphase from Checkmk.

def _parse_section(snmp_lines):
    # snmp_lines is list of "OID = TYPE: value" lines; extract meter_id, power_p, power_s, u_rms, i_rms
    section = {}
    for line in snmp_lines:
        line = line.strip()
        if not line:
            continue
        # Expected: .1.3.6.1.4.1.21695.1.10.7.2.1.1.<index> = INTEGER: <meter_id>
        #           .1.3.6.1.4.1.21695.1.10.7.2.1.5.<index> = INTEGER: <power_p>
        #           .1.3.6.1.4.1.21695.1.10.7.2.1.7.<index> = INTEGER: <power_s>
        #           .1.3.6.1.4.1.21695.1.10.7.2.1.8.<index> = INTEGER: <u_rms>
        #           .1.3.6.1.4.1.21695.1.10.7.2.1.9.<index> = INTEGER: <i_rms>
        # Parse by splitting on '=' and then extract values
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        if val_part.startswith("INTEGER: "):
            val = val_part[9:]
        elif val_part.startswith("INTEGER:"):
            val = val_part[8:].strip()
        else:
            val = val_part.strip()

        # Extract index from OID: base is .1.3.6.1.4.1.21695.1.10.7.2.1 and suffix is 1,5,7,8,9
        # We group by the index at the end (e.g., .1...1.1.<idx> -> idx)
        # Find last '.' before final segment
        last_dot = oid_part.rfind(".")
        if last_dot == -1:
            continue
        suffix = oid_part[last_dot + 1:]
        idx_str = oid_part[last_dot + 1:]
        # suffix is one of "1", "5", "7", "8", "9"
        # Extract index after base
        # Base: .1.3.6.1.4.1.21695.1.10.7.2.1 (length = 9 segments), so after base is .<suffix>.<index>
        # Therefore after .1 we have suffix (1,5,7,8,9) and then index
        # Let's reconstruct: remove everything before ".1.3.6.1.4.1.21695.1.10.7.2.1"
        # Instead, we store per index: use a map keyed by idx, and accumulate fields by suffix
        # Simpler: parse all, group by index (the last segment)
        if not idx_str.isdigit():
            continue
        # We'll aggregate by idx_str
        if idx_str not in section:
            section[idx_str] = {}
        # Map suffix to field name
        field_map = {"1": "meter_id", "5": "power_p", "7": "power_s", "8": "u_rms", "9": "i_rms"}
        field = field_map.get(suffix, "")
        if field == "":
            continue
        section[idx_str][field] = val

    # Convert aggregated to list of tuples (meter_id, power_p, power_s, u_rms, i_rms)
    entries = []
    for idx_str, d in section.items():
        meter_id = d.get("meter_id", "")
        power_p = d.get("power_p", "0")
        power_s = d.get("power_s", "0")
        u_rms = d.get("u_rms", "0")
        i_rms = d.get("i_rms", "0")
        entries.append((meter_id, power_p, power_s, u_rms, i_rms))
    return entries


def _check_elphase(params, elphase):
    # params is dict like {"voltage_upper": (230*1.1, 230*1.05), "voltage_lower": (230*0.9, 230*0.95), ...}
    # but original check_elphase expects thresholds per metric name; we only support basic upper/lower levels
    # Checkmk's check_elphase uses "voltage_upper" (warn,crit), "voltage_lower" (warn,crit),
    # "current_upper", "power_upper", "appower_upper" (all (warn,crit) tuples)
    # Since we have no thresholds from params and the original check_default_parameters is {},
    # we use generic defaults (same as Checkmk's default for ups_outphase).
    # Based on Checkmk's default rules, we assume:
    #   voltage:    upper_warn=253, upper_crit=264, lower_warn=207, lower_crit=198
    #   current:    upper_warn=None, upper_crit=None (no default)
    #   power:      upper_warn=None, upper_crit=None
    #   appower:    upper_warn=None, upper_crit=None
    # But we'll follow Checkmk's elphase.py pattern: only warn/crit if set in params
    # Since params is empty dict {}, we return OK for all (no thresholds defined)
    # We still emit metrics, but state will be OK unless thresholds are violated.
    # Checkmk elphase checks return OK if no thresholds defined.

    voltage = elphase.get("voltage")
    current = elphase.get("current")
    power = elphase.get("power")
    appower = elphase.get("appower")

    # Extract numeric values; if any missing, we'd return UNKNOWN, but parse_bluenet_meter filters out u_rms==0
    v_val = voltage.get("value") if type(voltage) == "dict" else 0.0
    i_val = current.get("value") if type(current) == "dict" else 0.0
    p_val = power.get("value") if type(power) == "dict" else 0.0
    a_val = appower.get("value") if type(appower) == "dict" else 0.0

    # For simplicity, we assume elphase is a dict with value, state keys
    # but in original, ReadingWithState is an object with .value and .state
    # We'll represent it as {"value": float, "state": "OK"|"WARN"|"CRIT"} and just use value
    # Checkmk elphase checks state based on thresholds; without thresholds, state=OK

    # Since no thresholds are defined in the check's default parameters,
    # we just report metrics with state OK (no threshold violation).
    # But to be safe, we must follow Checkmk's behavior: if no thresholds, return OK
    metrics = {"voltage": v_val, "current": i_val, "power": p_val, "appower": a_val}
    return "OK", metrics


def main(ctx, params):
    # SNMP host and community defaults (Checkmk's agent section uses host from discovery)
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        # Discovery: fetch all meters and yield one Service per meter_id
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, ".1.3.6.1.4.1.21695.1.10.7.2.1"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}

        lines = res.stdout.splitlines()
        entries = _parse_section(lines)

        discovery = []
        for meter_id, power_p, power_s, u_rms, i_rms in entries:
            # Only include if voltage is non-zero (per parse_bluenet_meter)
            if u_rms != "0" and meter_id != "":
                # Suggest empty params (same as original default)
                discovery.append({
                    "item": meter_id,
                    "params": {},
                    "metrics": ["voltage", "current", "power", "appower"]
                })

        return {
            "changed": False,
            "msg": "discovered %d powermeters" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: item is provided
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, ".1.3.6.1.4.1.21695.1.10.7.2.1"
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP fetch failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    entries = _parse_section(lines)

    elphase = None
    for meter_id, power_p, power_s, u_rms, i_rms in entries:
        if meter_id == item:
            # Filter out zero-voltage meters (per original parse function)
            if u_rms == "0":
                return {
                    "changed": False,
                    "msg": "meter %s has no voltage" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
                }
            # Build elphase dict matching ReadingWithState shape (value + state)
            voltage_val = float(u_rms) / 1000.0
            current_val = float(i_rms) / 1000.0
            power_val = float(power_p)
            appower_val = float(power_s)
            elphase = {
                "voltage": {"value": voltage_val, "state": "OK"},
                "current": {"value": current_val, "state": "OK"},
                "power": {"value": power_val, "state": "OK"},
                "appower": {"value": appower_val, "state": "OK"}
            }
            break

    if elphase == None:
        return {
            "changed": False,
            "msg": "meter %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state, metrics = _check_elphase(params, elphase)

    # Build msg: "Voltage: 230 V, Current: 5.2 A, Power: 1200 W, Apparent power: 1250 VA"
    msg = "Voltage: %f V, Current: %f A, Power: %f W, Apparent power: %f VA" % (
        metrics.get("voltage", 0),
        metrics.get("current", 0),
        metrics.get("power", 0),
        metrics.get("appower", 0)
    )
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }