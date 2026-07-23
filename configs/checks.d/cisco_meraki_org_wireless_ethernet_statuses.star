_SPEED_TO_BITS = 12500
_STATE_NAMES = {0: "OK", 1: "WARN", 2: "CRIT"}

def _render_speed(speed_bps):
    if speed_bps == None:
        return "unknown"
    if speed_bps >= 1000000000:
        return "%f Gbit/s" % (float(speed_bps) / 1000000000.0)
    if speed_bps >= 1000000:
        return "%f Mbit/s" % (float(speed_bps) / 1000000.0)
    if speed_bps >= 1000:
        return "%f kbit/s" % (float(speed_bps) / 1000.0)
    return "%d bit/s" % speed_bps

def _fetch_status(ctx, params):
    api_key = params.get("api_key", "")
    org_id = params.get("org_id", "")
    serial = params.get("serial", "")
    url = "https://api.meraki.com/api/v1/organizations/" + org_id + "/wireless/devices/ethernet/statuses"
    if serial:
        url = url + "?serials[]=" + serial
    res = ctx.run([
        "curl", "-s", "-L",
        "-H", "X-Cisco-Meraki-API-Key: " + api_key,
        url,
    ], mutates=False)
    if res.rc != 0:
        return None
    raw = res.stdout.strip()
    if not raw:
        return None
    data = json.decode(raw)
    if type(data) != "list" or len(data) == 0:
        return None
    return data[0]

def main(ctx, params):
    if params.get("_discover"):
        status = _fetch_status(ctx, params)
        if status == None:
            return {"changed": False, "msg": "no data", "data": {"discovery": []}}
        ports = status.get("ports", [])
        items = []
        for port in ports:
            name = port.get("name", "")
            link_neg = port.get("linkNegotiation", {})
            raw_speed = link_neg.get("speed")
            speed_bps = raw_speed * _SPEED_TO_BITS if raw_speed != None else None
            disc_params = {}
            if speed_bps != None:
                disc_params["speed"] = speed_bps
            items.append({
                "item": name,
                "params": disc_params,
                "metrics": ["speed_bps"],
            })
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    status = _fetch_status(ctx, params)
    if status == None:
        return {
            "changed": False,
            "msg": "no data from Meraki API",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    port_data = None
    for port in status.get("ports", []):
        if port.get("name", "") == item:
            port_data = port
    if port_data == None:
        return {
            "changed": False,
            "msg": "port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    power = status.get("power", {})
    link_neg = port_data.get("linkNegotiation", {})
    poe_info = port_data.get("poe", {})

    raw_speed = link_neg.get("speed")
    speed_bps = raw_speed * _SPEED_TO_BITS if raw_speed != None else None
    duplex = link_neg.get("duplex")
    poe_standard = poe_info.get("standard")
    power_mode = power.get("mode", "unknown")
    ac_connected = power.get("ac", {}).get("isConnected")
    poe_connected = power.get("poe", {}).get("isConnected")

    state_no_speed = params.get("state_no_speed", 1)
    state_not_full_duplex = params.get("state_not_full_duplex", 1)
    state_not_on_fill_power = params.get("state_not_on_fill_power", 1)
    state_speed_change = params.get("state_speed_change", 1)
    prior_speed = params.get("speed")

    worst = 0
    summary_parts = []
    detail_parts = []

    if speed_bps != None:
        if prior_speed != None and speed_bps != prior_speed:
            detail_parts.append("Speed changed: %s -> %s" % (_render_speed(prior_speed), _render_speed(speed_bps)))
            if state_speed_change > worst:
                worst = state_speed_change
        summary_parts.append("Speed: " + _render_speed(speed_bps))
    else:
        summary_parts.append("Speed: unknown")
        if state_no_speed > worst:
            worst = state_no_speed

    if duplex != None:
        summary_parts.append("Duplex: " + duplex)
        if duplex != "full":
            if state_not_full_duplex > worst:
                worst = state_not_full_duplex
    else:
        summary_parts.append("Duplex: unknown")

    detail_parts.append("Power mode: " + power_mode)
    if power_mode != "full":
        if state_not_on_fill_power > worst:
            worst = state_not_on_fill_power

    if ac_connected == True:
        ac_str = "connected"
    elif ac_connected == False:
        ac_str = "not connected"
    else:
        ac_str = "unknown"
    detail_parts.append("Power AC: " + ac_str)

    if poe_connected == True:
        poe_str = "connected"
    elif poe_connected == False:
        poe_str = "not connected"
    else:
        poe_str = "unknown"
    detail_parts.append("PoE: " + poe_str)

    if poe_standard != None:
        detail_parts.append("Standard: " + poe_standard)

    state = _STATE_NAMES.get(worst, "UNKNOWN")
    metrics = {}
    if speed_bps != None:
        metrics["speed_bps"] = speed_bps

    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "\n".join(detail_parts),
        },
    }