def main(ctx, params):
    if params.get("_discover"):
        # Probe for Synology device by checking the model OID (rc==127 means not installed/snmpget missing;
        # empty/no response means device not present)
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.6574.1.5"
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".1"],
            mutates=False
        )
        # If snmpget not found (127) or device didn't respond, not a Synology
        if probe.rc == 127:
            return {"changed": False, "msg": "not a synology device", "data": {"discovery": []}}
        if probe.rc != 0 or not probe.stdout.strip():
            return {"changed": False, "msg": "not a synology device", "data": {"discovery": []}}
        # Single-service check: one item with empty string
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            }
        }
    # CHECK MODE — gather the three OIDs
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.6574.1.5"
    model_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".1"],
        mutates=False
    )
    sn_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".2"],
        mutates=False
    )
    os_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base_oid + ".3"],
        mutates=False
    )
    # If we can't reach the device, report UNKNOWN
    if model_res.rc == 127 or model_res.rc != 0 or not model_res.stdout.strip():
        return {
            "changed": False,
            "msg": "no synology device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    model = model_res.stdout.strip()
    serialnumber = sn_res.stdout.strip() if sn_res.rc == 0 else ""
    os_version = os_res.stdout.strip() if os_res.rc == 0 else ""
    summary = "Model: %s, S/N: %s, OS Version: %s" % (model, serialnumber, os_version)
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": "OK", "metrics": {}, "details": ""}
    }