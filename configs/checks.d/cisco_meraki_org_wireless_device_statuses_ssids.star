def main(ctx, params):
    path = "/tmp/cisco_meraki_org_wireless_device_statuses"
    if not ctx.file_exists(path):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "data file not found: " + path,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = ctx.file_read(path)
    if raw == "" or raw.strip() == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "data file empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if raw.find("[[") != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "unexpected outer JSON format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(raw) if raw != "" else []

    if type(data) != "list" or len(data) != 1 or type(data[0]) != "list" or len(data[0]) != 1:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "unexpected outer JSON structure",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    payload_str = data[0][0]
    if type(payload_str) != "string" or payload_str == "":
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "payload is not a non-empty string",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    payload = json.decode(payload_str) if payload_str != "" else []

    if type(payload) != "list" or len(payload) == 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "inner JSON payload is empty list",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    device = payload[0]
    ssids_raw = device.get("basicServiceSets")

    if type(ssids_raw) != "list":
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "basicServiceSets not found or not a list",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ssid_names = []
    ssid_map = {}
    i = 0
    while i < len(ssids_raw):
        ssid_obj = ssids_raw[i]
        if type(ssid_obj) == "dict":
            ssid_name = ssid_obj.get("ssidName")
            if ssid_name != None and type(ssid_name) == "string" and ssid_name != "":
                ssid_names.append(ssid_name)
                ssid_map[ssid_name] = ssid_obj
        i = i + 1

    if params.get("_discover"):
        out = []
        i = 0
        while i < len(ssid_names):
            name = ssid_names[i]
            out.append({"item": name, "params": {"state_if_not_enabled": 1},
                        "metrics": []})
            i = i + 1
        return {"changed": False, "msg": "discovered %d SSIDs" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    ssid = ssid_map.get(item)
    if ssid == None:
        return {"changed": False, "msg": "SSID not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_if_not_enabled = params.get("state_if_not_enabled", 1)

    enabled = ssid.get("enabled")
    if type(enabled) != "bool":
        return {"changed": False, "msg": "enabled field missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if not enabled:
        return {"changed": False, "msg": "Status: Disabled",
                "data": {"state": state_if_not_enabled, "metrics": {}, "details": ""}}

    visible = ssid.get("visible", False)
    ssid_number = ssid.get("ssidNumber")
    if type(ssid_number) != "int":
        ssid_number = -1

    summary = "Status: Enabled"
    notice_visible = "Visible: " + ("true" if visible else "false")
    notice_number = "SSID number: %d" % ssid_number

    return {"changed": False, "msg": summary,
            "data": {"state": 0, "metrics": {}, "details": "", "notice": [notice_visible, notice_number]}}