def main(ctx, params):
    # Determine mode: discovery or check
    if params.get("_discover"):
        # Discovery: yield services for smoke detector items 1 and 2
        return {
            "changed": False,
            "msg": "discovered 2 smoke detectors",
            "data": {
                "discovery": [
                    {"item": "1", "params": {}, "metrics": ["smoke_perc"]},
                    {"item": "2", "params": {}, "metrics": ["smoke_perc"]},
                ]
            },
        }

    # Check mode
    item = params.get("item", "")
    if item != "1" and item != "2":
        return {
            "changed": False,
            "msg": "Smoke Detector %s not found in SNMP" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Get SNMP data
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe model detection OID first to distinguish models
    res_detect = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res_detect.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error during model detection",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    oid_val = res_detect.stdout.strip()
    if " = " not in oid_val:
        return {
            "changed": False,
            "msg": "Could not parse model OID response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    model = oid_val.split(" = ", 1)[1].strip()
    base = ""
    if ".1.3.6.1.4.1.34187.21501" in model:
        base = ".1.3.6.1.4.1.34187.21501.2.1"
    elif ".1.3.6.1.4.1.34187.74195" in model:
        base = ".1.3.6.1.4.1.34187.74195.2.1"
    else:
        return {
            "changed": False,
            "msg": "Unknown Wagner Titanus TOPSense model (not 21501 or 74195)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Map item to SNMP OID index
    item_idx = 245810000 if item == "1" else 245820000
    full_oid = base + "." + str(item_idx)

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-On", host, full_oid],
        mutates=False,
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error retrieving smoke percentage for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse snmpget output
    if " = " not in res.stdout:
        return {
            "changed": False,
            "msg": "Could not parse smoke percentage response",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value_str = res.stdout.split(" = ", 1)[1].strip()

    # Convert to float with guard instead of try/except
    clean = ""
    found_point = False
    for ch in value_str:
        if ch.isdigit():
            clean += ch
        elif ch == "." and not found_point:
            clean += ch
            found_point = True
        else:
            break

    smoke_perc = 0.0
    if clean != "" and clean != ".":
        smoke_perc = float(clean)

    # Threshold logic (hardcoded in Checkmk source)
    state = "OK"
    if smoke_perc > 5.0:
        state = "CRIT"
    elif smoke_perc > 3.0:
        state = "WARN"

    msg = "%s%% smoke detected" % ("{:.6f}".format(smoke_perc))
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"smoke_perc": smoke_perc},
            "details": "",
        },
    }