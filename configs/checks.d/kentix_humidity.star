# ===== module-level constants =====
KENTIX_OID_BASE1 = ".1.3.6.1.4.1.37954.2.1.2"
KENTIX_OID_BASE2 = ".1.3.6.1.4.1.37954.3.1.2"
KENTIX_SYSOID_PREFIX = ".1.3.6.1.4.1.332.11.6"

# SNMP OIDs for humidity values
# base/.1 = humidity reading (tenths of percent)
# base/.2 = lower warning threshold
# base/.3 = upper warning threshold
# base/.5 = text description
KENTIX_HUMIDITY_READING_OID = "1"
KENTIX_HUMIDITY_LOWER_WARN_OID = "2"
KENTIX_HUMIDITY_UPPER_WARN_OID = "3"
KENTIX_HUMIDITY_TEXT_OID = "5"


def _get_kentix_sysoid(ctx):
    # Get system object ID to detect Kentix devices
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return ""
    line = res.stdout.strip()
    parts = line.split()
    if len(parts) >= 2:
        return parts[-1].strip()
    return ""


def _get_snmp_value(ctx, oid):
    res = ctx.run(["snmpget", "-On", "-v2c", "-c", "public", "localhost", oid], mutates=False)
    if res.rc != 0:
        return None
    line = res.stdout.strip()
    # Format: OID = VALUE or OID: VALUE
    parts = line.split("=", 1)
    if len(parts) < 2:
        return None
    value = parts[1].strip()
    # Extract numeric value from quotes or trailing text
    value = value.strip('"').strip()
    return value


def main(ctx, params):
    # ===== discovery mode =====
    if params.get("_discover"):
        sysoid = _get_kentix_sysoid(ctx)
        if not sysoid.startswith(KENTIX_SYSOID_PREFIX):
            return {
                "changed": False,
                "msg": "discovered 0 items (not a Kentix device)",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["humidity"]}]},
        }

    # ===== check mode (single-service, item is always "") =====
    # Detect Kentix device first
    sysoid = _get_kentix_sysoid(ctx)
    if not sysoid.startswith(KENTIX_SYSOID_PREFIX):
        return {
            "changed": False,
            "msg": "not a Kentix device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch humidity data from both possible base OIDs
    base1_oid = KENTIX_OID_BASE1 + "." + KENTIX_HUMIDITY_READING_OID
    base2_oid = KENTIX_OID_BASE2 + "." + KENTIX_HUMIDITY_READING_OID
    value1 = _get_snmp_value(ctx, base1_oid)
    value2 = _get_snmp_value(ctx, base2_oid)
    value = value1 if value1 != None else value2

    if value == None:
        return {
            "changed": False,
            "msg": "no humidity reading available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch thresholds and text
    lower_warn = _get_snmp_value(ctx, KENTIX_OID_BASE1 + "." + KENTIX_HUMIDITY_LOWER_WARN_OID)
    if lower_warn == None:
        lower_warn = _get_snmp_value(ctx, KENTIX_OID_BASE2 + "." + KENTIX_HUMIDITY_LOWER_WARN_OID)
    upper_warn = _get_snmp_value(ctx, KENTIX_OID_BASE1 + "." + KENTIX_HUMIDITY_UPPER_WARN_OID)
    if upper_warn == None:
        upper_warn = _get_snmp_value(ctx, KENTIX_OID_BASE2 + "." + KENTIX_HUMIDITY_UPPER_WARN_OID)
    text = _get_snmp_value(ctx, KENTIX_OID_BASE1 + "." + KENTIX_HUMIDITY_TEXT_OID)
    if text == None:
        text = _get_snmp_value(ctx, KENTIX_OID_BASE2 + "." + KENTIX_HUMIDITY_TEXT_OID)
    if text == None:
        text = ""

    # Guard and parse values
    if not value.isdigit() and not value.replace(".", "").isdigit():
        return {
            "changed": False,
            "msg": "invalid humidity reading or thresholds",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reading = float(value) / 10.0
    lower_warn_val = float(lower_warn) if lower_warn != None and (lower_warn.isdigit() or lower_warn.replace(".", "").isdigit()) else 0.0
    upper_warn_val = float(upper_warn) if upper_warn != None and (upper_warn.isdigit() or upper_warn.replace(".", "").isdigit()) else 100.0

    # Determine state
    if reading >= upper_warn_val or reading <= lower_warn_val:
        state = "WARN"
    else:
        state = "OK"

    # Format summary message
    summary = "%f%% (min/max at %f%%/%f%%)" % (reading, lower_warn_val, upper_warn_val)
    if state == "WARN":
        summary = "%s:  %s" % (text, summary)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"humidity": reading},
            "details": "",
        },
    }
