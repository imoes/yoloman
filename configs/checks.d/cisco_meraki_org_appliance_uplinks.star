def main(ctx, params):
    # Constants and maps (top-level to avoid undefined errors)
    DEFAULT_TIMESPAN = 60
    STATUS_MAP_DEFAULT = {
        "active": "OK",
        "ready": "OK",
        "connecting": "WARN",
        "not_connected": "WARN",
        "failed": "CRIT",
    }

    # Discovery mode: enumerate all uplinks (items) with their metrics
    if params.get("_discover"):
        file_path = "/var/lib/cmk/cisco_meraki_org_appliance_uplinks.json"
        if not ctx.file_exists(file_path):
            return {
                "changed": False,
                "msg": "discovered 0 uplinks (no data file)",
                "data": {"discovery": []}
            }
        content = ctx.file_read(file_path)
        if not content:
            return {
                "changed": False,
                "msg": "discovered 0 uplinks (empty data file)",
                "data": {"discovery": []}
            }
        data = json.decode(content)
        if type(data) != "list" or len(data) == 0 or type(data[0]) != "dict":
            return {
                "changed": False,
                "msg": "discovered 0 uplinks (invalid data format)",
                "data": {"discovery": []}
            }
        uplinks = data[0].get("uplinks", [])
        if type(uplinks) != "list":
            return {
                "changed": False,
                "msg": "discovered 0 uplinks (no uplinks list)",
                "data": {"discovery": []}
            }
        items = []
        for uplink in uplinks:
            if type(uplink) == "dict":
                item_name = uplink.get("interface", "")
                if item_name == "":
                    continue
                items.append({
                    "item": item_name,
                    "params": STATUS_MAP_DEFAULT,
                    "metrics": ["if_in_bps", "if_out_bps"] if params.get("show_traffic", False) else []
                })
        return {
            "changed": False,
            "msg": "discovered %d uplinks" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: check one uplink item
    item = params.get("item", "")
    show_traffic = params.get("show_traffic", False)
    status_map = params.get("status_map", STATUS_MAP_DEFAULT)

    file_path = "/var/lib/cmk/cisco_meraki_org_appliance_uplinks.json"
    if not ctx.file_exists(file_path):
        return {
            "changed": False,
            "msg": "no data file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    content = ctx.file_read(file_path)
    if not content:
        return {
            "changed": False,
            "msg": "empty data file",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    data = json.decode(content)
    if type(data) != "list" or len(data) == 0 or type(data[0]) != "dict":
        return {
            "changed": False,
            "msg": "invalid data format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    org_data = data[0]
    uplinks_list = org_data.get("uplinks", [])
    if type(uplinks_list) != "list":
        return {
            "changed": False,
            "msg": "no uplinks in data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    uplink_data = None
    for uplink in uplinks_list:
        if type(uplink) == "dict" and uplink.get("interface") == item:
            uplink_data = uplink
            break
    if uplink_data == None:
        return {
            "changed": False,
            "msg": "uplink %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Status check
    status = uplink_data.get("status", "unknown")
    status_key = status.replace(" ", "_")
    state = status_map.get(status_key, "UNKNOWN")
    msg_parts = ["Status: %s" % status]

    # IP info
    ip = uplink_data.get("ip")
    if ip != None:
        msg_parts.append("IP: %s" % ip)
    public_ip = uplink_data.get("publicIp")
    if public_ip != None:
        msg_parts.append("Public IP: %s" % public_ip)

    # Network name
    network_name = org_data.get("networkName", "")
    if network_name != "":
        msg_parts.append("Network: %s" % network_name)

    # Traffic info (if enabled and uplink is active/ready)
    usage_by_interface = org_data.get("usageByInterface", {})
    if type(usage_by_interface) != "dict":
        usage_by_interface = {}
    if show_traffic and (status == "active" or status == "ready"):
        interface_key = uplink_data.get("interface", "")
        if interface_key in usage_by_interface:
            usage = usage_by_interface.get(interface_key, {})
            if type(usage) == "dict":
                received = usage.get("received")
                sent = usage.get("sent")
                if received != None and type(received) == "int":
                    bps_in = float(received) * 8.0 / float(DEFAULT_TIMESPAN)
                    msg_parts.append("In: %f bps" % bps_in)
                if sent != None and type(sent) == "int":
                    bps_out = float(sent) * 8.0 / float(DEFAULT_TIMESPAN)
                    msg_parts.append("Out: %f bps" % bps_out)

    # HA info
    ha = org_data.get("highAvailability", {})
    if type(ha) == "dict":
        ha_enabled = ha.get("enabled", False)
        ha_role = ha.get("role", "")
        msg_parts.append("H/A enabled: %s" % ("true" if ha_enabled else "false"))
        if ha_role != "":
            msg_parts.append("H/A role: %s" % ha_role)

    # Gateway and DNS
    gateway = uplink_data.get("gateway")
    if gateway != None:
        msg_parts.append("Gateway: %s" % gateway)
    ip_assigned_by = uplink_data.get("ipAssignedBy")
    if ip_assigned_by != None:
        msg_parts.append("IP assigned by: %s" % ip_assigned_by)
    primary_dns = uplink_data.get("primaryDns")
    if primary_dns != None:
        msg_parts.append("Primary DNS: %s" % primary_dns)
    secondary_dns = uplink_data.get("secondaryDns")
    if secondary_dns != None:
        msg_parts.append("Secondary DNS: %s" % secondary_dns)

    # Metrics for perfdata (only for active/ready)
    metrics = {}
    if (status == "active" or status == "ready") and show_traffic and (item in usage_by_interface):
        usage = usage_by_interface.get(item, {})
        if type(usage) == "dict":
            received = usage.get("received")
            sent = usage.get("sent")
            if received != None and type(received) == "int":
                metrics["if_in_bps"] = float(received) * 8.0 / float(DEFAULT_TIMESPAN)
            if sent != None and type(sent) == "int":
                metrics["if_out_bps"] = float(sent) * 8.0 / float(DEFAULT_TIMESPAN)

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""}
    }
