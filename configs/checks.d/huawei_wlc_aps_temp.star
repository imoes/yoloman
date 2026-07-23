# Module-level constants (required for SNMP OID mapping and state labels)
_HUAWEI_WLC_OIDS = {
    "ap_info_base": ".1.3.6.1.4.1.2011.6.139.13.3.3.1",
    "radio_info_base": ".1.3.6.1.4.1.2011.6.139.16.1.2.1",
    "sys_oid": ".1.3.6.1.2.1.1.2.0",
    "detect_oid": ".1.3.6.1.4.1.2011.2.240.17",
}

_AP_STATE_LABELS = {
    "1": "Idle",
    "2": "Auto find",
    "3": "Type not match",
    "4": "Fault",
    "5": "Config",
    "6": "Config failed",
    "7": "Download",
    "8": "Normal",
    "9": "Committing",
    "10": "Commit failed",
    "11": "Standy",
    "12": "Version mismatch",
    "13": "Name conflicted",
    "14": "Invalid",
    "15": "Country code mismatch",
}

_AP_STATE_TO_OKWARNCRIT = {
    "1": "CRIT",  # Idle -> CRIT
    "2": "WARN",  # Auto find -> WARN
    "3": "CRIT",  # Type not match -> CRIT
    "4": "CRIT",  # Fault -> CRIT
    "5": "CRIT",  # Config -> CRIT
    "6": "CRIT",  # Config failed -> CRIT
    "7": "WARN",  # Download -> WARN
    "8": "OK",    # Normal -> OK
    "9": "CRIT",  # Committing -> CRIT
    "10": "CRIT", # Commit failed -> CRIT
    "11": "WARN", # Standy -> WARN
    "12": "CRIT", # Version mismatch -> CRIT
    "13": "CRIT", # Name conflicted -> CRIT
    "14": "CRIT", # Invalid -> CRIT
    "15": "CRIT", # Country code mismatch -> CRIT
}

_RADIO_STATE_LABELS = {
    "1": "up",
    "2": "down",
}

_RADIO_STATE_TO_OKWARNCRIT = {
    "1": "OK",
    "2": "CRIT",
}


def _get_snmp_value(lines, base_oid):
    """Convert snmpwalk output lines into a dict: OID -> value."""
    result = {}
    for line in lines:
        if line.find(" = ") < 0:
            continue
        idx = line.find(" = ")
        oid_part = line[:idx].strip()
        value_part = line[idx + 3:].strip()
        # Extract suffix after base_oid
        base_clean = base_oid.rstrip(".")
        if oid_part.startswith(base_clean):
            suffix = oid_part[len(base_clean):].lstrip(".")
        else:
            suffix = oid_part
        result[suffix] = value_part


def _is_huawei_wlc_device(ctx):
    # Detect Huawei WLC via sysObjectID
    res = ctx.run(["snmpget", "-v2c", "-c", "public", "-On", "localhost", _HUAWEI_WLC_OIDS["sys_oid"]], mutates=False)
    if res.rc != 0:
        return False
    output = res.stdout.strip()
    if output.find(_HUAWEI_WLC_OIDS["detect_oid"]) >= 0:
        return True
    return False


def main(ctx, params):
    if params.get("_discover"):
        # Detect device type
        if not _is_huawei_wlc_device(ctx):
            return {"changed": False, "msg": "no Huawei WLC detected", "data": {"discovery": []}}

        # Fetch both tables
        res1 = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost",
                        _HUAWEI_WLC_OIDS["ap_info_base"]], mutates=False)
        if res1.rc != 0:
            return {"changed": False, "msg": "AP info table fetch failed", "data": {"discovery": []}}

        res2 = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost",
                        _HUAWEI_WLC_OIDS["radio_info_base"]], mutates=False)
        if res2.rc != 0:
            return {"changed": False, "msg": "Radio info table fetch failed", "data": {"discovery": []}}

        # Parse AP table
        ap_raw = _get_snmp_value(res1.stdout.splitlines(), _HUAWEI_WLC_OIDS["ap_info_base"])
        # Parse radio table
        radio_raw = _get_snmp_value(res2.stdout.splitlines(), _HUAWEI_WLC_OIDS["radio_info_base"])

        # Extract AP IDs (from radio table base)
        ap_ids = set()
        for suffix in radio_raw.keys():
            # Radio table structure: apID.radioIdx OID suffix
            parts = suffix.split(".")
            if len(parts) >= 2 and parts[0].isdigit():
                ap_ids.add(parts[0])

        # Build discovery list
        items = []
        for ap_id in sorted(ap_ids):
            items.append({
                "item": ap_id,
                "params": {
                    "levels": (70.0, 75.0),
                },
                "metrics": ["temperature"],
            })

        return {
            "changed": False,
            "msg": "discovered %d APs" % len(items),
            "data": {"discovery": items},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "item must be provided",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Fetch both tables again for this check
    res1 = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost",
                    _HUAWEI_WLC_OIDS["ap_info_base"]], mutates=False)
    if res1.rc != 0:
        return {
            "changed": False,
            "msg": "AP info table fetch failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res2 = ctx.run(["snmpwalk", "-v2c", "-c", "public", "-On", "localhost",
                    _HUAWEI_WLC_OIDS["radio_info_base"]], mutates=False)
    if res2.rc != 0:
        return {
            "changed": False,
            "msg": "Radio info table fetch failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse data
    ap_raw = _get_snmp_value(res1.stdout.splitlines(), _HUAWEI_WLC_OIDS["ap_info_base"])
    radio_raw = _get_snmp_value(res2.stdout.splitlines(), _HUAWEI_WLC_OIDS["radio_info_base"])

    # Find AP's temp OID: ap_id.43 -> temp value
    temp_oid_suffix = item + ".43"
    temp_str = ap_raw.get(temp_oid_suffix, "")

    # "invalid" (255) maps to "invalid" string; anything else parsed as float
    temp_value = "invalid"
    if temp_str == "255":
        temp_value = "invalid"
    elif temp_str.isdigit() or (temp_str.startswith("-") and temp_str[1:].isdigit()):
        temp_value = float(temp_str)

    # Extract thresholds from params
    levels = params.get("levels", (70.0, 75.0))
    warn, crit = levels

    # Determine state and message
    if temp_value == "invalid":
        state = "OK"
        msg = "invalid"
    else:
        # Temperature check: upper levels
        if temp_value >= crit:
            state = "CRIT"
        elif temp_value >= warn:
            state = "WARN"
        else:
            state = "OK"
        msg = "%f C" % temp_value

    # Build metrics
    metrics = {"temperature": temp_value} if temp_value != "invalid" else {}

    return {
        "changed": False,
        "msg": "AP %s temperature: %s" % (item, msg),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
