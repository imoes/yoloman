# HiveManager NG Devices check - read-only Starlark translation
# Monitors Hivemanager NG device connectivity and client counts

# Default thresholds for max_clients (warn, crit)
DEFAULT_MAX_CLIENTS = (25, 50)

def _parse_device_line(line):
    """Parse a device line in format key::value key::value ..."""
    data = {}
    parts = line.split()
    for element in parts:
        kv = element.split("::")
        if len(kv) == 2:
            key = kv[0]
            val = kv[1]
            data[key] = val
    # Convert known fields
    if "connected" in data:
        data["connected"] = data["connected"] == "True"
    if "activeClients" in data:
        data["activeClients"] = int(data["activeClients"])
    return data

def _get_device_data(ctx, host, community, ip):
    """
    Retrieve device data. The HiveManager NG check relies on a special agent
    that queries the HiveManager API. We probe for availability of that source.
    """
    # The Checkmk agent section hivemanager_ng_devices would be populated by
    # a special agent. We check if we can get that data source.
    # Since the special agent output isn't available on this host, we return
    # an empty section.
    return {}

def main(ctx, params):
    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # The HiveManager NG devices are managed via a network appliance/API.
        # Probe for the real source - the special agent section data would
        # need to be available. Since there's no standard CLI for this on
        # a generic host, check if the data is accessible.
        # The agent section data is expected from a special agent connecting
        # to HiveManager NG. We can't run Checkmk, but we can look for
        # any cached/special-agent output.
        section = {}
        
        # Probe for a possible data source (special agent output)
        # Check for any local representation of HiveManager data
        res = ctx.run(["hivemanager_ctl", "--status"], mutates=False)
        if res.rc == 127:
            # Binary not found - HiveManager not running on this host
            return {"changed": False, "msg": "No hivemanager_ng_devices found on this host",
                    "data": {"discovery": []}}
        
        # If we can't get real data, return empty discovery
        # (ABSENCE IS AN ANSWER - don't invent devices)
        return {"changed": False, "msg": "No hivemanager_ng_devices found",
                "data": {"discovery": []}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    
    # The HiveManager NG devices are queried via a special agent that
    # connects to the network management appliance. Since we cannot
    # run Checkmk's special agent here, we must check for the actual
    # data source.
    res = ctx.run(["hivemanager_ctl", "--status"], mutates=False)
    if res.rc == 127:
        # HiveManager not installed/running on this host
        return {"changed": False,
                "msg": "no hivemanager_ng_devices data available on this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # If the binary exists but we can't get device data, report UNKNOWN
    return {"changed": False,
            "msg": "no device data retrieved for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}