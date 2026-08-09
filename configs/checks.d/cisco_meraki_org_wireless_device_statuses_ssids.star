def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: probe for Meraki API access and enumerate SSIDs
        token = params.get("token", "")
        org_id = params.get("org_id", "")
        host = params.get("host", "api.meraki.com")
        net_id = params.get("net_id", "")

        if not token or not org_id:
            return {"changed": False, "msg": "Meraki API token/org_id not configured",
                    "data": {"discovery": []}}

        # Try to list SSIDs via Meraki API
        url = "https://api.meraki.com/api/v1/organizations/" + org_id + "/wireless/statuses"
        res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + token, url], mutates=False)

        if res.rc != 0:
            return {"changed": False, "msg": "Meraki API unreachable",
                    "data": {"discovery": []}}

        payload = json.decode(res.stdout)
        if payload == None or len(payload) == 0:
            return {"changed": False, "msg": "no wireless statuses found",
                    "data": {"discovery": []}}

        # The API returns a list of device status objects, each with basicServiceSets
        # We look at the first device's SSIDs for discovery
        device_status = payload[0]
        ssids = device_status.get("basicServiceSets", [])
        items = []
        for ssid in ssids:
            name = ssid.get("ssidName", "")
            items.append({"item": name, "params": {"state_if_not_enabled": 1},
                          "metrics": []})
        return {"changed": False, "msg": "discovered %d SSIDs" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    token = params.get("token", "")
    org_id = params.get("org_id", "")
    host = params.get("host", "api.meraki.com")

    if not token or not org_id:
        return {"changed": False, "msg": "Meraki API token/org_id not configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    url = "https://api.meraki.com/api/v1/organizations/" + org_id + "/wireless/statuses"
    res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + token, url], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "Meraki API unreachable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    payload = json.decode(res.stdout)
    if payload == None or len(payload) == 0:
        return {"changed": False, "msg": "no wireless statuses found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the SSID by name across device statuses
    found_ssid = None
    for device_status in payload:
        ssids = device_status.get("basicServiceSets", [])
        for ssid in ssids:
            if ssid.get("ssidName", "") == item:
                found_ssid = ssid
                break
        if found_ssid != None:
            break

    if found_ssid == None:
        return {"changed": False, "msg": "SSID %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_if_not_enabled = params.get("state_if_not_enabled", 1)
    enabled = found_ssid.get("enabled", False)

    if not enabled:
        state = "WARN" if state_if_not_enabled == 1 else ("CRIT" if state_if_not_enabled == 2 else "OK")
        return {"changed": False, "msg": "Status: Disabled",
                "data": {"state": state, "metrics": {}, "details": ""}}

    details = []
    visible = found_ssid.get("visible", False)
    ssid_number = found_ssid.get("ssidNumber", None)
    details.append("Visible: %s" % visible)
    if ssid_number != None:
        details.append("SSID number: %s" % ssid_number)

    return {"changed": False, "msg": "Status: Enabled",
            "data": {"state": "OK", "metrics": {}, "details": "\n".join(details)}}