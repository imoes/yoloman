# climaveneta_alarm — Checkmk SNMP alarm check, translated to read-only Starlark.
# Monitors a Climaveneta pCO Gateway's alarm table over SNMP.

# Alarm ID -> human-readable name (mirrors the Checkmk source table).
ALARM_NAMES = {
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

# Base OID of the climaveneta alarm table (index 2 of the SNMPTree base).
ALARM_BASE_OID = ".1.3.6.1.4.1.9839.2.1"


def _is_gateway(ctx, params):
    """Probe for the Climaveneta pCO Gateway via sysDescr."""
    res = ctx.run(
        [
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Ovqn",
            params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.1.0",
        ],
        mutates=False,
    )
    if res.rc != 0:
        return False
    return res.stdout.find("pCO Gateway") != -1


def _walk_alarm_table(ctx, params):
    """Walk the alarm table; return list of (alarm_id_str, status_str)."""
    res = ctx.run(
        [
            "snmpwalk", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqn",
            params.get("host", "localhost"),
            ALARM_BASE_OID + ".1",
        ],
        mutates=False,
    )
    rows = []
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        # Each line: "<OID>.<index> <value>"
        sp = idx_of_first_space(line)
        if sp < 0:
            continue
        oid_part = line[:sp]
        value = line[sp + 1:]
        # alarm_id is the trailing numeric component of the OID suffix.
        suffix = oid_part[len(ALARM_BASE_OID) + 1:]
        alarm_id_str = suffix
        rows.append((alarm_id_str, value))
    return rows


def idx_of_first_space(s):
    i = 0
    for ch in s:
        if ch == " ":
            return i
        i += 1
    return -1


def _check_alarm_rows(rows):
    """Grade the alarm rows; return (state, summary_lines, crit_count)."""
    summ = []
    crit_count = 0
    for alarm_id_str, status in rows:
        id_str = alarm_id_str.split(".")[0]
        if id_str.isdigit():
            alarm_id = int(id_str)
            if alarm_id in ALARM_NAMES:
                if status != "0":
                    crit_count += 1
                    summ.append("Alarm: %s" % ALARM_NAMES[alarm_id])
    if crit_count == 0:
        return ("OK", ["No alarm state"], 0)
    return ("CRIT", summ, crit_count)


def main(ctx, params):
    # ---- Discovery mode ----
    if params.get("_discover"):
        if not _is_gateway(ctx, params):
            return {
                "changed": False,
                "msg": "no Climaveneta pCO Gateway detected",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["alarm_count"],
                        "service_labels": {
                            "cmk/device_family": "Climaveneta",
                            "cmk/gateway_model": "pCO Gateway",
                        },
                    }
                ],
                "host_labels": {
                    "cmk/vendor": "Climaveneta",
                    "cmk/product": "pCO Gateway",
                },
            },
        }

    # ---- Check mode (single-service check, item "") ----
    if not _is_gateway(ctx, params):
        return {
            "changed": False,
            "msg": "no Climaveneta pCO Gateway detected (not installed on host)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Climaveneta pCO Gateway not reachable via SNMP; sysDescr is not 'pCO Gateway'.",
            },
        }

    rows = _walk_alarm_table(ctx, params)
    if len(rows) == 0:
        return {
            "changed": False,
            "msg": "no alarm data retrieved",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP walk of %s returned no rows." % (ALARM_BASE_OID + ".1"),
            },
        }

    state, summ, crit_count = _check_alarm_rows(rows)
    details = "\n".join(summ)
    return {
        "changed": False,
        "msg": "; ".join(summ),
        "data": {
            "state": state,
            "metrics": {"alarm_count": crit_count},
            "details": details,
        },
    }