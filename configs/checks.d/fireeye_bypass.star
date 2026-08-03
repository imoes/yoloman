def main(ctx, params):
    if params.get("_discover"):
        detect = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        sys_oid = ""
        for part in detect.stdout.split():
            sys_oid = part
        if detect.rc != 0 or not sys_oid.startswith(".1.3.6.1.4.1.25597.1"):
            return {"changed": False, "msg": "FireEye not detected", "data": {"discovery": [], "host_labels": {}}}
        res = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            ".1.3.6.1.4.1.25597.13.1.41.0",
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no bypass mail rate found", "data": {"discovery": []}}
        value_str = res.stdout.strip()
        if value_str == "" or not value_str.lstrip("-").isdigit():
            return {"changed": False, "msg": "invalid bypass value", "data": {"discovery": []}}
        value = int(value_str)
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {"value": value}, "metrics": ["bypass_mail_rate"]}], "host_labels": {"cmk/snmp": "true"}}}
    if params.get("_discover") == None and params.get("_discover") == False:
        pass
    item = params.get("item", "")
    res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.25597.13.1.41.0",
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "bypass mail rate unavailable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    value_str = res.stdout.strip()
    if value_str == "" or not value_str.lstrip("-").isdigit():
        return {"changed": False, "msg": "invalid bypass value: " + value_str, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    current_value = int(value_str)
    expected_value = params.get("value", 0)
    state = "OK" if current_value == expected_value else "CRIT"
    summary = "Bypass E-Mail count: %d" % current_value
    if current_value != expected_value:
        summary = summary + " (was %d before)" % expected_value
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {"bypass_mail_rate": current_value}, "details": ""}}