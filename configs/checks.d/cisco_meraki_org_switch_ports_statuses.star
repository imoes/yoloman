def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/cmk-agent/agent_reader/tmp/cisco_meraki_org_switch_ports_statuses"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "discovered 0 ports",
                    "data": {"discovery": []}}
        if not res.stdout.strip():
            return {"changed": False, "msg": "discovered 0 ports",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        items = []
        for switch_port in data:
            port_id = str(switch_port.get("portId", ""))
            if not port_id.isdigit():
                continue
            enabled = switch_port.get("enabled", False)
            status = switch_port.get("status", "").lower()
            admin_state = "up" if enabled else "down"
            oper_state = status if status in ["up", "down"] else "unknown"
            if admin_state in ["up", "down"] and oper_state in ["up", "down"]:
                items.append({
                    "item": port_id,
                    "params": {
                        "admin_state": admin_state,
                        "operational_state": oper_state,
                        "speed": switch_port.get("speed", "unknown")
                    },
                    "metrics": ["if_in_bps", "if_out_bps"]
                })
        return {"changed": False, "msg": "discovered %d ports" % len(items),
                "data": {"discovery": items}}

    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/cmk-agent/agent_reader/tmp/cisco_meraki_org_switch_ports_statuses"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "port %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout.strip():
        return {"changed": False, "msg": "port %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    port = None
    for switch_port in data:
        if str(switch_port.get("portId", "")) == item:
            port = switch_port
            break
    if port == None:
        return {"changed": False, "msg": "port %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    enabled = port.get("enabled", False)
    status = port.get("status", "").lower()
    admin_state = "up" if enabled else "down"
    oper_state = status if status in ["up", "down"] else "unknown"
    speed = port.get("speed", "unknown")
    duplex = port.get("duplex", "").lower()
    client_count = port.get("clientCount", 0)
    is_uplink = port.get("isUplink", False)
    power_usage = port.get("powerUsageInWh", None)
    traffic = port.get("trafficInKbps", {})
    recv_kbps = 0.0
    sent_kbps = 0.0
    if isinstance(traffic, dict):
        recv_kbps = traffic.get("recv", 0.0)
        sent_kbps = traffic.get("sent", 0.0)
    warnings = port.get("warnings", [])
    errors = port.get("errors", [])
    spanning_tree = port.get("spanningTree", {})
    st_statuses = []
    if isinstance(spanning_tree, dict):
        st_statuses = spanning_tree.get("statuses", [])
    secure_port = port.get("securePort", {})
    secure_enabled = False
    if isinstance(secure_port, dict):
        secure_enabled = secure_port.get("enabled", False)

    state_disabled = params.get("state_disabled", 0)
    state_not_connected = params.get("state_not_connected", 0)
    state_admin_change = params.get("state_admin_change", 1)
    state_op_change = params.get("state_op_change", 1)
    state_speed_change = params.get("state_speed_change", 1)
    state_not_full_duplex = params.get("state_not_full_duplex", 1)

    prior_admin = params.get("admin_state", "unknown")
    prior_oper = params.get("operational_state", "unknown")
    prior_speed = params.get("speed", "unknown")

    state = "OK"
    details_lines = []
    perfdata = {}

    if admin_state == "down":
        if state_disabled == 2:
            state = "CRIT"
        elif state_disabled == 1:
            state = "WARN"
        details_lines.append("Admin status: down")
    else:
        details_lines.append("Admin status: up")
    if admin_state != prior_admin:
        if state_admin_change == 2:
            state = "CRIT"
        elif state_admin_change == 1 and state != "CRIT":
            state = "WARN"

    if admin_state != "down":
        if oper_state == "up":
            if state_not_connected == 2:
                state = "CRIT"
            elif state_not_connected == 1 and state != "CRIT":
                state = "WARN"
        elif oper_state == "down":
            if state_not_connected == 2:
                state = "CRIT"
            elif state_not_connected == 1 and state != "CRIT":
                state = "WARN"
        else:
            state = "UNKNOWN"
        details_lines.append("Operational status: " + oper_state)
        if oper_state != prior_oper:
            if state_op_change == 2:
                state = "CRIT"
            elif state_op_change == 1 and state != "CRIT":
                state = "WARN"

    if admin_state == "down" or oper_state in ["down", "unknown"]:
        pass
    else:
        speed_ok = len(speed) > 0
        if speed_ok:
            if speed != prior_speed:
                if state_speed_change == 2:
                    state = "CRIT"
                elif state_speed_change == 1 and state != "CRIT":
                    state = "WARN"
            details_lines.append("Speed: " + speed)
        else:
            state = "UNKNOWN"
            details_lines.append("Speed: unknown")

    recv_bps = recv_kbps * 1000.0
    sent_bps = sent_kbps * 1000.0
    perfdata["if_in_bps"] = recv_bps
    perfdata["if_out_bps"] = sent_bps

    if admin_state == "down" or oper_state in ["down", "unknown"]:
        pass
    else:
        if duplex == "full":
            details_lines.append("Duplex: full")
        else:
            if state_not_full_duplex == 2:
                state = "CRIT"
            elif state_not_full_duplex == 1 and state != "CRIT":
                state = "WARN"
            details_lines.append("Duplex: " + duplex)

    details_lines.append("Clients: %d" % client_count)

    if is_uplink:
        details_lines.append("Uplink: yes")
    else:
        details_lines.append("Uplink: no")

    if power_usage != None:
        details_lines.append("Power usage: %f Wh" % power_usage)

    for st in st_statuses:
        details_lines.append("Spanning tree status: " + st)

    for w in warnings:
        if state != "CRIT":
            state = "WARN"
        details_lines.append(w)

    for e in errors:
        if e not in ["Port disconnected", "Port disabled"]:
            state = "CRIT"
            details_lines.append(e)

    if secure_enabled:
        details_lines.append("Secure port: enabled")

    summary = ""
    if admin_state == "down":
        summary = "(admin down)"
    else:
        summary = "(%s)" % oper_state

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": perfdata,
            "details": "; ".join(details_lines),
        },
    }