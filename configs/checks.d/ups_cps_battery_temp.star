# Checkmk check: ups_cps_battery_temp
# Translated to a read-only Starlark check module for the yolo-man agent.
# This check monitors the battery temperature of a CyberPower (CPS) UPS via SNMP.

# --- Checkmk default parameters -------------------------------------------------
# TempParamType: warn/crit temperature thresholds in degrees Celsius.
DEFAULT_TEMP_PARAMS = {"warn": 50, "crit": 60}

# Base OID for the ups_cps_battery SNMP table (.1.3.6.1.4.1.3808.1.1.1.2.2)
# Sub-OIDs fetched: "1" (capacity), "3" (temperature), "4" (battime TimeTick)
BASE_OID = ".1.3.6.1.4.1.3808.1.1.1.2.2"
OID_CAPACITY = BASE_OID + ".1"
OID_TEMPERATURE = BASE_OID + ".3"
OID_BATTIME = BASE_OID + ".4"

# sysObjectID used by Checkmk's DETECT_UPS_CPS to identify a CPS UPS.
# DETECT_UPS_CPS = startswith(".1.3.6.1.2.1.1.2.0", ".1.3.6.1.4.1.3808.1.1.1")
SYS_OBJECT_ID_OID = ".1.3.6.1.2.1.1.2.0"
CPS_SYSOID_PREFIX = ".1.3.6.1.4.1.3808.1.1.1"


def _detect_cps_ups(ctx, params):
    """Probe for a CyberPower (CPS) UPS via SNMP sysObjectID."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYS_OBJECT_ID_OID],
        mutates=False,
    )
    if res.rc == 127:
        return False
    if res.rc != 0:
        return False
    value = res.stdout.strip()
    return value.startswith(CPS_SYSOID_PREFIX)


def _get_temperature(ctx, params):
    """Read the battery temperature (Celsius) via SNMP. Returns None if absent."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, OID_TEMPERATURE],
        mutates=False,
    )
    if res.rc == 127 or res.rc != 0:
        return None
    raw = res.stdout.strip()
    if raw == "" or raw == "NULL":
        return None
    return float(raw)


def _check_lower_levels(value, warn, crit):
    """Upper-level threshold grading: WARN if >= warn, CRIT if >= crit."""
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    if params.get("_discover"):
        # --- DISCOVERY MODE ---
        if not _detect_cps_ups(ctx, params):
            return {
                "changed": False,
                "msg": "no CPS UPS detected",
                "data": {"discovery": []},
            }
        temp = _get_temperature(ctx, params)
        if temp == None:
            return {
                "changed": False,
                "msg": "no CPS UPS temperature reported",
                "data": {"discovery": []},
            }
        discovery = [
            {
                "item": "Battery",
                "params": dict(DEFAULT_TEMP_PARAMS),
                "metrics": ["temperature"],
            }
        ]
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Re-verify the device is present; without it we cannot grade.
    if not _detect_cps_ups(ctx, params):
        return {
            "changed": False,
            "msg": "no CPS UPS detected",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "SNMP sysObjectID does not match a CyberPower CPS UPS",
            },
        }

    temp = _get_temperature(ctx, params)
    if temp == None:
        return {
            "changed": False,
            "msg": "no battery temperature reported",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "UPS battery temperature OID returned no value",
            },
        }

    warn = params.get("warn", DEFAULT_TEMP_PARAMS["warn"])
    crit = params.get("crit", DEFAULT_TEMP_PARAMS["crit"])
    state = _check_lower_levels(temp, warn, crit)

    return {
        "changed": False,
        "msg": "Temperature %s %f C" % (item, temp),
        "data": {
            "state": state,
            "metrics": {"temperature": temp},
            "details": "Battery temperature: %f C (warn >= %d, crit >= %d)" % (temp, warn, crit),
        },
    }