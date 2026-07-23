def main(ctx, params):
    # SNMP probe: fetch the health section from the agent
    # The check uses SNMP OID .1.3.6.1.4.1.2.3.51.1.2.7
    res = ctx.run(["snmpget", "-Oqv", "-On", ".1.3.6.1.4.1.2.3.51.1.2.7"], mutates=False)
    raw = res.stdout.strip()
    if not raw:
        return {"changed": False, "msg": "no data from agent",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse SNMP response: it returns a quoted string like "0 1 2 3 4 5 255 255 255 ..."
    # Split into tokens (string_table lines)
    tokens = raw.split()
    if not tokens:
        return {"changed": False, "msg": "empty SNMP response",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section = [[t] for t in tokens]  # mimic StringTable format

    # ===== DISCOVERY MODE =====
    if params.get("_discover"):
        if section:
            return {"changed": False, "msg": "discovered 1 item",
                    "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
        else:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

    # ===== CHECK MODE =====
    # The section is a list of lists; flatten to tokens for processing
    section_data = [t[0] for t in section]
    if len(section_data) < 1:
        return {"changed": False, "msg": "incomplete SNMP data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse according to original logic
    # First element is overall state
    state_str = section_data[0]
    state_val = int(state_str) if state_str.isdigit() else -1

    infotext = ""
    if len(section_data) > 1:
        # Count alerts: (len(section) - 1) // 3
        num_alerts = (len(section_data) - 1) // 3
        for i in range(num_alerts):
            # state per alert at index num_alerts + 1 + i
            # text per alert at index num_alerts * 2 + 1 + i
            state_idx = num_alerts + 1 + i
            text_idx = num_alerts * 2 + 1 + i
            if state_idx < len(section_data) and text_idx < len(section_data):
                alert_state = section_data[state_idx]
                alert_text = section_data[text_idx]
                infotext += alert_text + "(" + alert_state + ")"
                if i < num_alerts - 1:
                    infotext += ", "

    # Determine state
    if state_val == 255:
        check_state = "OK"
        summary = "no problem found"
    elif state_val in [0, 2]:
        check_state = "CRIT"
        summary = infotext if infotext else "non-critical or critical status"
    elif state_val == 4:
        check_state = "WARN"
        summary = infotext if infotext else "system level warning"
    else:
        check_state = "UNKNOWN"
        summary = infotext if infotext else "unexpected health state: " + str(state_val)

    return {"changed": False, "msg": summary,
            "data": {"state": check_state, "metrics": {}, "details": ""}}
