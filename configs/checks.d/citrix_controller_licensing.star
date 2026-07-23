def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    res = ctx.run(["cmk-agent-ctl", "show-data", "citrix_controller"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve citrix_controller data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    section = {
        "licensing_grace_state": None,
        "licensing_server_state": None,
    }

    for line in lines:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        key = parts[0]
        value = parts[1] if len(parts) > 1 else None

        if key == "LicensingGraceState" and section["licensing_grace_state"] == None:
            section["licensing_grace_state"] = value
        elif key == "LicensingServerState" and section["licensing_server_state"] == None:
            section["licensing_server_state"] = value

    server_states = {
        "ServerNotSpecified": ("CRIT", "server not specified"),
        "NotConnected": ("WARN", "not connected"),
        "OK": ("OK", "OK"),
        "LicenseNotInstalled": ("CRIT", "license not installed"),
        "LicenseExpired": ("CRIT", "licenese expired"),
        "Incompatible": ("CRIT", "incompatible"),
        "Failed": ("CRIT", "failed"),
    }

    grace_states = {
        "NotActive": ("OK", "not active"),
        "Active": ("CRIT", "active"),
        "InOutOfBoxGracePeriod": ("WARN", "in-out-of-box grace period"),
        "InSupplementalGracePeriod": ("WARN", "in-supplemental grace period"),
        "InEmergencyGracePeriod": ("CRIT", "in-emergency grace period"),
        "GracePeriodExpired": ("CRIT", "grace period expired"),
        "Expired": ("CRIT", "expired"),
    }

    results = []
    state_order = {"UNKNOWN": 0, "OK": 1, "WARN": 2, "CRIT": 3}
    final_state = "OK"

    raw_server = section.get("licensing_server_state")
    if raw_server != None:
        state, text = server_states.get(raw_server, ("UNKNOWN", "unknown[" + raw_server + "]"))
        results.append({"state": state, "summary": "Licensing Server State: " + text})
        if state_order.get(state, 0) > state_order.get(final_state, 0):
            final_state = state

    raw_grace = section.get("licensing_grace_state")
    if raw_grace != None:
        state, text = grace_states.get(raw_grace, ("UNKNOWN", "unknown[" + raw_grace + "]"))
        results.append({"state": state, "summary": "Licensing Grace State: " + text})
        if state_order.get(state, 0) > state_order.get(final_state, 0):
            final_state = state

    if len(results) == 0:
        msg = "No licensing state data available"
    else:
        msgs = []
        for r in results:
            msgs.append(r["summary"])
        msg = ", ".join(msgs)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": final_state, "metrics": {}, "details": ""}
    }
