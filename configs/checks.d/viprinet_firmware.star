def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if detect.rc != 0 or not detect.stdout:
            return {"changed": False, "msg": "not a Viprinet device",
                    "data": {"discovery": []}}
        sysoid = detect.stdout.strip()
        if sysoid != ".1.3.6.1.4.1.35424":
            return {"changed": False, "msg": "not a Viprinet device",
                    "data": {"discovery": []}}
        fw = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.35424.1.1.4"],
            mutates=False,
        )
        if fw.rc != 0 or not fw.stdout:
            return {"changed": False, "msg": "firmware OID unavailable",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered Firmware Version",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": ["fw_status"]},
                ]}}

    fw = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.35424.1.1.4"],
        mutates=False,
    )
    status = ctx.run(
        ["snmpget", "-v2c", "-c", params.get("community", "public"),
         "-Oqv", params.get("host", "localhost"),
         ".1.3.6.1.4.1.35424.1.1.7"],
        mutates=False,
    )
    if fw.rc != 0 or status.rc != 0:
        return {"changed": False, "msg": "no firmware status available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    fw_version = fw.stdout.strip()
    fw_code = status.stdout.strip()
    fw_status_map = {
        "0": "No new firmware available",
        "1": "Update Available",
        "2": "Checking for Updates",
        "3": "Downloading Update",
        "4": "Installing Update",
    }
    fw_status = fw_status_map.get(fw_code)
    if fw_status:
        return {"changed": False,
                "msg": "%s, %s" % (fw_version, fw_status),
                "data": {"state": "OK", "metrics": {"fw_status": 0},
                         "details": ""}}
    return {"changed": False, "msg": "no firmware status available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}