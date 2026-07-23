# Power supply status check for Cisco Meraki device status
# Translation of checkmk.cisco_meraki_org_device_status_ps

def main(ctx, params):
    # Get the agent data via the same command the Checkmk agent would use
    # The agent section "cisco_meraki_org_device_status" is populated by
    # a special API call; since we don't have the agent installed, run
    # the same HTTP request the agent's cisco_meraki plugin would.
    # We'll assume the agent already provides this data as JSON via a
    # custom endpoint, but since the Starlark agent doesn't have HTTP,
    # we use the standard Checkmk agent's built-in cisco_meraki_org_device_status
    # section by calling the agent directly and parsing its JSON output.
    #
    # In practice, the Checkmk agent includes this section when configured with
    # the Meraki API. We request the agent to produce the section.
    res = ctx.run(["/usr/bin/cmk-agent-remote", "cisco_meraki_org_device_status"],
                  mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "agent section unavailable",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Check for empty output before attempting JSON parsing
    if not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no data from agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard: parse JSON only if output is non-empty
    data = json.decode(res.stdout) if res.stdout.strip() else []

    # The agent section is [device_status_dict]
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], dict):
        return {
            "changed": False,
            "msg": "unexpected agent output format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    device_status = data[0]

    # Check discovery mode
    if params.get("_discover"):
        power_supplies = device_status.get("components", {}).get("powerSupplies", [])
        items = []
        for ps in power_supplies:
            slot = str(ps.get("slot", ""))
            if slot:
                items.append({
                    "item": slot,
                    "params": {"state_not_powering": 1},  # WARN = 1
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d power supplies" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: single item
    item = params.get("item", "")
    power_supplies = device_status.get("components", {}).get("powerSupplies", [])
    power_supply = None
    for ps in power_supplies:
        if str(ps.get("slot", "")) == item:
            power_supply = ps
            break

    if power_supply == None:
        return {
            "changed": False,
            "msg": "power supply %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    status = power_supply.get("status", "").lower()
    state_not_powering = params.get("state_not_powering", 1)

    if status == "powering":
        state = "OK"
    else:
        state = "WARN" if state_not_powering == 1 else ("CRIT" if state_not_powering == 2 else "OK")

    model = power_supply.get("model", "")
    serial = power_supply.get("serial", "")
    ps_status = power_supply.get("status", "")

    msg = "Status: %s" % ps_status
    details = "Model: %s, Serial: %s" % (model, serial)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": details
        }
    }
