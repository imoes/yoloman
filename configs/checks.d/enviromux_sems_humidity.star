# Checkmk check: enviromux_sems_humidity
# Translated to a read-only Starlark check module.
#
# This check monitors humidity sensors on an Enviromux SEMS device via SNMP.
# Discovery enumerates humidity-type sensors; the check grades each against
# warn/crit thresholds (default: 30 / 70 percent, the typical Enviromux humidity
# defaults surfaced through the "humidity" ruleset).

# Sensor type codes from the Enviromux MIB (cmk/plugins/enviromux/lib.py).
SENSOR_TYPE_NAMES = {
    "0": "undefined", "1": "temperature", "2": "humidity", "3": "power",
    "4": "lowVoltage", "5": "current", "6": "aclmvVoltage", "7": "aclmpVoltage",
    "8": "aclmpPower", "9": "water", "10": "smoke", "11": "vibration",
    "12": "motion", "13": "glass", "14": "door", "15": "keypad",
    "16": "panicButton", "17": "keyStation", "18": "digInput", "22": "light",
    "24": "dewpoint", "26": "tacDio", "36": "acVoltage", "37": "acCurrent",
    "38": "dcVoltage", "39": "dcCurrent", "41": "rmsVoltage", "42": "rmsCurrent",
    "43": "activePower", "44": "reactivePower", "513": "tempHum",
    "32767": "custom", "32769": "temperatureCombo", "32770": "humidityCombo",
    "540": "tempHum",
}

# Per-value scaling: temperature, power, current and temperatureCombo are
# reported with a factor of 10 in the Enviromux MIB and must be divided by 10.
# Humidity sensors are reported in percent (no scaling).
SCALED_TYPES = ["temperature", "power", "current", "temperatureCombo"]

# Base OID for the enviromux_sems sensor table (intSensorValue column etc.).
SENSOR_BASE_OID = ".1.3.6.1.4.1.3699.1.1.2.1.4.1.1"

# The sysoid prefix that identifies an Enviromux SEMS device
# (DETECT_ENVIROMUX_SEMS). Used to confirm the product is actually present.
ENVIROMUX_SEMS_SYSOID_PREFIX = ".1.3.6.1.4.1.3699.1.1.2"

# Column OIDs (relative to SENSOR_BASE_OID) fetched by the SNMPTree.
COL_SENSOR_INDEX = "1"
COL_SENSOR_TYPE = "2"
COL_SENSOR_DESCRIPTION = "3"
COL_SENSOR_VALUE = "6"
COL_SENSOR_MIN = "10"
COL_SENSOR_MAX = "11"

# Default alert thresholds for humidity (the "humidity" ruleset default is
# 30/70 percent; operators override via the params dict when configuring the
# service).
DEFAULT_HUMIDITY_WARN = 30.0
DEFAULT_HUMIDITY_CRIT = 70.0


def _snmp_get(ctx, host, community, oid):
    """Perform a scalar SNMP GET with -Oqv (bare value, no type tag)."""
    return ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-OQv",
            host, oid,
        ],
        mutates=False,
    )


def _snmpwalk(ctx, host, community, oid):
    """Perform an SNMP walk with -Oqn (numeric OID per line, no type tag)."""
    return ctx.run(
        [
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, oid,
        ],
        mutates=False,
    )


def _split_first_space(line):
    """Split an snmpwalk -Oqn line into (oid, value) on the first space."""
    idx = line.find(" ")
    if idx < 0:
        return (line, "")
    return (line[:idx], line[idx + 1:])


