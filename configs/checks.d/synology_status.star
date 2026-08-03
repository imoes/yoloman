def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for the real thing: synologyStatus OIDs live at .1.3.6.1.4.1.6574.1
    base = ".1.3.6.1.4.1.6574.1"
    sys_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".1"],
        mutates=False,
    )
    if sys_res.rc == 127:
        return {"changed": False, "msg": "snmpget not installed",
                "data": {"discovery": []}}

    if params.get("_discover"):
        # Discovery only happens on real Synology hardware: confirm the
        # enterprise OID .1.3.6.1.4.1.6574 responds.
        probe = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.6574"],
            mutates=False,
        )
        if probe.rc != 0 or not probe.stdout.strip():
            return {"changed": False, "msg": "no Synology device found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": []}]}}

    item = params.get("item", "")
    if sys_res.rc != 0:
        return {"changed": False, "msg": "failed to read system status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    system_status = sys_res.stdout.strip()

    pwr_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3"],
        mutates=False,
    )
    if pwr_res.rc != 0:
        return {"changed": False, "msg": "failed to read power status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    power_status = pwr_res.stdout.strip()

    if not system_status.isdigit() or not power_status.isdigit():
        return {"changed": False, "msg": "invalid status values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    system = int(system_status)
    power = int(power_status)
    states = []
    messages = []
    if system != 1:
        states.append("CRIT")
        messages.append("System Failure")
    else:
        states.append("OK")
        messages.append("System state OK")
    if power != 1:
        states.append("CRIT")
        messages.append("Power Failure")
    else:
        states.append("OK")
        messages.append("Power state OK")

    final_state = "CRIT" if "CRIT" in states else "OK"
    return {"changed": False,
            "msg": "; ".join(messages),
            "data": {"state": final_state, "metrics": {}, "details": ""}}