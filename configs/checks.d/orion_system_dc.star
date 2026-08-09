# ===== check plugin: cmk/plugins/orion/agent_based/orion_system.py (translated) =====
# Translated Checkmk SNMP check "orion_system_dc" into a read-only Starlark check module.
# Monitors DC electrical phase (current/voltage/power) of an ElPhase device via SNMP.

# Sentinel value Checkmk uses for "no value available"
NO_VALUE = "2147483647"

# OID base for the Orion system electrical table
OID_BASE = ".1.3.6.1.4.1.20246.2.3.1.1.1.2.3"


def _is_digit_str(s):
    """Check if a string represents a valid integer (optional leading minus)."""
    if not s:
        return False
    digits = s[1:] if s[0] == "-" else s
    if len(digits) == 0:
        return False
    for c in digits:
        if c not in "0123456789":
            return False
    return True


def _snmp_get_string(ctx, community, host, oid):
    """Fetch a single SNMP scalar value. Returns bare value string or '' on error."""
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return ""
    return res.stdout.rstrip("\n").strip()


def _snmp_walk(ctx, community, host, oid):
    """Fetch an SNMP table. Returns dict {index_str: value_str}."""
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return {}
    out = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        # Format: "<full_oid> <value>"
        sp = line.find(" ")
        if sp == -1:
            continue
        full_oid = line[:sp]
        value = line[sp + 1:]
        # index is the part after the base oid + "."
        if full_oid.startswith(oid + "."):
            index = full_oid[len(oid) + 1:]
        else:
            continue
        out[index] = value
    return out


def _get_phase_value(raw, factor):
    if raw == NO_VALUE or raw == "":
        return None
    stripped = raw.strip()
    if not _is_digit_str(stripped):
        return None
    return int(stripped) * factor


def _detect_device(ctx, params):
    """Probe for the real Orion device via sysObjectID detection."""
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    sys_obj = _snmp_get_string(ctx, community, host, ".1.3.6.1.2.1.1.2.0")
    if not sys_obj or not sys_obj.startswith(".1.3.6.1.4.1.20246"):
        return None
    return (community, host)


def _read_section(ctx, params):
    """Fetch the full orion_system SNMP table row (oids 1..8 under base)."""
    detected = _detect_device(ctx, params)
    if detected == None:
        return None
    community, host = detected

    # Walk the column-1 values to get the indices, then fetch each column by index
    col1_vals = _snmp_walk(ctx, community, host, OID_BASE + ".1")
    if not col1_vals:
        return None

    cols = ["1", "2", "3", "4", "5", "6", "7", "8"]
    rows = []
    for index in col1_vals:
        row = []
        valid = True
        for col in cols:
            val = _snmp_get_string(ctx, community, host, OID_BASE + "." + col + "." + index)
            if val == "" and col1_vals.get(index, "") == "":
                valid = False
                break
            row.append(val)
        if not valid:
            continue
        rows.append(row)

    if not rows:
        return None
    return rows


def _build_electrical(ctx, params):
    """Reproduce parse_orion_system's electrical dict construction."""
    rows = _read_section(ctx, params)
    if rows == None:
        return None

    # Take the first row (string_table[0])
    row = rows[0]
    (
        system_voltage,
        load_current,
        battery_current,
        battery_temp,
        charge_state,
        _battery_current_limit,
        rectifier_current,
        system_power,
    ) = row

    electrical = {}

    # System voltage/current/power
    sys_data = {}
    v = _get_phase_value(system_voltage, 0.01)
    c = _get_phase_value(load_current, 0.1)
    p = _get_phase_value(system_power, 1.0)
    if v != None:
        sys_data["voltage"] = v
    if c != None:
        sys_data["current"] = c
    if p != None:
        sys_data["power"] = p
    if sys_data:
        electrical["System"] = sys_data

    # Battery current
    bc = _get_phase_value(battery_current, 0.1)
    if bc != None:
        electrical.setdefault("Battery", {})["current"] = bc

    # Rectifier current
    rc = _get_phase_value(rectifier_current, 0.1)
    if rc != None:
        electrical.setdefault("Rectifier", {})["current"] = rc

    return electrical


def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        electrical = _build_electrical(ctx, params)
        if electrical == None or len(electrical) == 0:
            return {
                "changed": False,
                "msg": "no Orion DC electrical data found",
                "data": {"discovery": []},
            }
        discovery = []
        for entity in electrical:
            metrics = []
            phase = electrical[entity]
            if "voltage" in phase:
                metrics.append("voltage")
            if "current" in phase:
                metrics.append("current")
            if "power" in phase:
                metrics.append("power")
            discovery.append({
                "item": entity,
                "params": {},
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d DC phases" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK MODE ----
    item = params.get("item", "")
    electrical = _build_electrical(ctx, params)
    if electrical == None:
        return {
            "changed": False,
            "msg": "no Orion DC electrical data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    phase = electrical.get(item)
    if phase == None:
        return {
            "changed": False,
            "msg": "no data for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Apply threshold logic for each available metric
    # Default thresholds from ups_outphase ruleset (Checkmk defaults)
    voltage_warn = params.get("voltage_warn", None)
    voltage_crit = params.get("voltage_crit", None)
    current_warn = params.get("current_warn", None)
    current_crit = params.get("current_crit", None)
    power_warn = params.get("power_warn", None)
    power_crit = params.get("power_crit", None)

    metrics_out = {}
    states = []
    detail_parts = []

    if "voltage" in phase:
        v = phase["voltage"]
        metrics_out["voltage"] = v
        detail_parts.append("Voltage: %f V" % v)
        if voltage_warn != None and v >= voltage_warn:
            states.append("WARN")
        if voltage_crit != None and v >= voltage_crit:
            states.append("CRIT")

    if "current" in phase:
        c = phase["current"]
        metrics_out["current"] = c
        detail_parts.append("Current: %f A" % c)
        if current_warn != None and c >= current_warn:
            states.append("WARN")
        if current_crit != None and c >= current_crit:
            states.append("CRIT")

    if "power" in phase:
        p = phase["power"]
        metrics_out["power"] = p
        detail_parts.append("Power: %f W" % p)
        if power_warn != None and p >= power_warn:
            states.append("WARN")
        if power_crit != None and p >= power_crit:
            states.append("CRIT")

    if "CRIT" in states:
        state = "CRIT"
    elif "WARN" in states:
        state = "WARN"
    else:
        state = "OK"

    details = "; ".join(detail_parts)

    return {
        "changed": False,
        "msg": details,
        "data": {"state": state, "metrics": metrics_out, "details": details},
    }