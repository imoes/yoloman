def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    item = params.get("item", "")
    return _check(ctx, params, item)


# ---- data fetching -------------------------------------------------------

def _fetch_device_status(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    # The Cisco Meraki device status data comes from a Meraki special agent
    # over the network. There is no on-host equivalent that returns this data.
    # On this host we cannot retrieve it, so there is no data source.
    return None


# ---- discovery -----------------------------------------------------------

def _discover(ctx, params):
    section = _fetch_device_status(ctx, params)
    if section == None:
        return {"changed": False, "msg": "not available", "data": {"discovery": []}}
    supplies = section.get("power_supplies", {})
    discovery = []
    for slot in sorted(supplies):
        ps = supplies[slot]
        discovery.append({
            "item": slot,
            "params": {"state_not_powering": 1},
            "metrics": [],
            "service_labels": {
                "ps_model": ps.get("model", ""),
                "ps_serial": ps.get("serial", ""),
            },
        })
    return {
        "changed": False,
        "msg": "discovered %d power supplies" % len(discovery),
        "data": {"discovery": discovery},
    }


# ---- check ---------------------------------------------------------------

def _check(ctx, params, item):
    section = _fetch_device_status(ctx, params)
    if section == None:
        return {
            "changed": False,
            "msg": "Cisco Meraki device status not available on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    supplies = section.get("power_supplies", {})
    power_supply = supplies.get(item)
    if power_supply == None:
        return {
            "changed": False,
            "msg": "no such power supply: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    status = power_supply.get("status", "")
    if status.lower() == "powering":
        state = "OK"
    else:
        state = _state_name(params.get("state_not_powering", 1))
    details = "Model: %s\nSerial: %s" % (
        power_supply.get("model", ""),
        power_supply.get("serial", ""),
    )
    return {
        "changed": False,
        "msg": "Status: " + status,
        "data": {"state": state, "metrics": {}, "details": details},
    }


def _state_name(val):
    if val == 0:
        return "OK"
    if val == 1:
        return "WARN"
    if val == 2:
        return "CRIT"
    if val == 3:
        return "UNKNOWN"
    return "WARN"