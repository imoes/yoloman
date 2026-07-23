PROTOCOLS = {1: "FC", 2: "iSCSI", 3: "FCOE", 4: "IP", 5: "SAS", 6: "NVMe"}

FAILOVERS = {
    1: "NONE", 2: "FAILOVER_PENDING", 3: "FAILED_OVER",
    4: "ACTIVE", 5: "ACTIVE_DOWN", 6: "ACTIVE_FAILED", 7: "FAILBACK_PENDING",
}

LINKS = {
    1: "CONFIG_WAIT", 2: "ALPA_WAIT", 3: "LOGIN_WAIT", 4: "READY",
    5: "LOSS_SYNC", 6: "ERROR_STATE", 7: "XXX", 8: "NONPARTICIPATE",
    9: "COREDUMP", 10: "OFFLINE", 11: "FWDEAD", 12: "IDLE_FOR_RESET",
    13: "DHCP_IN_PROGRESS", 14: "PENDING_RESET",
}

MODES = {1: "SUSPENDED", 2: "TARGET", 3: "INITIATOR", 4: "PEER"}

LINK_LEVELS = {
    1: 1, 2: 1, 3: 1, 4: 0, 5: 2, 6: 2, 7: 1,
    8: 0, 9: 1, 10: 1, 11: 1, 12: 1, 13: 1, 14: 1,
}

FAIL_LEVELS = {1: 0, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2, 7: 1}

STATE_NAMES = ["OK", "WARN", "CRIT"]


def _port_name(protocol_id, node, slot, cardport):
    proto = PROTOCOLS.get(protocol_id)
    if proto == None:
        return None
    return "%s Node %d Slot %d Port %d" % (proto, node, slot, cardport)


def _fetch_ports(ctx, params):
    host = params.get("host", "localhost")
    api_port = params.get("api_port", "8080")
    username = params.get("username", "3paradm")
    password = params.get("password", "3pardata")
    base_url = "https://%s:%s/api/v1" % (host, api_port)

    creds_body = '{"user":"%s","password":"%s"}' % (username, password)
    auth_res = ctx.run([
        "curl", "-k", "-s", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", creds_body,
        base_url + "/credentials",
    ], mutates=False)

    if auth_res.rc != 0 or not auth_res.stdout:
        return None, "authentication failed: " + auth_res.stderr

    auth_data = json.decode(auth_res.stdout)
    session_key = auth_data.get("key")
    if session_key == None:
        return None, "no session key in auth response"

    ports_res = ctx.run([
        "curl", "-k", "-s",
        "-H", "X-HP3PAR-WSAPI-SessionKey: " + session_key,
        base_url + "/ports",
    ], mutates=False)

    ctx.run([
        "curl", "-k", "-s", "-X", "DELETE",
        "-H", "X-HP3PAR-WSAPI-SessionKey: " + session_key,
        base_url + "/credentials/" + session_key,
    ], mutates=False)

    if ports_res.rc != 0 or not ports_res.stdout:
        return None, "failed to fetch ports: " + ports_res.stderr

    data = json.decode(ports_res.stdout)
    return data.get("members", []), None


def main(ctx, params):
    members, err = _fetch_ports(ctx, params)

    if params.get("_discover"):
        if members == None:
            return {"changed": False, "msg": "discovery failed: " + str(err), "data": {"discovery": []}}

        discovered = []
        for port in members:
            protocol_id = port.get("protocol", 0)
            port_type = port.get("type", 0)
            if PROTOCOLS.get(protocol_id) == None:
                continue
            if port_type == 3:
                continue
            pos = port.get("portPos", {})
            name = _port_name(
                protocol_id,
                pos.get("node", 0),
                pos.get("slot", 0),
                pos.get("cardPort", 0),
            )
            if name == None:
                continue
            discovered.append({"item": name, "params": {}, "metrics": []})

        return {
            "changed": False,
            "msg": "discovered %d ports" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")

    if members == None:
        return {
            "changed": False,
            "msg": "cannot fetch ports: " + str(err),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    found_port = None
    for port in members:
        protocol_id = port.get("protocol", 0)
        if PROTOCOLS.get(protocol_id) == None:
            continue
        pos = port.get("portPos", {})
        name = _port_name(
            protocol_id,
            pos.get("node", 0),
            pos.get("slot", 0),
            pos.get("cardPort", 0),
        )
        if name == item:
            found_port = port
            break

    if found_port == None:
        return {
            "changed": False,
            "msg": "port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = []
    worst = 0

    label = found_port.get("label")
    if label != None:
        parts.append("Label: " + str(label))

    link_state = found_port.get("linkState")
    if link_state != None and link_state > 0:
        link_name = LINKS.get(link_state, "UNKNOWN_%d" % link_state)
        link_key = str(link_state) + "_link"
        link_level = params.get(link_key, LINK_LEVELS.get(link_state, 1))
        if link_level > worst:
            worst = link_level
        parts.append(link_name)

    port_wwn = found_port.get("portWWN")
    if port_wwn != None:
        parts.append("portWWN: " + str(port_wwn))

    mode = found_port.get("mode")
    if mode != None and mode > 0:
        mode_name = MODES.get(mode, "UNKNOWN_%d" % mode)
        parts.append("Mode: " + mode_name)

    failover_state = found_port.get("failoverState")
    if failover_state != None and failover_state > 0:
        fail_name = FAILOVERS.get(failover_state, "UNKNOWN_%d" % failover_state)
        fail_key = str(failover_state) + "_fail"
        fail_level = params.get(fail_key, FAIL_LEVELS.get(failover_state, 2))
        if fail_level > worst:
            worst = fail_level
        parts.append("Failover: " + fail_name)

    state = STATE_NAMES[worst] if worst < len(STATE_NAMES) else "UNKNOWN"
    summary = ", ".join(parts) if parts else "Port: " + item

    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""},
    }