def _probe_product(ctx, params):
    """Confirm the Enviromux SEMS product is actually present on the host."""
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # sysDescr-based detection is not available without the full sysDescr string;
    # instead confirm the device responds and its sysoid matches the Enviromux
    # SEMS enterprise prefix. A non-responsive host (rc != 0) means the
    # product is not here.
    res = _snmp_get(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if res.rc != 0:
        return False
    sysoid = res.stdout.strip()
    # sysoid looks like: .1.3.6.1.4.1.3699.1.1.2.x.y.z
    if not sysoid.startswith(ENVIROMUX_SEMS_SYSOID_PREFIX):
        return False
    return True


def _fetch_sensors(ctx, params):
    """Walk the sensor table and return a dict keyed by sensor index.

    Each value is a dict with keys: index, type, description, value, min, max.
    Sensors whose value ("Not configured") cannot be float-cast are skipped.
    """
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    sensors = {}

    # Walk the whole sensor table once. The column OID for intSensorValue is
    # "<base>.6"; walking "<base>" with -Oqn returns every column row as
    # <full-oid> <value>, e.g. .1.3.6.1.4.1.3699.1.1.2.1.4.1.1.6.<idx>.
    walk = _snmpwalk(ctx, host, community, SENSOR_BASE_OID + ".6")
    if walk.rc != 0:
        return sensors

    for line in walk.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        oid, raw_value = _split_first_space(line)
        # oid is like <base>.6.<idx>; the table index is the suffix after the
        # intSensorValue column base.
        col_base = SENSOR_BASE_OID + "." + COL_SENSOR_VALUE + "."
        if not oid.startswith(col_base):
            continue
        index = oid[len(col_base):]

        # Gather the remaining columns for this index.
        sindex = index
        stype = _snmp_get(ctx, host, community,
                          SENSOR_BASE_OID + "." + COL_SENSOR_TYPE + "." + sindex)
        sdesc = _snmp_get(ctx, host, community,
                          SENSOR_BASE_OID + "." + COL_SENSOR_DESCRIPTION + "." + sindex)
        sval = _snmp_get(ctx, host, community,
                         SENSOR_BASE_OID + "." + COL_SENSOR_VALUE + "." + sindex)
        smin = _snmp_get(ctx, host, community,
                         SENSOR_BASE_OID + "." + COL_SENSOR_MIN + "." + sindex)
        smax = _snmp_get(ctx, host, community,
                         SENSOR_BASE_OID + "." + COL_SENSOR_MAX + "." + sindex)

        # Skip sensors whose value cannot be parsed (e.g. "Not configured").
        value_text = sval.stdout.strip()
        if not value_text or not value_text.replace("-", "").replace(".", "").isdigit():
            continue

        sensor_value = float(value_text)
        sensor_type = SENSOR_TYPE_NAMES.get(stype.stdout.strip(), "unknown")

        min_text = smin.stdout.strip()
        max_text = smax.stdout.strip()
        sensor_min = None
        sensor_max = None
        if min_text and min_text.replace("-", "").replace(".", "").isdigit():
            sensor_min = float(min_text)
        if max_text and max_text.replace("-", "").replace(".", "").isdigit():
            sensor_max = float(max_text)

        # Scaling: temperature/power/current/temperatureCombo are reported
        # with a factor of 10 in the MIB.
        if sensor_type in SCALED_TYPES:
            sensor_value = sensor_value / 10.0
            if sensor_min != None:
                sensor_min = sensor_min / 10.0
            if sensor_max != None:
                sensor_max = sensor_max / 10.0

        sensors[index] = {
            "index": index,
            "type": sensor_type,
            "description": sdesc.stdout.strip(),
            "value": sensor_value,
            "min": sensor_min,
            "max": sensor_max,
        }
    return sensors


def _humidity_state(value, warn, crit):
    """Grade a humidity reading against warn/crit thresholds (upper levels)."""
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def main(ctx, params):
    # Discovery mode: enumerate humidity sensors actually present.
    if params.get("_discover"):
        if not _probe_product(ctx, params):
            return {
                "changed": False,
                "msg": "Enviromux SEMS device not present",
                "data": {"discovery": []},
            }
        sensors = _fetch_sensors(ctx, params)
        items = []
        for index, s in sensors.items():
            if s["type"] in ["humidity", "humidityCombo"]:
                # item name mirrors the Checkmk service_name "Sensor %s":
                # "<description> <index>" (description first, index appended).
                item = s["description"] + " " + index
                items.append({
                    "item": item,
                    "params": {
                        "warn": DEFAULT_HUMIDITY_WARN,
                        "crit": DEFAULT_HUMIDITY_CRIT,
                    },
                    "metrics": ["humidity"],
                    "service_labels": {"enviromux_sensor_type": s["type"]},
                })
        return {
            "changed": False,
            "msg": "discovered %d humidity sensors" % len(items),
            "data": {"discovery": items},
        }

    # Check mode: grade a single humidity sensor.
    item = params.get("item", "")
    if not _probe_product(ctx, params):
        return {
            "changed": False,
            "msg": "Enviromux SEMS device not present",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    sensors = _fetch_sensors(ctx, params)
    if not sensors:
        return {
            "changed": False,
            "msg": "no enviromux sensors found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # The item is "<description> <index>"; match on the index suffix.
    target_index = item.split(" ")[-1] if item else ""
    sensor = None
    for index, s in sensors.items():
        candidate_item = s["description"] + " " + index
        if candidate_item == item or (target_index and index == target_index):
            sensor = s
            break

    if sensor == None or sensor["type"] not in ["humidity", "humidityCombo"]:
        return {
            "changed": False,
            "msg": "no such humidity sensor: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    warn = params.get("warn", DEFAULT_HUMIDITY_WARN)
    crit = params.get("crit", DEFAULT_HUMIDITY_CRIT)
    state = _humidity_state(sensor["value"], warn, crit)

    return {
        "changed": False,
        "msg": "Sensor %s %s %f%% (warn %f / crit %f)" % (
            sensor["description"], state, sensor["value"], warn, crit,
        ),
        "data": {
            "state": state,
            "metrics": {"humidity": sensor["value"]},
            "details": "type=%s, min=%s, max=%s" % (
                sensor["type"],
                str(sensor["min"]) if sensor["min"] != None else "n/a",
                str(sensor["max"]) if sensor["max"] != None else "n/a",
            ),
        },
    }