def main(ctx, params):
    api_key = params.get("api_key", "")
    org_id = params.get("org_id", "")
    network_id = params.get("network_id", "")
    base_url = params.get("base_url", "https://api.meraki.com/api/v1")

    if params.get("_discover"):
        if api_key == "" or org_id == "" or network_id == "":
            return {"changed": False, "msg": "missing api_key/org_id/network_id", "data": {"discovery": []}}
        url = base_url + "/networks/" + network_id + "/wireless/ethernetStatuses"
        res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + api_key, "-H", "Content-Type: application/json", url], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "API call failed", "data": {"discovery": []}}
        if res.stdout == "":
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        if type(data) != "dict":
            return {"changed": False, "msg": "invalid response", "data": {"discovery": []}}
        ports = data.get("ports", [])
        if type(ports) != "list":
            return {"changed": False, "msg": "invalid ports", "data": {"discovery": []}}
        discovery = []
        for port in ports:
            name = port.get("name", "")
            link_neg = port.get("linkNegotiation", {})
            raw_speed = link_neg.get("speed", None)
            speed = None
            if raw_speed != None and type(raw_speed) == "int":
                speed = raw_speed * 12500
            discovery.append({"item": name, "params": {"speed": speed, "state_no_speed": params.get("state_no_speed", 1), "state_not_full_duplex": params.get("state_not_full_duplex", 1), "state_not_on_fill_power": params.get("state_not_on_fill_power", 1), "state_speed_change": params.get("state_speed_change", 1)}, "metrics": []})
        return {"changed": False, "msg": "discovered %d ports" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    if api_key == "" or org_id == "" or network_id == "":
        return {"changed": False, "msg": "missing api_key/org_id/network_id", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    url = base_url + "/networks/" + network_id + "/wireless/ethernetStatuses"
    res = ctx.run(["curl", "-s", "-H", "X-Cisco-Meraki-API-Key: " + api_key, "-H", "Content-Type: application/json", url], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "API call failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.stdout == "":
        return {"changed": False, "msg": "no data from API", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    if type(data) != "dict":
        return {"changed": False, "msg": "invalid response", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    ports = data.get("ports", [])
    if type(ports) != "list":
        return {"changed": False, "msg": "invalid ports", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    port_found = None
    for port in ports:
        name = port.get("name", "")
        if name == item:
            port_found = port
            break
    if port_found == None:
        return {"changed": False, "msg": "port not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    link_neg = port_found.get("linkNegotiation", {})
    raw_speed = link_neg.get("speed", None)
    speed = None
    if raw_speed != None and type(raw_speed) == "int":
        speed = raw_speed * 12500
    duplex = link_neg.get("duplex", None)

    poe = port_found.get("poe", {})
    poe_standard = poe.get("standard", None)

    power = data.get("power", {})
    power_mode = power.get("mode", "")
    ac_info = power.get("ac", {})
    ac_connected = ac_info.get("isConnected", False)
    poe_info = power.get("poe", {})
    poe_connected = poe_info.get("isConnected", False)

    prior_speed = params.get("speed", None)
    state_speed_change = params.get("state_speed_change", 1)
    state_no_speed = params.get("state_no_speed", 1)
    state_not_full_duplex = params.get("state_not_full_duplex", 1)
    state_not_on_fill_power = params.get("state_not_on_fill_power", 1)

    states = []
    summaries = []

    if speed != None:
        if prior_speed != None and speed != prior_speed:
            states.append(state_speed_change)
            summaries.append("Speed changed: " + _render_speed(prior_speed) + " -> " + _render_speed(speed))
        summaries.append("Speed: " + _render_speed(speed))
    else:
        states.append(state_no_speed)
        summaries.append("Speed: unknown")

    duplex_state = 0 if duplex == "full" else state_not_full_duplex
    states.append(duplex_state)
    summaries.append("Duplex: " + str(duplex))

    power_mode_state = 0 if power_mode == "full" else state_not_on_fill_power
    states.append(power_mode_state)
    summaries.append("Power mode: " + power_mode)

    ac_summary = "connected" if ac_connected else "not connected"
    summaries.append("Power AC: " + ac_summary)

    poe_summary = "connected" if poe_connected else "not connected"
    summaries.append("PoE: " + poe_summary)

    summaries.append("Standard: " + str(poe_standard))

    overall_state = 0
    for s in states:
        if s > overall_state:
            overall_state = s

    if overall_state == 0:
        state = "OK"
    elif overall_state == 1:
        state = "WARN"
    elif overall_state == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"

    return {"changed": False, "msg": summaries[0] if len(summaries) > 0 else "ok", "data": {"state": state, "metrics": {}, "details": "\n".join(summaries)}}

def _render_speed(speed):
    if speed == None:
        return "unknown"
    return _format_nicspeed(speed)

def _format_nicspeed(bits_per_sec):
    if bits_per_sec >= 1000000000000:
        return "%f Tbit/s" % (bits_per_sec / 1000000000000.0)
    elif bits_per_sec >= 1000000000:
        return "%f Gbit/s" % (bits_per_sec / 1000000000.0)
    elif bits_per_sec >= 1000000:
        return "%f Mbit/s" % (bits_per_sec / 1000000.0)
    elif bits_per_sec >= 1000:
        return "%f Kbit/s" % (bits_per_sec / 1000.0)
    else:
        return "%d bit/s" % int(bits_per_sec)