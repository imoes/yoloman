# ===== Starlark check module: climaveneta_alarm =====
# Discovery: single-service (no item)
# Check: examine alarm status, report OK or CRIT per alarm

climaveneta_alarms = {
    21: "Maintenance Status",
    22: "Password",
    23: "High water 1erature",
    24: "High water 2erature",
    25: "Low room humidity",
    26: "High room humidity",
    27: "Low Roomerature",
    28: "High roomerature",
    29: "High air inleterature",
    30: "High air outleterature",
    31: "Room humid probe",
    32: "Room probe",
    33: "Inlet 1 probe",
    34: "Inlet 2 probe",
    35: "Inlet 3 probe",
    36: "Inlet 4 probe",
    37: "Outlet 1 probe",
    38: "Outlet 2 probe",
    39: "Outlet 3 probe",
    40: "Outlet 4 probe",
    41: "Water 1erature probe",
    42: "Water 2erature probe",
    43: "Door open",
    44: "EEPROM",
    45: "Fan 1 disconnected",
    46: "Fan 2 disconnected",
    47: "Fan 3 disconnected",
    48: "Fan 4 disconnected",
    49: "Dew point",
    50: "Flooding",
    51: "LAN",
    52: "Dirty filter",
    53: "Electronic thermostatic valve",
    54: "Low pressure",
    55: "High pressure",
    56: "Air flow",
    57: "Fire smoke",
    58: "I/O expansion",
    59: "Inverter",
    60: "Envelop",
    61: "Polygon inconsistent",
    62: "Delta pressure for inverter compressor",
    63: "Primary power supply",
    64: "Energy managment",
    65: "Low current humidif",
    66: "No water humidif",
    67: "High current humidif",
    68: "Humidifier Board Offline",
    69: "Life timer expired Reset/Clean cylinder",
    70: "Humidifier Drain",
    71: "Generic Humidifier",
    72: "Electric heater",
}


def main(ctx, params):
    # Discovery mode: single-service check (no item)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: examine alarms via SNMP
    res = ctx.run(
        ["snmpwalk", "-On", "-v2c", "-c", ctx.facts().get("snmp_comm", "public"), "localhost",
         ".1.3.6.1.4.1.9839.2.1"],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    hit = False
    summary = ""
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Expected format: OID . N = STRING: "value"
        # e.g. .1.3.6.1.4.1.9839.2.1.21.0 = STRING: "1"
        parts = stripped.split(" = ")
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        # Extract integer from OID suffix (e.g., ".1.3.6.1.4.1.9839.2.1.21.0" -> "21")
        suffix = oid_part.rsplit(".", 1)
        if len(suffix) != 2:
            continue
        oid_id = suffix[0]
        # Last numeric component is alarm_id
        last_seg = oid_id.rsplit(".", 1)
        if len(last_seg) != 2:
            continue
        # Guard: ensure segment is numeric before conversion
        if not last_seg[1].isdigit():
            continue
        alarm_id = int(last_seg[1])

        # Extract status from value_part (e.g., 'STRING: "1"' -> "1")
        status = ""
        if value_part.startswith('STRING: "'):
            status = value_part[8:-1]  # strip 'STRING: "' and trailing '"'
        else:
            # fallback for raw numeric
            status = value_part.strip()

        if alarm_id in climaveneta_alarms and status != "0":
            hit = True
            summary = "Alarm: " + climaveneta_alarms[alarm_id]
            break  # first alarm suffices for CRIT

    if hit:
        state = "CRIT"
        msg = summary
    else:
        state = "OK"
        msg = "No alarm state"

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": {}, "details": ""},
    }
