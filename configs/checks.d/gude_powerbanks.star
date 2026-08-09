# ===== Starlark check module: gude_powerbanks =====
# Translated from Checkmk plugin cmk.plugins.gude.agent_based.gude_powerbanks.py
# Read-only: never mutates, only discovers and checks powerbank states and metrics.

_PORT_STATES = {
    "0": ("CRIT", "off"),
    "1": ("OK", "on"),
}

_CHANNEL_STATES = {
    "0": ("CRIT", "data not active"),
    "1": ("OK", "data valid"),
}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: walk both SNMPTree bases to gather port and powerbank data

        # Table 19: port states
        res19_ports = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.28507.19.1.3.1.2.1"
        ], mutates=False)

        # Table 19 power metrics (dev_state, energy, active_power, current, volt, freq, appower)
        res19_met = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.28507.19.1.5.1.2.1"
        ], mutates=False)

        # Table 38: dev_state metrics
        res38_met = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.28507.38.1.5.1.2.1"
        ], mutates=False)

        # Parse port states for table 19
        port19 = {}
        for line in res19_ports.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_parts = parts[1].strip().split(": ")
            if len(value_parts) < 2:
                continue
            idx = oid.rsplit(".", 1)[-1]
            port19[idx] = value_parts[1].strip()

        # Parse power metrics for table 19
        met19 = {}
        for line in res19_met.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_parts = parts[1].strip().split(": ")
            if len(value_parts) < 2:
                continue
            raw_vals = value_parts[1].strip()
            fields = raw_vals.split(",")
            if len(fields) < 7:
                continue
            idx = oid.rsplit(".", 1)[-1]
            # Clean whitespace from fields
            for i in range(len(fields)):
                fields[i] = fields[i].strip()
            # Validate numeric fields before storing
            # fields[0] is dev_state (string), fields[1..6] are numbers
            valid = True
            for i in range(1, 7):
                field_val = fields[i]
                if field_val == "" or field_val == None:
                    valid = False
                    break
            if valid:
                met19[idx] = {
                    "dev_state": fields[0],
                    "energy": float(fields[1]),
                    "active_power": float(fields[2]),
                    "current": float(fields[3]),
                    "volt": float(fields[4]),
                    "freq": float(fields[5]),
                    "appower": float(fields[6])
                }

        # Parse power metrics for table 38
        met38 = {}
        for line in res38_met.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid = parts[0].strip()
            value_parts = parts[1].strip().split(": ")
            if len(value_parts) < 2:
                continue
            raw_vals = value_parts[1].strip()
            fields = raw_vals.split(",")
            if len(fields) < 7:
                continue
            idx = oid.rsplit(".", 1)[-1]
            for i in range(len(fields)):
                fields[i] = fields[i].strip()
            # Validate numeric fields before storing
            valid = True
            for i in range(1, 7):
                field_val = fields[i]
                if field_val == "" or field_val == None:
                    valid = False
                    break
            if valid:
                met38[idx] = {
                    "dev_state": fields[0],
                    "energy": float(fields[1]),
                    "active_power": float(fields[2]),
                    "current": float(fields[3]),
                    "volt": float(fields[4]),
                    "freq": float(fields[5]),
                    "appower": float(fields[6])
                }

        # Discover active powerbanks
        discovery = []
        all_indices = set(port19.keys()) | set(met19.keys()) | set(met38.keys())

        for idx in all_indices:
            state_name = ""
            # Check table 19 (port-based)
            if idx in port19 and idx in met19:
                port_state = port19[idx]
                if port_state in _PORT_STATES:
                    state_name = _PORT_STATES[port_state][1]
            # Check table 38 (channel-based)
            elif idx in met38:
                dev_state_raw = met38[idx].get("dev_state", "0")
                if dev_state_raw in _CHANNEL_STATES:
                    state_name = _CHANNEL_STATES[dev_state_raw][1]

            # If state is not inactive, discover
            if state_name != "off" and state_name != "data not active" and state_name != "":
                discovery.append({
                    "item": idx,
                    "params": {
                        "voltage": [220, 210],
                        "current": [15, 16]
                    },
                    "metrics": ["voltage", "current", "power", "energy", "frequency", "appower"]
                })

        return {
            "changed": False,
            "msg": "discovered %d powerbanks" % len(discovery),
            "data": {"discovery": discovery}
        }

    # Check mode: check one item (powerbank idx)
    item = params.get("item", "")

    # Re-fetch data for this item
    # Table 19: port states
    res19_ports = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.28507.19.1.3.1.2.1"
    ], mutates=False)

    # Table 19 power metrics
    res19_met = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.28507.19.1.5.1.2.1"
    ], mutates=False)

    # Table 38 power metrics
    res38_met = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.28507.38.1.5.1.2.1"
    ], mutates=False)

    # Parse port states for table 19
    port19 = {}
    for line in res19_ports.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        value_parts = parts[1].strip().split(": ")
        if len(value_parts) < 2:
            continue
        idx = oid.rsplit(".", 1)[-1]
        port19[idx] = value_parts[1].strip()

    # Parse power metrics for table 19
    met19 = {}
    for line in res19_met.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        value_parts = parts[1].strip().split(": ")
        if len(value_parts) < 2:
            continue
        raw_vals = value_parts[1].strip()
        fields = raw_vals.split(",")
        if len(fields) < 7:
            continue
        idx = oid.rsplit(".", 1)[-1]
        for i in range(len(fields)):
            fields[i] = fields[i].strip()
        # Validate numeric fields before storing
        valid = True
        for i in range(1, 7):
            field_val = fields[i]
            if field_val == "" or field_val == None:
                valid = False
                break
        if valid:
            met19[idx] = {
                "dev_state": fields[0],
                "energy": float(fields[1]),
                "active_power": float(fields[2]),
                "current": float(fields[3]),
                "volt": float(fields[4]),
                "freq": float(fields[5]),
                "appower": float(fields[6])
            }

    # Parse power metrics for table 38
    met38 = {}
    for line in res38_met.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid = parts[0].strip()
        value_parts = parts[1].strip().split(": ")
        if len(value_parts) < 2:
            continue
        raw_vals = value_parts[1].strip()
        fields = raw_vals.split(",")
        if len(fields) < 7:
            continue
        idx = oid.rsplit(".", 1)[-1]
        for i in range(len(fields)):
            fields[i] = fields[i].strip()
        # Validate numeric fields before storing
        valid = True
        for i in range(1, 7):
            field_val = fields[i]
            if field_val == "" or field_val == None:
                valid = False
                break
        if valid:
            met38[idx] = {
                "dev_state": fields[0],
                "energy": float(fields[1]),
                "active_power": float(fields[2]),
                "current": float(fields[3]),
                "volt": float(fields[4]),
                "freq": float(fields[5]),
                "appower": float(fields[6])
            }

    # Determine device state and gather metrics
    device_state = ""
    state_name = ""
    energy = 0.0
    active_power = 0.0
    current = 0.0
    volt = 0.0
    freq = 0.0
    appower = 0.0

    # Check table 19 first
    if item in port19 and item in met19:
        port_state = port19[item]
        if port_state in _PORT_STATES:
            state_name = _PORT_STATES[port_state][1]
            device_state = _PORT_STATES[port_state][0]
            if state_name == "on":
                data = met19[item]
                energy = data.get("energy", 0.0)
                active_power = data.get("active_power", 0.0)
                current = data.get("current", 0.0) * 0.001
                volt = data.get("volt", 0.0)
                freq = data.get("freq", 0.0) * 0.01
                appower = data.get("appower", 0.0)
        else:
            return {
                "changed": False,
                "msg": "item not found or invalid port state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    elif item in met38:
        dev_state_raw = met38[item].get("dev_state", "0")
        if dev_state_raw in _CHANNEL_STATES:
            state_name = _CHANNEL_STATES[dev_state_raw][1]
            device_state = _CHANNEL_STATES[dev_state_raw][0]
            if state_name == "data valid":
                data = met38[item]
                energy = data.get("energy", 0.0)
                active_power = data.get("active_power", 0.0)
                current = data.get("current", 0.0) * 0.001
                volt = data.get("volt", 0.0)
                freq = data.get("freq", 0.0) * 0.01
                appower = data.get("appower", 0.0)
        else:
            return {
                "changed": False,
                "msg": "item not found or invalid dev_state",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    else:
        return {
            "changed": False,
            "msg": "item not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Apply thresholds from params
    warn_voltage = 220.0
    crit_voltage = 210.0
    warn_current = 15.0
    crit_current = 16.0

    if "voltage" in params:
        v = params["voltage"]
        if isinstance(v, list) and len(v) >= 2:
            warn_voltage = v[0]
            crit_voltage = v[1]

    if "current" in params:
        c = params["current"]
        if isinstance(c, list) and len(c) >= 2:
            warn_current = c[0]
            crit_current = c[1]

    # Determine state and build metrics
    state = "OK"
    metrics = {}
    details = []

    # Voltage: upper levels
    metrics["voltage"] = volt
    if volt >= crit_voltage:
        state = "CRIT"
    elif volt >= warn_voltage:
        state = "WARN"
    details.append("Voltage: %f V" % volt)

    # Current: upper levels
    metrics["current"] = current
    if current >= crit_current:
        state = "CRIT"
    elif current >= warn_current:
        state = "WARN"
    details.append("Current: %f A" % current)

    # Power
    metrics["power"] = active_power
    details.append("Power: %f W" % active_power)

    # Energy
    metrics["energy"] = energy
    details.append("Energy: %f kWh" % energy)

    # Frequency
    metrics["frequency"] = freq
    details.append("Frequency: %f Hz" % freq)

    # Apparent power
    metrics["appower"] = appower
    details.append("Apparent power: %f VA" % appower)

    # Device state (override state if needed)
    if device_state != "OK":
        state = "CRIT"
    details.append("Device: %s" % state_name)

    return {
        "changed": False,
        "msg": ", ".join(details),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }